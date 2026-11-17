# 子进程补丁与 syscall 兼容层

> 这里记录 guest 进程里被改写的 libc / 框架入口，以及它们在 host 侧对应的 syscall 实现。guest 侧代码在 `Nyxian/LindChain/ProcEnvironment/Shims/`，host 侧在 `Nyxian/LindChain/ProcEnvironment/Surface/sys/`。
>
> 一句话概括这套设计：**guest 里所有"需要跨进程特权"的 libc 调用都被替换成"向 host 发一条 Mach 消息并等回复"；host 用自己真实的 task port / 文件权限替它做完，再把结果写回 guest 内存。** 有些调用（fork）在 iOS 上根本无解，于是用"快照-回滚"伪造。

---

## 0. 补丁是怎么装上的

两套机制并存，都只是函数级 inline hook：

| 机制 | 位置 | 用法 |
| --- | --- | --- |
| `litehook` | `ProcEnvironment/litehook/` | `LIBKERN_INSTALL_PATCH(posix_spawn)`（在 `environment_posix_spawn_init()` 末尾） |
| `LIBKERN_PATCH` / `LIBKERN_ORIG` | `Surface/libkern/patch.h` | 定义函数体时用；`LIBKERN_ORIG(name)(...)` 调原实现（kill/close/dup2 等要"先记录再透传"的地方） |
| `LIBKERN_DEFINE_PATCHABLE` | 同上 | 声明"这个 host 函数可被 kext/ROM 替换实现"（例如 `trust_identity_create_from_path`、`kxopen`、`proc_task_for_proc`、`proc_spawn`），是 ROM/kext 定制 host 行为的唯一入口 |

guest 侧的入口是 `Shims/environment.m::environment_init()`（调用顺序见 `surface.md` §5）：

```c
environment_posix_spawn_init();     /* posix_spawn / posix_spawnp */
environment_vfork_init();           /* fork / vfork / close / dup2 / execve … */
environment_application_init();     /* LSApplicationWorkspace / application */
```

以下按题目要求的顺序：posix_spawn → vfork → sysctl → tty/ioctl → libproc → task_for_pid → setuid/setgid。

---

## 1. `posix_spawn` / `posix_spawnp`（`Shims/posix_spawn.m`）

### 为什么必须改

iOS 上 App 不能用 `fork()`，`posix_spawn` 也被沙箱挡住（`sandbox-exec` 禁止 `process-exec`）。而 guest 里跑的是普通 Unix 程序（`clang`、`make`、`bash`），它们只会调 `posix_spawn`。

### 实现步骤

1. **解析 spawnattr**：`posix_spawnattr_getflags()`；`POSIX_SPAWN_SETSID` 与 `SETPGROUP` 同时出现 → `EINVAL`（与 Darwin 一致）；取了 `pgroup`。
2. **`realpath(path)`**：先规范化（注释说"防奇怪的 file bug，apple 的合法性检查就这样"）。
3. **CS 校验 / 自动签名**：
   ```c
   LCMachO *machO = LCMapMachO(resolved, true);
   cs_valid = LCCheckCodeSignature(machO);
   if(!cs_valid) {
       int fd = open(path, O_RDWR);
       int ret = (int)liveshim_syscall(SYS_sign, fd);   /* 让 host 用它的私钥签 */
       close(fd);
       /* 再验一次，仍失败 → ENOEXEC */
   }
   ```
4. **文件描述符继承**：`PEFileTable *fileTable = [PEFileTable currentTable]` 拷贝当前 fd 集合，然后按 `POSIX_SPAWN_CLOEXEC_DEFAULT` 与每个 fd 的 `FD_CLOEXEC` 建 `closeOnExec` 索引集，最后统一关掉（`Shims` 自己维护一张"fd → 目标 fd"的表，`ProcEnvironment/PEFileTable.m`）。
5. **解释 file actions**（直接摸私有结构 `_posix_spawn_file_actions_t`，`psfa_act_acts[i]`）：
   `PSFA_OPEN` / `PSFA_CLOSE` / `PSFA_DUP2` / `PSFA_INHERIT` / `PSFA_FILEPORT_DUP2` / `PSFA_CHDIR` / `PSFA_FCHDIR`，并同步维护 `closeOnExec`（`dup2` 不论是否同 fd 都清 CLOEXEC——与 Darwin 语义一致）。`CHDIR/FCHDIR` 在 iOS 上不存在，注释写"shrug, add it anyways"。
6. **工作目录**：若 file actions 没设，`getcwd()` 取当前目录。
7. **交给 host**：
   ```c
   int64_t pid = environment_proxy_spawn_process_at_path(nsPath, argv数组, envp字典, fileTable, nsCwd, spawnFlags, spawnPgroup);
   if(pid < 0) return EPERM;          /* 注释："lacking entitlements?" */
   *process_identifier = (pid_t)pid;
   liveshim_syscall(SYS_waittask, pid);   /* 等 host 把 task port 拿到 */
   ```
   `environment_proxy_spawn_process_at_path` 走的是 `Shims/proxy.m` + `ServerProtocol`，也就是 README 里标 **deprecated** 的 `ServerSession`/XPC 通道（`Server/Server.m`、`ServerSession.m`）；返回值是 host 分配的 pid。

8. **`posix_spawnp`**：注释坦白"skidded from apple them selves"，即把 Darwin `libc/sys/posix_spawn.c` 的 PATH 搜索循环整段抄下来，内部调上面被 patch 的 `posix_spawn`，错误码映射也照抄（`EACCES`/`ENOENT`/`ENOEXEC` 的判定顺序）。

### 要点

- **返回值是 errno**（Darwin 的 `posix_spawn` 返回错误码而不是 -1 置 errno），补丁严格遵守了。
- `SYS_waittask` 是"task port 就绪"的同步点：guest 后续要做 `task_for_pid()`/`kill()` 时依赖 host 已经持有子进程的 task port。
- 这里**不做权限判断**——判断在 host 的 spawn 路径与 `SYS_sign` 里；guest 拿不到 `ProcessSpawn` 就直接 `EPERM`。

---

## 2. `vfork` / `fork`：time-travel fork checkpoint（`Shims/vfork.m`，77 KB）

这是整个仓库里最"暴力"的一段：**iOS 没有 fork，所以在同一地址空间里做"检查点—跑子逻辑—回滚"。**

### 常量体现规模

```c
#define PE_CHECKPOINT_ARENA_SIZE (512ull * 1024ull * 1024ull)   /* 512 MiB 快照区 */
#define PE_MAX_VM_REGIONS        2048
#define PE_MAX_FD_JOURNAL        512
#define PE_MAX_FD_OPS            512
#define PE_MAX_FAKE_CHILDREN     32
#define PE_MAX_TRACKED_FDS       4096
#define PE_MAX_EXEC_VECTOR       4096
#define PE_MAX_LOCAL_PIPES       128
#define PE_PIPE_SPOOL_INITIAL    (64ull * 1024ull)
#define PE_PIPE_SPOOL_LIMIT      (256ull * 1024ull * 1024ull)
#define PE_SYNTHETIC_PID_BASE    ((pid_t)0x40000000)
#define PE_EXEC_PENDING_PID      ((pid_t)0x3fffffff)
```

### 控制块 `pe_checkpoint_control_t`

一个全局 `g_checkpoint`，内含：

- **helper 线程握手**：`helper_action`（IDLE/CAPTURE/RESTORE）、`request_semaphore`/`ready_semaphore`、`helper_pthread`/`helper_thread`、`helper_stack_low/high`（自己的栈，因为要在"父"的栈被回滚后仍然活着）。
- **线程状态**：`target_thread` + `struct arm64_thread_full_state`（`thread_get_state` 的 ARM_THREAD_STATE64 + EXCEPTION + NEON + DEBUG 四个 flavor）。
- **进程状态**：`cwd`、`saved_cwd_fd`、`umask`、`sigmask`、每个信号的 `sigaction`。
- **虚拟内存**：`vm_regions[]`（`address/size/copy_address/protection/max_protection/inheritance/user_tag/share_mode`）。
- **fd**：`fd_journal[]`（原 fd 的备份 + flags）、`fd_ops[]`（CLOSE/DUP2 记录）、`pipe_fd_slot[]`/`pipe_fd_role[]` 映射。
- **本地管道**：`local_pipes[]`（spool 缓冲区、序列号）。
- **待执行 exec**：`pending_exec` / `path` / `argv` / `envp` / `cwd`。
- **伪造的子进程**：`return_pid`（0 表示"我现在是子"）、`synthetic_child`、`synthetic_wait_status`、`fake_children[]`、`collapsed_nested_forks`。

### 抓快照（`pe_capture_vm`）

用 `mach_vm_region_recurse()` 遍历自己的地址空间，对每个 region：

- 只看 **可读 + 可写 + `SM_PRIVATE`/`SM_COW`/`SM_PRIVATE_ALIASED`** 的私有页（共享库代码、frameworks 不用存）；
- 跳过 `pe_region_is_excluded()` 的范围：快照区自身、helper 栈、管道 spool；
- `mach_vm_copy(task, address, size, copy_address)` 把内容复制到 arena（`copy_address` 来自 `pe_scratch_alloc`）；
- 超过 `PE_MAX_VM_REGIONS` → `E2BIG`；arena 用完 → `ENOMEM`。

### 回滚（`pe_restore_vm` / `pe_restore_one_vm_region`）

先试 `mach_vm_copy` 写回原地址；失败则 **`mach_vm_remap(VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE)`** 把 arena 里那份重新映射过去，再按原 `max_protection`/`protection` 恢复权限。fd 与 cwd 由 `pe_restore_fd_state()` 逆序重放 journal（`dup2(backup, fd)` + 恢复 flags，或关掉"新开的"fd）；线程状态由 `pe_restore_thread_state()` 写回四个 flavor。

### 本地管道（`pe_local_pipe_*`）

这是最容易被忽略但最关键的一处：**父子在同一地址空间，`pipe()` 的两端本来就是同一个内核对象**，如果直接让"子"写、"父"读，数据会被快照逻辑复制成两份或丢失。做法：

- `pipe()` 注册一对 fd 到 slot（`PE_PIPE_ROLE_READ` / `WRITE`）；
- 当处于"伪子"上下文（`pe_in_fake_child()`：`return_pid == 0 && checkpoint_active && !restoring`）且写端属于当前 checkpoint 的 slot 时，**写入不落到真管道**，而是追加到 slot 的 spool 缓冲区（`pe_pipe_spool_write`，容量翻倍增长，上限 256 MiB）；
- 父侧读该 slot 的读端时先从 spool 取（`pe_pipe_spool_read`），spool 空且写端已 `producer_done` 才返回 0（EOF）。

于是 `fork(); child writes; exec()` 这类"父读子输出"的模式在单地址空间里也成立。

### fd 与 exec 的处理

- `close` / `dup2` 被 `LIBKERN_PATCH` 包了一层：只在"伪子"里记录（`pe_record_fd_before_change` 先备份被覆盖的 fd，再 `LIBKERN_ORIG(close/dup2)`，成功后 `pe_record_fd_op` 记一条），回滚时逆序重放。
- `execve` 在本进程里不可能真的替换镜像，所以记成 `pending_exec`（path + argv + envp + cwd，全部复制进 arena，`PE_MAX_EXEC_VECTOR` 上限）——回滚完成后，由"父"真正去做 `posix_spawn`+等待。
- 伪造 pid：`PE_SYNTHETIC_PID_BASE (0x40000000)` 起递增，`fake_children[]` 记录 `{pid, status, used}`，`wait4` 从这里取。`PE_EXEC_PENDING_PID (0x3fffffff)` 是"待 exec"的占位。
- `collapsed_nested_forks` 计数：嵌套 fork 会被折叠，而不是真的递归快照。

### 结论

`fork()` 在这里的真实语义是：**"能在同一地址空间里回滚的一次投机执行"**。副作用（文件系统、网络）不可回滚，这也是为什么它只用于 `fork + exec` 这种"立刻 exec"的用法，并用 `pending_exec` 把 exec 推迟到回滚之后。

---

## 3. `sysctl`（guest 侧调用 → host 侧 `Surface/sys/host/sysctl.m`）

见 `surface.md` §6 的实现细节。这里只记**为什么需要它**：

- guest 是 iOS App 进程，`sysctl(CTL_KERN, KERN_PROC, ...)` 被沙箱挡住（只能看到自己的 pid）；`ps`、`top`、`getprocs`、`NSProcessInfo` 的某些路径都会失败。
- 补丁把 `SYS_sysctl` / `SYS_sysctlbyname` 变成 Mach 调用；host 在自己的权限下组装**整个进程表**并 `mach_vm_write` 回 guest 缓冲区。
- **语义保真**：两段式查询（先问长度）、缓冲不足回 `ENOMEM` 并写回所需长度、`kern.procargs2` 用 `p_comm` 合成。这些细节说明写它是照着 `ps` 的实际调用模式对齐的。
- `SYS_proctb` / `SYS_procbsd` / `SYS_getent` / `SYS_setent` / `SYS_procpath` / `SYS_gethostname` / `SYS_sethostname` 在 `ksurface_abi.h` 里全部标 **deprecated**，理由写在注释：统一走 `SYS_sysctl` 与 `SYS_pectl`，编号永不重用。

---

## 4. tty 与 `ioctl`（`Surface/sys/host/openpty.c` + `ioctl.c`）

- **`SYS_openpty`**：guest 里 `openpty()` 需要 `/dev/ptmx`，iOS 上不可用；host 在自己的权限下开一对 pty，把 slave 侧作为 **fileport** 通过 OOL ports 描述符交回 guest，并在 `ksurface->tty_info` 树里登记一个 `ksurface_tty_t`（含 `struct termios t`、`struct winsize ws`、`sid`、`pgrp`、`pump_thread`）。
- **`SYS_ioctl`**：fileport → `tty_for_port()` → 白名单 9 个 ioctl（详见 `surface.md` §6）。不在白名单 → `ENOSYS`（不是 `ENOTTY`，可区分"我们没实现"与"这不是终端"）。
- `TIOCSCTTY` 里除了设 `tty->sid/pgrp`，还改本进程 `bsd.kp_proc.p_flag |= P_CONTROLT` 和 `e_tpgid`——**guest 的"控制终端"完全是在 host 的进程表里伪造的**，guest 自己的 struct proc 根本不存在。
- `TIOCSWINSZ` 变化时 `tty_kill(tty, SIGWINCH)`：信号也是 host 通过 `PEProcess sendSignal:` 往 guest 投递的。
- README 的限制说明（"only works when NXWindowSessionTerminal creates it"）对应的事实是：**tty 只能由 host 侧的窗口/终端会话创建并登记**，guest 自己 `open("/dev/tty")` 是走不通的。

---

## 5. libproc 兼容（`SYS_proc_info`）

- `ksurface_abi.h` 里 `SYS_proc_info = 755` 已废弃但保留编号；当前实际路径是 `Surface/sys/proc/proc_info.h` 里的 handler 注册进 `sys_list[]`（见 `surface.m` 的 `{ "SYS_proc_info", SYS_proc_info, GET_SYSCALL_HANDLER(proc_info) }`）。
- 结构定义借的是 `Surface/libkern/bsd/proc_info.h`（40 KB，逐字复刻 XNU 的 `proc_bsdinfo`、`proc_taskinfo`、`proc_regioninfo`…），所以 guest 里 `proc_pidinfo()` 系列能拿到真实布局。
- **这一节的实现我没有逐行读**（只看到注册与结构头），因此"支持哪些 flavor"、"是否走 host 自己的 task port 取 `proc_taskinfo`"**属推断**；可确定的是：`proc_pidinfo` 在 iOS 上对其它进程被拒，所以它必然和 sysctl 一样被重定向到 host。

---

## 6. `task_for_pid` / `task_name_for_pid`（`Surface/sys/compat/task_for_pid.c`）

- 参数：`pid`、`name_only`。
- 找进程（`proc_for_pid`，失败 `ESRCH`）→ 权限（`proc_snapshot_primitive_over_proc_allowed`，见 `surface.md` §3）：
  - `name_only` 时不需要任何 entitlement（与 Darwin 的 `task_name_for_pid` 语义对齐），
  - 否则要求调用者 `TaskForPid` **且** 目标 `GetTaskAllowed`，
  - 旁路：`SystemTaskPorts | TaskForPid | Platform` 三者齐备 → 无条件放行（但仍要"看得见"目标）。
- `proc_task_for_proc(target, &flavour, &exportTask)`：flavour = `TASK_NAME_PORT`（name_only）或 `TASK_KERNEL_PORT`；若实际拿到的是 name port 而请求的是 kernel port → `EACCES`；只有 `IPC_OTYPE_TASK_CONTROL` 才真给 control port（`lookup.c`）。
- 返回值走 **端口描述符**（不是整数）：`syscall_payload_create(NULL, sizeof(mach_port_t), out_ports)` + `sys_export_port(exportTask)`，guest 侧从 reply 的 OOL ports 里取出。

于是 guest 里 `task_for_pid(mach_task_self(), other_pid, &port)` 真能拿到**你自己启动的**子进程的 task port；越权拿别的 guest 的会被 `permit.c` 拦掉（同一 session 之外的进程"看不见"）。

---

## 7. 凭据类 syscall（`Surface/sys/cred/`）

| syscall | 文件 | 语义 |
| --- | --- | --- |
| `setuid` / `seteuid` / `setreuid` | `setuid.c` | 特权（`ProcessElevate` 或 ruid==0）可任意设；否则只能设成 ruid/svuid；`setreuid` 特权时同步 svuid |
| `setgid` / `setegid` / `setregid` | `setgid.c` | 同上，落在 `e_ucred.cr_groups[0]` |
| `getuid/geteuid/getgid/getegid/getppid` | `getuid.c`、`getgid.c`、`getppid.c` | 从进程表读 |
| `setsid` / `getpgrp` / `setpgid` / `getsid` / `getpgid` | `setsid.c`、`getsid.c` | 落在 `nyx.sid` / `nyx.pgid` 与 `bsd.kp_eproc.e_pgid` |
| `loginctl` | `loginctl.c` | `GetLength/GetWord/SetWord/Commit/Clear` 管理 `nyx.login_name` |
| `groupctl` | `groupctl.c` | 同五个动作管理 `nyx.supplementary_groups[32]` |

**统一要点**：iOS 里 App 不能 `setuid()`（沙箱 + 无 root），所以这些 syscall 全部被截获，只改 ksurface 进程表里的字段。它们之所以重要，是因为 `sudo`、`login`、`su`、`chsh` 之类的工具会检查这些返回值与 `getpwuid` 的一致性——而 `loginctl`/`groupctl` 的存在说明作者把"登录名"与"附加组"也补上了，否则 `id` 的输出会是空的。

改动六个 id 时置 `P_SUGID`（`proc_set_sugid_if_applicable`），这是给 `permit.c` 的 uid 检查用的安全细节（降权后的进程不能被同 uid 进程拿 task port）。

---

## 8. 其它 guest 侧 shim（未逐一展开）

| 文件 | 作用 |
| --- | --- |
| `Shims/LSApplicationWorkspace.m`（25 KB） | 伪造 LaunchServices：让 guest 能枚举/查询/打开"应用"（数据来自 host 的 `LDEApplicationWorkspace`） |
| `Shims/application.m` / `application.h` | `UIApplication` 相关伪造（`environment_application_init`） |
| `Shims/proxy.m` / `proxy.h` | guest → host 的代理接口（`environment_proxy_spawn_process_at_path` 等），走 XPC `ServerProtocol` |
| `Shims/environment_abi.h/.m` | ABI 声明 |
| `Shims/attrstrnilfix.m` | 一个 `NSAttributedString` 传 nil 的兼容修正 |
| `Shims/PEExtension.m`（host 侧，见 `build-and-run.md`） | NSExtension 承载 |
| `LiveProcess/` | 真正的 guest 执行体：`main.c`、`NXLiveProcessBootstrap.h`、`NXLiveProcessDispatch.c`、`NXCoWCache.h` |

---

## 9. 本节的推断与缺口

- `vfork.m` 77 KB，我只读了前 ~32 KB（常量、控制块、管道 spool、VM 抓取/回滚、fd journal、`close`/`dup2` 补丁）。**`fork()`/`vfork()`/`execve()` 三个入口本身、`wait4` 的伪造、`pending_exec` 的执行时序我没有读到源码**，上述流程是按数据结构与辅助函数反推的，`execve` 之后"由父真正 spawn"这一步**属推断**。
- `wait4` 的 host 侧处理（`Surface/sys/proc/wait4.h`）未读；`kProcEventTypeKill/Wait4/WaitTask` 三个事件位的语义只从 `spawn.m`、`handoffep.c` 的调用处反推。
- libproc（`SYS_proc_info`）只看到注册与 40 KB 结构头，具体分支未读，已在 §5 标注。
- `Shims/LSApplicationWorkspace.m`、`application.m` 未读，表格里的描述来自文件名与 `environment_application_init` 的调用点。
- `litehook` / `patch.h` 的 hook 实现（如何绕过 arm64e PAC、如何取到原始函数地址）未读。
