# Nyxian 的 ksurface：进程 / 内存 / Mach IPC 层

> 仓库：https://github.com/emexlab/Nyxian （main）。本文所有路径都相对仓库根。
> 这一层代码运行在 **Nyxian 这个 App 进程里**（它自称 kernel / host），被托管的每个"进程"是另一个真实的 iOS 进程（LiveProcess.appex 的实例）。所谓"微内核"是一套**跑在用户态、以真实 iOS 进程为 backing 的进程抽象**。

---

## 1. 全局对象与初始化顺序

`Nyxian/LindChain/ProcEnvironment/Surface/mapping.h` 定义了唯一全局结构 `ksurface_mapping_t`：

| 字段 | 作用 |
| --- | --- |
| `sys_server` | 系统调用服务端（Mach 端口 + 处理表 + 线程池） |
| `pub_key` / `pub_key_len` | 校验 NXT2 信任 blob 的**公钥**（安装期生成的密钥对的公钥） |
| `host_info` | `pthread_rwlock_t` + `hostname[MAXHOSTNAMELEN]` |
| `proc_info` | 读写锁 + `proc_count` + **以 pid 为 key 的 radix tree** + `kern_proc`（"kernel process"，其实就是 Nyxian 自己） |
| `tty_info` | radix tree，tty 对象 |
| `kext_info` | radix tree，已加载 kext 对象 |

全局指针 `ksurface` 在 `Nyxian/LindChain/ProcEnvironment/Surface/surface.m`。

初始化入口 `ksurface_kinit()`（同文件）严格按序：

1. `ksurface_kinit_kalloc()`：`malloc` `ksurface`；`ksurface_kinit_get_keys()` 用 `get_static_kernel_key()` 取安装期生成的 CS 密钥对（只留公钥），失败即 `kpanic`；逐个 `pthread_rwlock_init` 四把锁；把三棵 radix tree 置空。
2. `ksurface_kinit_kinfo()`：从 `NSUserDefaults` 键 `LDEHostname` 恢复主机名，缺省 `localhost`。
3. `ksurface_kinit_kserver()`：`syscall_server_create()` → 逐个 `syscall_server_register()` 注册 `sys_list[]` → `syscall_server_start()`。
4. `ksurface_kinit_kproc()`：分配一个 `ksurface_proc` 作为"kernel proc"，`identity = trust_identity_get_kernel()`；`KSURFACE_EMIT_KERNEL_TASK` 为 0（默认）时**它冒充 Nyxian 自身**：pid/ppid/sid/pgid 全取自 `getpid()` 等，`p_comm` 取自身可执行文件名，task port 取 `task_get_special_port(mach_task_self(), TASK_NAME_PORT)`（只给 name port，不给 control port——保护自己）；`p_flag = P_SYSTEM|P_LP64`；插入进程表，`ksurface->proc_info.kern_proc` 记住它。
5. `ksurface_fs_init()`、`ksurface_keychain_update()`，任一失败 `kpanic`。
6. 把 `~/Documents/kmsg.txt` 重命名/移动到 `~/Documents/mntfs/devfs/kmsg`，即把 klog 伪装成一个 devfs 设备文件（`SYS_sysctl` 的 `kern.msgbuf` 就读它的 `st_size`）。

`surface.h` 只暴露 `ksurface`、`ksurface_kinit*`、`ksurface_sethostname()`。

---

## 2. 对象模型：`kvobject` = 引用计数 + 事件 + 快照

`Surface/libkern/obj/defs.h` 是整套"内核对象"的地基：

```c
struct kvobject {
    kvobject_base_type_t base_type;   /* Object / ObjectSnapshot */
    bool memoryIsOwned;
    _Atomic int refcount;
    _Atomic kvobject_state_t state;   /* Normal / Invalid：Invalid 之后 retain 必失败 */
    kvobject_main_event_handler_t main_handler;
    pthread_rwlock_t event_rwlock; uint64_t event_count; kvobject_event_t *event;
    pthread_rwlock_t rwlock;          /* 对象主锁 */
    kvobject_t *orig;                 /* 快照指回原对象 */
};
```

- 事件类型：`Init / Deinit / Copy / Snapshot / Invalidate / Unregister`（`enum kvObjEvent`），每个对象维护一条事件链 `kvevent`，带自己的 `handler`、`mask`、`ctx`、`in_use` 互斥。
- 快照三种：`kvObjSnapStatic`（不建反向引用）、`kvObjSnapReferenced`（新引用）、`kvObjSnapConsumeReference`（吃掉调用者的引用，**失败时也吃掉**）。
- 典型用法：`Surface/libkern/sys/worker.c` 用 `kvo_snapshot_into_mem(owned, proc, kvObjSnapConsumeReference)` 把调用者进程做成一份"快照"，之后所有权限判断都对着快照做，避免持锁太久；`Surface/proc/permit.c` 的 `proc_primitive_over_proc_allowed()` 把真实对象直接 cast 成快照指针（读锁下等价）。
- 分配宏：`kvo_alloc_fastpath(proc)`（`surface.m`、`proc/spawn.m` 用它）、`kvo_copy(parent)`（fork 语义：**拷贝的是对象，不是地址空间**）、`kvo_retain/kvo_release/kvo_rdlock/kvo_wrlock/kvo_event_trigger`。

### 进程对象

`Surface/proc/def.h`：

```c
struct ksurface_proc {
    kvobject_t header;
    bool in_tfp_handoff;     /* task port 交接进行中（防重入） */
    task_t task;             /* 该 guest 的 task port，MACH_PORT_NULL 表示还没拿到 */
    struct kchildren {       /* 父子"引用契约" */
        pthread_mutex_t mutex;
        ksurface_proc_t *parent;
        ksurface_proc_t *children[CHILD_PROC_MAX];
        uint64_t parent_cld_idx, children_cnt;
    } children;
    kinfo_proc_t bsd;        /* 直接复刻 BSD 的 kinfo_proc，供 sysctl 拷贝出去 */
    struct knyx_proc {
        pid_t sid, pgid; int pidv;              /* pidv：防 pid 复用 */
        char login_name[MAXLOGNAME]; uint16_t login_name_len;
        gid_t supplementary_groups[32]; uint16_t supplementary_group_count;
        int64_t p_status;                        /* wait4 状态 */
        uint64_t start_abstime, exit_abstime;
        ksurface_trust_identity_t *identity;     /* 路径 / cdhash / 权限 / 信任级别 */
        PEEntitlementFlags entitlements, maxEntitlements;
    } nyx;
};
```

要点：

- **真实凭据字段全在 `bsd` 里**（`kp_eproc.e_pcred`、`e_ucred.cr_groups[0]`…），宏 `proc_setruid/euid/svuid/rgid/egid/svgid` 直接改这些字段。所以"setuid"只是改这张表，见 `Surface/sys/cred/setuid.c`。
- **`maxEntitlements` 是权限上限**：`SYS_pectl` 的 `kPECTLCodeSigningSetEntitlements` 只允许把 entitlement 加到 `maxEntitlements` 子集里（`Surface/sys/compat/pectl.m`），`DropAllEntitlements` 会连上限一起清。
- `pidv`（audit token 的 `val[7]`）参与进程查找：`proc_for_pid_with_pidv()`（`Surface/proc/lookup.c`）在 pid 命中后再比对 pidv，pid 复用不会串到旧对象上。

### 进程表

`Surface/proc/insert.c` / `lookup.c` / `remove.c` / `list.c`，底层是 `Surface/libkern/radix/` 的 radix tree，key 是 pid：

- `proc_for_pid()`：读锁下 `radix_lookup` → `kvo_retain` → 返回**已持有的引用**（调用方必须 release）。
- `proc_task_for_proc(proc, &flavour, &task)`：**只导出白名单 flavour**（`TASK_KERNEL_PORT / TASK_NAME_PORT / TASK_INSPECT_PORT / TASK_READ_PORT`）；先用 `mach_port_kernel_object()` 看 `proc->task` 的真实 IPC 对象类型：`IPC_OTYPE_TASK_CONTROL` 才 `task_get_special_port()` 派生，`IPC_OTYPE_TASK_NAME` 就降级成 `mach_port_mod_refs` 复制 name port，其它类型一律 `KERN_INVALID_RIGHT`。注释明确写着"失败路径绝不能导出 task port，否则 PR 会被拒"。
- `proc_list()`（`list.c`）：按调用者可见性 + flavour 遍历 radix tree，把每个 `proc->bsd` **memcpy 成 `kinfo_proc` 数组**，这就是 guest 里 `ps` 看到的数据来源。

### 父子契约与生命周期

`Surface/proc/spawn.m`：

- `proc_spawn()`：`kvo_copy(parent)` 得到子对象 → `ppid=父 pid`、`pid/pidv` 用参数 → `nyx.identity` 用新身份 → `entitlements/maxEntitlements` 由 NXT2 字典换算（`trust_identity_entitlement_flags_from_entitlements`）→ 父是 kernel proc 时给 501/mobile 凭据、自成 session/pgroup → `Platform` + `PlatformRoot` 给 root 凭据，否则按 `PlatformUser/PlatformGroup` 设 uid/gid → `p_comm` 取路径最后一段 → 插表 → 双向 retain 建立父子引用契约（父最多 `CHILD_PROC_MAX` 个孩子）。
- `proc_kill()`：只做参数校验，然后交给 `[[PEProcessManager shared] processForProcessIdentifier:]` 的 `sendSignal:`（`Nyxian/LindChain/ProcEnvironment/PEProcessManager.m`）。找不到进程返回 `KERN_NOT_FOUND`（注释：防止引用计数被试探）。`KSURFACE_EMIT_LAUNCHD` 打开时 pid 1 上的 SIGKILL/SIGTERM 变成 `rebootUserspace`。
- `proc_zombify()` / `proc_reap()`：僵尸化时递归 reap 子树、标记 `SZOMB`、给父发 `kProcEventTypeWait4` 事件 + `SIGCHLD`；reap 时把父的 `children[]` 用"末尾元素填补"的方式摘链（`parent_cld_idx` 同步更新），最后 `forceTerminate` 真实进程。

---

## 3. 权限模型

三层：**NXT2 entitlement 字典** →（换算）**`PEEntitlementFlags` 位掩码** → **`proc/permit.c` 的判定函数**。

### 位定义

`Surface/trust/entitlement.h`，`PEEntitlementFlags`（uint64）：

`GetTaskAllowed`(1<<0)、`TaskForPid`(1<<1)、`ProcessEnumeration`(1<<3)、`ProcessKill`(1<<5)、`ProcessSpawn`(1<<6)、`ProcessSpawnSignedOnly`(1<<7)、`ProcessElevate`(1<<8)、`HostManager`(1<<9)、`CredentialsManager`(1<<10)、`LaunchServices*`(1<<11–15)、`ProcessSpawnInheriteEntitlements`(1<<19)、`Platform`(1<<20)、`PlatformRoot`(1<<21)、`SystemTaskPorts`(1<<22)、`LoadKEXT`(1<<23)。

同一文件还给了 NXT2 的字符串键常量（`kNXT2Entitlement*`，见 `trust-and-kext.md`）。

### 判定顺序（`Surface/proc/permit.c::proc_snapshot_primitive_over_proc_allowed`）

1. **就是自己** → 允许（自己对自己永远有权限）。
2. **可见性**：`proc_get_proc_visibility()`（`proc/list.c`）有 `ProcessEnumeration`（或 enforcement 放宽）→ 全见；否则只能见**同 session**（`PROC_VIS_SAME_SID`）。看不见 → `ESRCH`。
3. **platform 保护**：目标是 platform 进程而调用者不是 → 若 enforcement 判"应拒绝"则 `EPERM`。
4. **血缘检查**：同 session 且目标是调用者的后代（沿 `parent` 链上溯）→ 跳过 uid 检查直达 `out_euid_check`。注释说明了动机：否则 platform 父进程 spawn 一个非特权子进程，子进程拿到父的 task port 就能借父的 entitlement 提权。
5. **目标必须自带被操作所需的 entitlement**（`targetEntitlementsNeeded`，例如拿对方 task port 需要对方有 `GetTaskAllowed`），除非调用者是 platform。
6. **调用者必须自带操作的 entitlement**（`entitlementsNeeded`，例如 `TaskForPid`）。
7. **uid 检查**：`euid != 0` 时，要求目标没置 `P_SUGID` 且 euid 相同；否则 `EPERM`。

结论：这不是 Unix DAC，而是"**能力位 + 可见性 + 血缘 + euid 兜底**"的四段式，且每一步都被 `trust_enforcement_should_deny()` 包住，可以整体降级为 permissive/disabled（`trust.m`）。

`Surface/sys/compat/task_for_pid.c` 是这套模型的样板消费者：`name_only` 走 `TASK_NAME_PORT` 且不需要 entitlement；否则要求 `TaskForPid`+目标 `GetTaskAllowed`，但 `SystemTaskPorts|TaskForPid|Platform` 三者齐备时可以无条件放行（且只要求"看得见"）。

---

## 4. Mach IPC 服务端（系统调用的传输层）

### 端口

`Surface/libkern/sys/core.c::syscall_server_start()`：

```c
mach_port_options_t options = {
    .flags = MPO_PORT | MPO_IMMOVABLE_RECEIVE | MPO_INSERT_SEND_RIGHT | MPO_QLIMIT | MPO_STRICT | MPO_CONTEXT_AS_GUARD,
    .mpl = SYSCALL_QUEUE_LIMIT,
};
arc4random_buf(&guard_value, sizeof(guard_value));
mach_port_construct(mach_task_self(), &options, guard_value, &server->port);
guard_value = 0;   /* 建好后连 ksurface 自己也无法 unguard */
```

- `MPO_IMMOVABLE_RECEIVE` + `MPO_STRICT` + 随机 guard：接收权不可移动、不可被降级，防止被 guest 抢走或伪造消息。
- 线程池规模 = `CCGetMaximumPerformanceCores()`（性能核数量），每个核一个 `pthread` 跑 `syscall_worker`。

### 消息格式

`Surface/libkern/sys/worker.h`：

```c
typedef struct {                     /* guest → host */
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_ports_descriptor_t oolp;   /* 传入的 mach port（≤64 个） */
    uint32_t syscall_num;
    int64_t args[6];                        /* 只放标量，绝不放指针 */
    mach_msg_max_trailer_t trailer;         /* audit token */
} syscall_request_t;

typedef struct {                     /* host → guest */
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_ports_descriptor_t oolp;   /* 返回的 mach port（task port / fileport …） */
    int64_t result;
    errno_t err;
} syscall_reply_t;
```

`recv_buffer_t` 把上面结构放大一遍（`body[sizeof(syscall_request_t)]`）并留出 `mach_msg_max_trailer_t`，用 `vm_allocate` 分配，一个 worker 一块、可被 handler "认领"（见下）。

约定：**参数只走寄存器式标量**，任何缓冲区/字符串都由 host 用 task port 亲自读写（下节）。这不是风格问题，而是安全边界：guest 不能传一个"看起来像指针"的数。

### worker 主循环

`Surface/libkern/sys/worker.c::syscall_worker()`：

1. `mach_msg(..., MACH_RCV_MSG | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT), server->port, ...)` ——**显式索取 audit trailer**。
2. `syscall_get_caller_proc_snapshot()`：从 trailer 里取 `audit_token.val[5]`（pid）与 `val[7]`（pidv），`proc_for_pid_with_pidv()` 查表。注释：*"我们依赖 XNU 内核，去问进程自己是愚蠢的"*。→ **调用者身份由内核填，不可伪造**。
3. 校验消息头：必须是 `COMPLEX`，且 `msgh_bits` 的端口位恰为 `(SEND_ONCE, SEND)`；body 必须恰好 1 个 `MACH_MSG_OOL_PORTS_DESCRIPTOR` 且 `count <= 64`；否则 `EBADMSG`。
4. `proc_task_for_proc(..., TASK_KERNEL_PORT, &task)` 拿调用者的 task port（这一步把"调用者 = 谁"变成"我能读写谁的地址空间"）。
5. 查处理表（`SYSCALL_HANDLERS_LIMIT` 内、`os_unfair_lock` 保护），没有就 `ENOSYS`。
6. 清 `errno` 后调用 handler，签名固定：

```c
int64_t handler(task_t task, ksurface_proc_snapshot_t *proc_snapshot, recv_buffer_t **recv_buffer,
                int64_t *args, mach_msg_ool_ports_descriptor_t in_ports,
                mach_port_t **out_ports, uint32_t *out_ports_cnt, errno_t *err);
```

7. 收尾：若是普通返回，worker 自己 `syscall_send_reply()`；若 handler 把 `*recv_buffer` 置 NULL（"认领"了缓冲区），则由 handler 之后**异步**回复。`SYS_wait4`/`SYS_pectl` 的 UI 分支就是这么做的——否则 8 个阻塞的 wait4 会把 8 核的 syscall 服务全占死。注释直接写了这个理由。

`syscall_send_reply()` 的细节：`msgh_id = request + 100`（Mach 的 reply id 约定），要返回端口时挂一个 `MACH_MSG_OOL_PORTS_DESCRIPTOR`（`MOVE_SEND` + `MACH_MSG_PHYSICAL_COPY` + `deallocate`），发完 `mach_msg_destroy(request)`，需要时 `vm_deallocate` 归还缓冲区。

---

## 5. task port handoff：用异常端口把 task port 换出来

这是整个项目最核心的一招，README 里那句拗口的描述对应 `Surface/libkern/task_handoff.c` 与 `Surface/sys/compat/handoffep.c`。

### 原理

iOS 上 `task_for_pid()` 对普通进程被拒。但 **Mach 异常消息天然携带"出错进程的 task 控制端口"和"出错线程的 thread 端口"**（`EXCEPTION_DEFAULT` 投递时 `__Request__exception_raise_t` 里有 `task` 和 `thread` 两个 port descriptor）。于是：

> guest 把**自己的** breakpoint 异常端口设成一个自己造的 receive right，用 syscall 把该 receive right 交给 host，然后执行 `brk #1`；XNU 于是把这个"伪异常"连同 guest 的 task control port 一起投递给 host。host 只要收下并回一个 reply，就永久持有 guest 的 task port。

### guest 侧（`task_handoff.c` 的 `!HOST_ENV` 分支）

```c
mach_port_options_t opt = { .flags = MPO_PORT | MPO_INSERT_SEND_RIGHT };
thread_get_exception_ports(thread, EXC_MASK_BREAKPOINT, old_masks, ...);   /* 备份 */
mach_port_construct(mach_task_self(), &opt, 0, &exceptionPort);
thread_set_exception_ports(thread, EXC_MASK_BREAKPOINT, exceptionPort, EXCEPTION_DEFAULT, ARM_THREAD_STATE64);
liveshim_syscall(SYS_handoffep, exceptionPort);        /* MOVE_RECEIVE 交给 host */
__asm__ volatile ("brk #1" ::: "memory");              /* 触发伪异常 */
```

收尾：恢复原异常端口（逐个 `thread_set_exception_ports` 恢复）、`mach_port_deallocate`、`task_normalize()`，最后 `liveshim_syscall(SYS_waittask, getpid())` 等 host 确认 task port 已就位。

`task_normalize()`（同文件）是个小彩蛋：把 `mach_task_self()` 的 SEND right 引用数 dealloc 到 2，注释是"工具们（reveil 之类）总爱假装能永远检测到它"。

`brk #1` 后面那行 `success = true;` 的注释解释了为什么用内联汇编而不是 `__builtin_trap()`：让编译器不能把 `success = true` 优化掉。

### host 侧（同一函数 `HOST_ENV` 分支）

1. `mach_msg(MACH_RCV_MSG | MACH_RCV_TIMEOUT, ..., exceptionPort, 1000, ...)` 收请求，缓冲区用 `__Request__exception_raise_large_t`（1024 字节 union，够大）。
2. 校验头：必须 COMPLEX 且端口位为 `(SEND_ONCE, SEND)`；body 必须 `descriptor_count == 2`，且两个都是 `MACH_MSG_PORT_DESCRIPTOR`。
3. `mach_port_kobject()` 验证两个端口的内核对象类型：task 必须是 **`IPC_OTYPE_TASK_CONTROL`**（注释：aka IKOT_TASK、aka kernel task port），thread 必须是 **`IPC_OTYPE_THREAD_CONTROL`**。类型不对就失败——挡住"伪造一个 name port 蒙混"。
4. 用 thread 端口 `thread_get_state(ARM_THREAD_STATE64)` → `state.__pc += 4`（跳过 `brk` 指令，否则 guest 会反复触发或崩）→ `thread_set_state()`。
5. `mach_port_mod_refs(..., MACH_PORT_RIGHT_SEND, +1)` 给 task right 加引用，`*task = request.v.task.name`。
6. 回 reply（`msgh_id + 100`、`NDR_record`、`RetCode = kr`），`mach_msg_destroy`。失败路径也照样回 reply，只是 `RetCode` 是失败码。

### syscall 层（`handoffep.c`）

```c
sys_need_in_ports(1, MACH_MSG_TYPE_MOVE_RECEIVE);
kvo_wrlock(sys_proc_);
if(sys_proc_->task != MACH_PORT_NULL || sys_proc_->in_tfp_handoff) { ... goto out_failure_kill; }
sys_proc_->in_tfp_handoff = true;
kvo_unlock(sys_proc_);
exceptionPort = sys_in_ports[0]; sys_in_ports[0] = MACH_PORT_NULL;   /* 认领，避免被 reply 释放 */
syscall_send_reply(...);        /* 先回 guest，让它去 brk */
*recv_buffer = NULL;
kr = task_handoff(exceptionPort, &returnedTask);
...
pid_for_task(returnedTask, &pid); if(pid != proc_getpid(sys_proc_snapshot_)) → 释放并 kill
sys_proc_->task = returnedTask; in_tfp_handoff = false;
kvo_event_trigger(sys_proc_, kProcEventTypeWaitTask, 0);
```

三点值得记：

- **一个进程生命周期内 task port 只能初始化一次**（写锁下判 `task != NULL || in_tfp_handoff`），失败直接 `proc_kill(sys_proc_, SIGKILL)`，注释是"这不可能是合法失败"。所以这是一次性的、不可重来的信任建立。
- **顺序被刻意固定**：先回 reply 再收异常。否则 `task_handoff()` 阻塞等异常时，guest 还在等 syscall 的 reply，会死锁。
- `pid_for_task()` 回查是最后一道校验：拿到的 task 必须真的属于刚发起 syscall 的那个 pid。

### 为什么 guest 一启动就要做这件事

`Nyxian/LindChain/ProcEnvironment/Shims/environment.m::environment_init()`：

```
抬高 RLIMIT_NOFILE（iOS 默认 200 左右 → 65536/最大可用）
environment_posix_spawn_init(); environment_vfork_init(); environment_application_init();
while (liveshim_syscall(SYS_getppid) < 0) { relax() / usleep(100); }   /* 等 host 把本进程登记进进程表 */
task_handoff(MACH_PORT_NULL, NULL);                                     /* ← 上面那套 */
PEOverwriteExecutablePath(executablePath);
dlopen(vroot "/boot/rtpatch");                                          /* 可选运行时补丁 */
PEInsertLibrariesIfNeeded();                                            /* DYLD_INSERT_LIBRARIES */
LCBootstrapMain(executablePath, argc, argv);
```

`SYS_getppid` 在这里被当成"**登记探针**"用：host 还没为这个 guest 建好 `ksurface_proc` 时它会失败。

> **推测**：README 说 `brk` 之后"把 task 移到尊重我们 init 和对方数据的新地址空间"，代码里对应的是拿到 task port 之后对 guest 地址空间的改写/重映射（`PEOverwriteExecutablePath` 用 patchcache 里 `kCFBundleMainOffset` / `kNSBundleMainOffset` 之类的偏移，直接改写 **CoreFoundation/Foundation 内部 `mainBundle` 槽位**，让 `NSBundle` 以为自己是被当二进制加载的）。具体 remap 代码在 `LiveProcess/`（`NXCoWCache.h`、`NXLiveProcessDispatch.c`）与 patchcache 生成侧，我没有逐行读到，**因此这一段属于推断**：真实执行体是 LiveProcess.appex 的镜像，guest 的"我是谁"是靠改写 dyld/CF/NSBundle 的槽位伪造的。

---

## 6. guest 内存读写（copy in / out）

`Surface/libkern/sys/systm.c`，全部以"调用者的 task port"为句柄：

| 函数 | 实现 | 用途 |
| --- | --- | --- |
| `syscall_copy_in(task, size, kptr, src)` | `mach_vm_read_overwrite(task, src, size, kptr, &reply)`，并检查 `reply == size` | 从 guest 读固定大小数据到 host 栈/堆 |
| `syscall_alloc_in(task, size, src)` | `calloc` 清零后再 `copy_in`（注释：避免变成攻击面） | 读变长数据 |
| `syscall_copy_out(task, size, kptr, dst)` | `mach_vm_write(task, dst, kptr, size)` | 往 guest 写 |
| `syscall_copy_str_in(task, src, len)` | 按页读（`want = PAGE_SIZE - (addr & (PAGE_SIZE-1))`），逐段 `memchr('\0')`，跨越未映射页就失败，必要时 `realloc` 扩容，上限 `min(len,1024)+1` 起 | 读 C 字符串 |
| `syscall_payload_create(ptr, size, &addr)` | `mach_vm_allocate(host)`，可选 memcpy | 为返回端口在 host 侧准备一个数组，交给 OOL ports descriptor |

**这就是 README 里"yep out of the iOS processes and into them without assistance, this is not a typo"所指**：有了 task port，`mach_vm_read_overwrite` / `mach_vm_write` 可以对 guest 双向读写，不需要 guest 配合，也不需要 `vm_read` 的接收端配合。

### 样板：`SYS_sysctl`（`Surface/sys/host/sysctl.m`）

请求结构把指针都留成 `userspace_pointer_t`，host 侧一条条显式拷贝：

```c
typedef struct { int name[6]; u_int namelen; userspace_pointer_t oldp, oldlenp, newp; size_t newlen;
                 errno_t err; task_t task; ksurface_proc_snapshot_t *proc_snapshot; } sysctl_req_t;
```

- MIB 表 `sysctl_map[]` 精确匹配（前缀匹配，允许 namelen 更长），支持：
  `kern.hostname`、`kern.boottime`、`kern.msgbuf`（自定义 MIB `{CTL_KERN, 9999}`，注释"XNU BSD 里没给稳定标识"）、`kern.maxproc`、`kern.argmax`、`kern.proc.{all,pid,uid,ruid,session,pgrp}`、`kern.procargs2`。
- `sysctlbyname` 走 `sysctl_name_map[]`（只 6 项子集），名字先 `syscall_copy_str_in` 读到 host。
- `kern.proc.*` 的标准流程：先 `copy_in(oldlenp)` 拿用户缓冲长度 → `proc_list()` 在 host 侧组装 `kinfo_proc` 数组 → 若 `oldp == NULL` 只回写长度（POSIX 的两段式查询）→ 缓冲不够回 `ENOMEM` 并回写所需长度 → 够就 `copy_out` 整块再回写长度。
- `kern.procargs2` 不是真读 argv：用 `p_comm` **合成**一个 `argc=1` + comm + comm 的伪 argv 缓冲区（注释：`p_comm` 不是路径最后一段，FIXME: frida fix this）。
- 写路径 `kern.hostname` 需要 `HostManager` entitlement，写前用 `is_valid_hostname_regex()`（`regcomp` 一次，缓存）校验，然后落 `ksurface->host_info.hostname` 并写回 `NSUserDefaults` 的 `LDEHostname`。

### 样板：`SYS_ioctl`（`Surface/sys/host/ioctl.c`）

- 入参是一个 fileport（`MACH_MSG_TYPE_MOVE_SEND`），`tty_for_port()` 在 `tty_info` 树里找对应 tty，找不到 `ENOTTY`。
- **白名单**：`TIOCGETA/TIOCSETA/TIOCSETAW/TIOCSETAF/TIOCSPGRP/TIOCGPGRP/TIOCGWINSZ/TIOCSWINSZ/TIOCSCTTY`，其余 `ENOSYS`。
- `TIOCSETA*`：读入 `struct termios`，`pthread_suspend(tty->pump_thread)` → 改写 → `pthread_resume`（避免 pump 线程并发读）。
- `TIOCSPGRP` 要求 `tty->sid == 调用者 sid` 且新 pgrp 在同 session 内存在（`proc_pgrp_exists_in_session`）。
- `TIOCSCTTY`：要求 `pid == sid`（session leader），置 `tty->sid/sid`、给进程 `P_CONTROLT` 与 `e_tpgid`。
- `TIOCSWINSZ`：窗口尺寸变化时 `tty_kill(tty, SIGWINCH)`。

README 说 tty"只在 NXWindowSessionTerminal 创建时可用"，与这里"tty 只能通过 `SYS_openpty` 产生并被 host 登记"一致（`Surface/sys/host/openpty.c`）。

### 样板：凭据（`Surface/sys/cred/setuid.c`）

- `proc_is_privileged()` = 有 `ProcessElevate` **或** `ruid == 0`。
- `setuid`：特权 → 三个 uid 全改；否则目标 uid 必须等于当前 ruid/svuid 才允许改 euid。
- `seteuid` / `setreuid`：标准 POSIX 语义的新旧 id 组合检查；特权时 `setreuid` 会同步 svuid。
- 每次改动前后比对六个 id，**变了就置 `P_SUGID`**（`proc_set_sugid_if_applicable`）。`permit.c` 的 uid 检查要求目标没有 `P_SUGID`，于是"降权后的进程"不会因为 euid 相同而被同 uid 进程拿 task port。
- `SYS_loginctl` / `SYS_groupctl`（`Surface/sys/cred/loginctl.c`、`groupctl.c`）用 `Get/Set/Commit/Clear` 五个动作管理 `nyx.login_name` 与 `nyx.supplementary_groups[32]`——Linux 的 `login(1)`/`getgrouplist` 语义，被搬到了这张表上。

---

## 7. 谁在哪一层

| 角色 | 真实身份 | 代码位置 |
| --- | --- | --- |
| "kernel" / host | Nyxian.app 主进程（`com.cr4zy.nyxian`） | `Nyxian/LindChain/ProcEnvironment/Surface/**`，由 `HOST_ENV` 宏区分侧 |
| guest "进程" | `LiveProcess.appex` 的一个 NSExtension 实例 | `LiveProcess/`（执行体）、`Shims/`（guest 侧补丁）、`PEExtension.m`（host 侧创建） |
| "kext" | Nyxian 进程里的一个 Mach-O 映像 + `__ksurfacemod` 段 | `Surface/libkern/kxld/**`、`KextLoader/` |
| "设备" | host 容器里的普通文件 | `~/Documents/mntfs/…`（`surface.m` 末尾、`Surface/fs/**`） |

因此"微内核"的边界是：**host 是唯一持有所有 guest task port 的进程**；guest 之间互操作必须经过 host 的 syscall 服务端与权限判定。

---

## 8. 本节阅读缺口（未逐行读，结论已按此降级）

- `Surface/libkern/bsd/proc_info.h`（40 KB，`proc_pidinfo` 一族的结构定义）未读；`SYS_proc_info` 的实现只看到注册处，**libproc 兼容细节按 README 与结构存在推断**。
- `Surface/libkern/patch.h` / `LIBKERN_DEFINE_PATCHABLE` 的完整机制（脱壳/重定向、`LIBKERN_ORIG`）只从调用处反推。
- `Surface/fs/**`（`sandbox.m` 16 KB、`mount.c` 13 KB、`preserver.c` 14 KB）未逐行读；本文只用到 `trust.m` 里可见的接口名（`ksurface_fs_sandbox_copy_sandbox_extension_for_arbitary_path`、`ksurface_fs_install_kext_at_path`）。
- `Surface/libkern/sys/systm.c` 之外的 `libkern/relax.h`（`relax()`）、`CCGetMaximumPerformanceCores()`（来自 CommonCrypto/私有符号?）未展开。
- `Surface/cache/shimcache.*`：`RomGen.py` 内嵌的 ROM 版 shim 把 `ksurface_shimcache_append_code/build` 实现成"忽略/跳过"，说明 host 版会**在运行时编译 guest shim 源码**；host 侧实现未读，属**推测**（证据：`RomGen.py` 里的 `SHIMCACHE_M` 文本）。
