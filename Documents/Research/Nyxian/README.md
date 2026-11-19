# emexlab/Nyxian 实现原理笔记

研究目标：**机制**（它凭什么跑起来），不是功能清单。
仓库：https://github.com/emexlab/Nyxian ，main 分支（`ProjectNyxian/Nyxian` 会重定向到这里）。作者指名核心在 `Nyxian/LindChain/ProcEnvironment/Surface`，README 也是这么写的（"Everything I care about is located at `Nyxian/LindChain/ProcEnvironment/Surface`"）。

四篇子笔记：

- [surface.md](surface.md) —— 对象模型、进程表、权限判定、Mach IPC 服务端、task port handoff、guest 内存读写
- [trust-and-kext.md](trust-and-kext.md) —— NXT2 entitlement blob、Apple CS 互译、信任级别、kxld 加载 kext、NXROM001 发布签名
- [process-patches.md](process-patches.md) —— posix_spawn / vfork / sysctl / tty-ioctl / libproc / task_for_pid / setuid
- [build-and-run.md](build-and-run.md) —— Mac 构建、App 内 MDK 构建、两层签名、NSExtension 承载、BootHandoff、Recovery、KEXTs

---

## 一句话结论

Nyxian 不是"模拟器"，也不是"内核漏洞利用"。它是**在用户态搭了一套进程抽象，用 iOS 自带的两个合法机制把真实的第二进程造出来并彻底接管**：

1. **NSExtension** 提供"能 spawn 出进程"的唯一合法出口（`LiveProcess.appex`）；
2. **Mach 异常消息自带 task control port** 这一事实，让 host 无需任何内核补丁就拿到 guest 的 task port，从此可以任意读写它的地址空间、改它的线程状态；
3. 有了 task port，"内核 API"全部可以在 host 里**用真实现 + 伪数据**重做：进程表、sysctl、task_for_pid、凭据、tty、kext……

`README` 里那句 "we cannot intercept a arm64 supervisor call … by not intercepting a supervisor call we can still do most things we need to do" 就是这套方案的自我定位：**不拦 SVC，而是替换掉所有会做 SVC 的库函数入口，并把真正需要特权的那一步搬到 host 里做。**

---

## 分层与数据流

```
┌───────────────────────────────────────────────────────────────────────────┐
│ Nyxian.app （宿主进程，com.cr4zy.nyxian）                                  │
│                                                                           │
│  ┌─────────────────────────┐   ┌──────────────────────────────────────┐   │
│  │ IDE 层                  │   │ ksurface（"微内核"，用户态）          │   │
│  │ IDEBuilder/NXBuilder    │   │ ProcEnvironment/Surface/**            │   │
│  │ IDEConsole / IDE-       │   │  ├ mapping.h  全局 ksurface           │   │
│  │  LanguageServer …       │   │  ├ proc/      kvobject + radix 进程表 │   │
│  │      ↓ MDK              │   │  ├ sys/       系统调用实现            │   │
│  │  编译器 (LLVM-On-iOS)   │   │  ├ trust/     NXT2 / 信任 / 签名      │   │
│  │      ↓ zsign + NXT2     │   │  ├ fs/        mntfs + sandbox 扩展    │   │
│  │  可执行文件              │   │  ├ tty/       pty 对象                │   │
│  └─────────────────────────┘   │  ├ libkern/   kvo/radix/kxld/syscall  │   │
│                                 │  └ cache/     shimcache               │   │
│  ┌─────────────────────────┐   └──────────────────────────────────────┘   │
│  │ 服务层                   │        │                    ▲                │
│  │ PEProcessManager         │        │ 系统调用处理        │ Mach 消息      │
│  │ PEExtension (NSExtension)│        ▼                    │ (guarded port) │
│  │ PELaunchService(Registry)│   ┌─────────────────────────┴───────────┐    │
│  │ PEUserspaceManager       │   │ syscall workers (每性能核 1 个线程)  │    │
│  │ NXWindowServer           │   │ audit trailer 判定调用者 → handler   │    │
│  └─────────────────────────┘   └─────────────────────────────────────┘    │
└───────────────┬───────────────────────────────────────┬───────────────────┘
                │ beginExtensionRequestWithInputItems    │ task port
                │ (注入 syscall port / env / fd table)   │ (mach_vm_read/write
                ▼                                        │  thread_get/set_state)
┌───────────────────────────────────┐                    │
│ guest 进程 = LiveProcess.appex 实例│◄───────────────────┘
│                                   │
│ NXLiveProcessBootstrap → main     │
│ environment_init():               │
│   ├ RLIMIT_NOFILE 抬高            │
│   ├ 装 shim（litehook）           │
│   │   posix_spawn / vfork / LS*   │
│   ├ 轮询 SYS_getppid 等登记        │
│   ├ task_handoff(): 设异常端口 →   │
│   │   SYS_handoffep → brk #1      │
│   ├ 改写 executable / CFBundle /   │
│   │   NSBundle 槽位               │
│   ├ dlopen($NXROOT/boot/rtpatch)  │
│   └ LCBootstrapMain(argv)         │
│                                   │
│ 用户的程序（clang / make / bash）  │
│   每次 libc 调用 → Mach 消息 → host│
└───────────────────────────────────┘

文件系统：guest 看到的 / 由 host 的 mntfs + 每条路径一条 sandbox extension 拼出来
          （trust.m → fs/sandbox.m，真实数据在 host 容器 ~/Documents/mntfs/）
kext：   Nyxian 进程内的 Mach-O 映像（kxld 链入、__ksurfacemod 段给 kmod_info）
ROM：    RomGen.py 烘出 ksurface+WindowServer+NXSlotMain+示例 App，尾部 NXROM001 签名
```

---

## 六条核心机制（每条一句话 + 代码位置）

| # | 机制 | 一句话 | 位置 |
| --- | --- | --- | --- |
| 1 | **进程 = 真实进程 + 影子表** | 每个 guest 是 NSExtension 起的真进程；ksurface 里为它建一个 `ksurface_proc`（`kinfo_proc` + 权限位 + 父子契约），表用 radix tree 以 pid 索引 | `Surface/proc/def.h`、`proc/insert.c`、`proc/lookup.c` |
| 2 | **权限 = 能力位 + 可见性 + 血缘 + euid** | 看不见的进程对你不存在（同 session 才可见）；拿别人 task port 要求双方各有对应 entitlement；有 SUID 变化的目标不可碰 | `Surface/proc/permit.c`、`proc/list.c` |
| 3 | **task port = 异常消息的副产物** | guest 把自己 breakpoint 异常端口交给 host 后执行 `brk #1`，XNU 就把 `IKOT_TASK` 送到 host 手里；host 校验 `mach_port_kobject` 类型、跳过 `brk`、回 reply | `Surface/libkern/task_handoff.c`、`sys/compat/handoffep.c` |
| 4 | **系统调用 = Mach 消息 + 显式内存拷贝** | 参数只走标量；缓冲区由 host 用 `mach_vm_read_overwrite`/`mach_vm_write` 亲自搬；调用者身份取 audit trailer 的 pid+pidv | `Surface/libkern/sys/{core,worker,systm}.c` |
| 5 | **能力 = 自签名 blob（NXT2）** | Apple CS 只负责"能被系统执行"，NXT2 追加在文件尾、P-256 签名，装 ksurface 自己的 entitlement 字典；Apple 的 private entitlement 被逐条翻译成 NXT2 | `Surface/trust/{signing,apple,trust}.c/.m` |
| 6 | **fork = 快照-回滚** | 512 MiB arena 快照所有私有可写页 + fd/信号/cwd/线程状态，子逻辑在同地址空间里跑完再回滚，exec 推迟到回滚之后；pipe 用 spool 缓冲隔离 | `Shims/vfork.m` |

---

## 与常见方案的差别（读代码得出的对比）

| 方案 | 谁做特权操作 | guest 是什么 | Nyxian 的选择 |
| --- | --- | --- | --- |
| iSH / 用户态 Linux | 同进程内 syscall 翻译 | 一个 ELF 解释器 | 不做：guest 是真 Mach-O、真进程 |
| LiveContainer 类 | 宿主 App 内 dlopen | 同进程 | 不做：guest 独立进程，独立 task port |
| 越狱 tweak / 内核补丁 | 内核态 | 系统进程 | 不做：无内核补丁，纯用户态 |
| **Nyxian** | **宿主进程（持有所有 guest 的 task port）** | **真 iOS 进程，但"身份"由宿主伪造** | — |

"伪造身份"的几处具体表现：`p_comm` 取路径最后一段（`spawn.m`）、`getppid`/`getsid` 由表提供、`union mount` + sandbox extension 伪造 `/`（`fs/`）、`CFBundleMainBundle`/`NSBundle.mainBundle` 槽位被直接改写（`Shims/environment.m` + patchcache）。

---

## 阅读方式与覆盖范围

- 全部通过 GitHub REST contents API 列目录 + raw.githubusercontent.com 取正文，单次约 32 KB，超长文件用 offset 续读。
- 完整读过（引擎级）：`ksurface_abi.h`、`ksurface_config.h`、`README.md`、`Makefile`、`Surface/{surface,mapping,limits,lock}.{h,c}`、`Surface/libkern/{task_handoff.c,obj/defs.h,sys/{core.c,worker.c,worker.h,systm.c,systm.h},kxld/kxopen.c}`、`Surface/proc/{def.h,lookup.c,list.c,permit.c,spawn.m}`、`Surface/sys/{syscall.h,host/{sysctl.m,ioctl.c},compat/{handoffep.c,task_for_pid.c,pectl.m,sign.m},cred/setuid.c}`、`Surface/trust/{entitlement.h,trust.h,trust.m,apple.h,apple.c,signing.h,signing.c}`、`Shims/{posix_spawn.m,environment.m}`、`PEExtension.m`、`PEProcessManager.m`、`KextLoader/{PEKext.m,PEKextLoader.m}`、`IDEBuilder/NXBuilder.swift`、`BootHandoff/NXBootArgs.h`。
- 部分读过（截断）：`Shims/vfork.m`（77 KB，前 ~32 KB）、`RomGen.py`（115 KB，前 ~32 KB）。
- 只列目录、未读正文：`Surface/fs/**`、`Surface/tty/**`、`Surface/cache/**`、`Surface/libkern/{radix,bsd/proc_info.h,obj/*.c,kxld/*.c 除 kxopen}`、`Shims/{LSApplicationWorkspace.m,application.m,proxy.m}`、`LiveProcess/**`、`Server/**`、`KextLoader/PEKextLoader` 之外的 `PEDependency`、`LiveContainer/**`、`Recovery/binpack/**`、`TrustStore/`（根 listing 里不存在，与 `Makefile` 引用不一致）、`Daemons/`、`Frameworks/`。
- **没有失败到无法继续的抓取**：所有 `api.github.com/contents` 与 `raw.githubusercontent.com` 请求均返回 200。唯一"取不到"的是 `TrustStore/` 目录（`Makefile` 与 `RomGen.py` 都引用它，但根目录 listing 中没有），以及 `LLVM-On-iOS`（submodule，按题目要求不深入）。

## 推断清单

各篇末尾都单列了推断项，汇总：

1. README 中"brk 之后把 task 移到新地址空间"的实际实现（改写 CF/NSBundle 槽位 + 可能的 remap）——`surface.md` §5。
2. shimcache 在 App 版会**运行时编译 guest shim 源码**——证据是 `RomGen.py` 里 ROM 版把 `ksurface_shimcache_append_code/build` 实现成空（`surface.md` §8）。
3. `kxld` 用 pseudo kext 提供未解析符号（`KMOD_FLAG_ALLOW_UNRESOLVED` + `pseudo.c` 存在）——`trust-and-kext.md` §9。
4. `SYS_proc_info` / libproc 的具体 flavor 支持——`process-patches.md` §5。
5. `vfork.m` 的 fork/vfork/execve 入口与 `pending_exec` 执行时序（文件过长未读完）——`process-patches.md` §9。
6. `NXBootGetArguments` 由 ROM 引导器（NXSlotMain）提供——`build-and-run.md` §5。
7. `NXCoWCache` 用于在多个 guest 间共享初始内存镜像——`build-and-run.md` §4。
8. `KEXTs/KRW` 是"直接读写 guest 内存的调试工具"——`build-and-run.md` §6。

## 阅读时注意到的两处代码问题（非本文重点，但值得记）

- `KextLoader/PEKextLoader.m` 在依赖图有环时 `return nil;`，而这个函数的签名是 `BOOL`——调用方会把 `nil`（=0，false）当成"加载失败"但拿不到原因字符串。
- `Surface/trust/trust.m` 的 `trust_resign_with_fd` 路径上有一条作者的 `FIXME`：用 RootCA 密钥验过的 blob 在重签前**没有**校验 CS 哈希与 cdhash 是否吻合。
