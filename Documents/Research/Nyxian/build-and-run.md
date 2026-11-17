# 构建与运行链

> 从"在 Mac 上编出 Nyxian.app"到"在 iPhone 上编出的程序被 ksurface 托管执行"，中间有四段互不相同的机制：
>
> 1. Mac 侧：`Makefile` + `LLVM-On-iOS` 子模块 + `xcodebuild`；
> 2. App 内 IDE：`NXBuilder` + `MobileDevelopmentKit`（MDK）编译链接；
> 3. 签名：zsign（Apple CS）+ NXT2 blob（ksurface 能力）；
> 4. 执行：`LiveProcess.appex` 经 NSExtension 起进程，再由 ksurface 接管。

---

## 1. Mac 侧构建（`Makefile`、`Config.xcconfig`、`Nyxian.xcodeproj`）

仓库根的 `Makefile` 只服务"把 App 编出来并打 ipa"，默认目标 `all = clean check compile package-app clean`：

- `NXNAME := Nyxian`、`NXVERSION`（从 `Config.xcconfig` 的 `VERSION=` 行 awk 出来）、`NXBUNDLE := com.cr4zy.nyxian`。
- `check`：强制 macOS（`uname -s == Darwin`）、完整 Xcode（检查 `xcode-select -p` 下的 `Platforms/iPhoneOS.platform`，否则给 App Store 链接）、`brew` 以及 `pkgconf cmake libarchive dpkg openssl ninja`。`CHECK_DEPS=0` 可跳过（CI 用）。
- `compile` 的**前置依赖**是关键：
  ```make
  Frameworks/CoreCompiler/CoreCompilerSupportLibs:
      cd LLVM-On-iOS; $(MAKE)
      rm -rf Frameworks/CoreCompiler/CoreCompilerSupportLibs/
      cp -r LLVM-On-iOS/CoreCompilerSupportLibs Frameworks/CoreCompiler/CoreCompilerSupportLibs/
      cp -r LLVM-On-iOS/LLVM.xcframework Frameworks/CoreCompiler/CoreCompilerSupportLibs/LLVM.xcframework
  ```
  → **`LLVM-On-iOS` 是一个 git submodule**（`.gitmodules`、根 listing 里显示为 submodule 链接），它自己构建出 `CoreCompilerSupportLibs` 与 `LLVM.xcframework`，然后被拷进 `Frameworks/CoreCompiler/` 作为 App 内编译器的二进制后端。仓库里对它的唯一"用法"就是这个 Makefile 目标 + `NXRemoteCompiler`/`MDK` 的链接关系，**本文不深入它的构建**。
- `compile`：`./version.sh`（`chmod +x` 后执行，生成版本号）→
  ```sh
  xcodebuild -project Nyxian.xcodeproj -scheme Nyxian -configuration Release \
      -destination 'generic/platform=iOS' -archivePath build/Nyxian.xcarchive archive \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
  ```
  **完全不签名**：产物靠后续 zsign + NXT2 在设备上签（或由用户用自己的证书签）。
- `package-app`：`cp -r build/Nyxian.xcarchive/Products/Applications Payload && zip -r Nyxian.ipa ./Payload`。
- 另外三个与"启动/分发"相关的目标：
  - `recovery-binpack`：`python3 Recovery/binpack/mkbinpack.py --bootstrap ../emexOS/bootstrap --vroot-libs ../emexOS/.rompkg/ROM/binpack/usr/lib [--debs Recovery/binpack/debs/*.deb] --output Shared/Recovery/binpack.zip`，注释说这个 zip"由 TWRP 终端解包"。即从 **emexOS** 的 procursus bootstrap 与 vroot 库打出一个最小用户态，用于恢复/引导场景。
  - `truststore-root` / `truststore` / `truststore-bundle`：`python3 -I TrustStore/truststore.py`，产出 `build/truststore/truststore.plist`（上线到 `emexlabs.org/switzach/truststore/`），并可拷进 `Shared/TrustStore/` 供首次启动离线使用。
- `fetchtruststore.sh`（1.4 KB）在根目录，配套上面。

---

## 2. App 内的编译链接：`NXBuilder`（`Nyxian/LindChain/IDEBuilder/NXBuilder.swift`）

Nyxian 的 IDE 侧不自己写编译驱动，而是基于 **MobileDevelopmentKit**（`import MobileDevelopmentKit`）——仓库里没有 MDK 的源码，它是外部依赖（framework）。

### 初始化（`init?(project:)`）

1. `project.reload()`；`project.syncFolderStructureToCache()`（把工程目录结构同步进 cache 目录）。
2. 打开 `cache/debug.json` 的 `DebugDatabase`（诊断消息库）。
3. **远程编译优先**：`useRemoteServiceIfAvailable`（`NSUserDefaults` 键 `LDERemoteCompileService`，默认 true）→ `NXRemoteCompiler.new()`；若它能 `setupDependencyScanner(withArguments: compilerFlags)`，就用它的 `MDKDependencyScanner`，否则用本地 `MDKDependencyScanner`。→ 即**同一套依赖扫描/编译既能本地跑也能交给 host 上的 `MobileDevelopmentService` 守护进程**（`Surface/trust/trust.m` 里那条 `boot/libexec/MobileDevelopmentService` 白名单正是它）。
4. `NXPhaseEngine(project:)` + `NXPhaseRunner(engine:)`：把构建拆成"阶段（phase）"执行；失败抛错并写进 debug.json。
5. **增量判定**：
   ```swift
   let argsString = swiftFlags.joined(" ") + compilerFlags.joined(" ") + " \(linkFrameworksAutomatically)"
   if incrementalBuild, let args = try? String(contentsOf: cache/args.txt) { projectDirty = args != argsString }
   else { projectDirty = true; database.clearDatabase() }
   ```
   `NSUserDefaults` 键 `LDEIncrementalBuild` 默认 true。→ 增量粒度是"**整份编译参数变没变**"，不是逐文件依赖图（`DebugDatabase.reuseDatabase()` 可能承担更细的复用，源码不在仓库里）。
6. 生成工程缓存。

### 五个阶段（`buildProject` 里的 `flow`）

```swift
(nil, try builder.headsup(buildType:)),   // 版本/目标合法性检查
(nil, try builder.clean()),               // 删 .o/.tmp/Resources/Config 与旧 Payload
(nil, try builder.prepare()),             // 组装 bundle
(nil, try builder.build()),               // 跑 phases
("arrow.down.app.fill", try builder.install(...))  // 签名 + 安装/导出
```

- **`headsup`**：只允许 `schemeKind ∈ {app, utility, kSurfaceKext}`；用 `MDKOSVersion` 比较 deployment target，必须落在 `NXOSVersion.NXOSVersionSupportedBuildVersions` 的首末之间；`buildType == .run` 时 target 版本不能高于宿主 iOS 版本。
- **`clean`**：`LDEFilesFinder(project, ["o","tmp"], ["Resources","Config"])` 找出来删；`.app` 再删 `payloadURL` 与 `packageURL`。
- **`prepare`**：
  - `.app`：建 `Payload/`，把 `Resources/` 拷成 `bundleURL`，用 `PropertyListSerialization` 把 `projectConfig.infoDictionary` 写成 `Info.plist`；
  - `.kSurfaceKext`：只建 bundle 目录 + `Info.plist`。
- **`build`**：`phaseRunner.runPhases()`，成功后写 `cache/args.txt`。
- **`install`**：见 §3。

### 导出

`buildType == .export` 时：kext → 重新 zip `Payload`；其它 → `trust_nxt2_sign(..., signBlob: false)`（不带签名，只挂 entitlement 字典），`.app` 再 `zipDirectoryAtPath(payloadURL, packageURL, true)`。这就是 README 里"Signing executables"之外的那条"导出未签名/仅带权限的包"路径。

---

## 3. 签名：两层，缺一不可

`NXBuilder.install(buildType:)` 是理解这层的最好入口：

| schemeKind | Apple CS | NXT2 | 之后 |
| --- | --- | --- | --- |
| `.app` | `LCUtils.signAppBundle(withZSign:)`（异步 + 信号量等待） | 若 `projectConfig.signMachOWithNyxianEntitlements`：`trust_nxt2_sign(machoURL, entitlementsConfig.dictionary, true, nil)` | `LDEApplicationWorkspace.installApplication(atBundlePath:)` |
| `.utility` | `LCUtils.signMachO(at:)`（会 patch） | 同上 | `LDEApplicationWorkspace.fastpathUtility(path)` → 返回可直接执行的路径 |
| `.kSurfaceKext` | 先把 `filetype` 改成 `MH_KEXT_BUNDLE`，再 `LCUtils.signMachOWithoutPatch(at:)` | **强制** `trust_nxt2_sign(path, ["org.emexlabs.nyxian.ksurface.kernelextension.loading": true], true, nil)` | `vnode_refresh_with_path()` → `ksurface_fs_install_kext_at_path(bundleURL)` → `PERestartSelf()` |

`.run` 之前先 `checkSigningSetup()`：**没有证书/描述文件就根本不允许 run**（抛"Code signing is not properly set up"）。这解释了为什么"Nyxian 需要用户自己的开发者证书"——Apple CS 这一层必须由用户的证书完成，Nyxian 只负责第二层。

两个签名工具的来源：

- `LCUtils` / `LCMachOUtils` / `LiveContainer/ZSign/zsigner`（`Nyxian/LindChain/ProcEnvironment/LiveContainer/`，以及 `Frameworks/` 下的 LiveContainer 兼容层）：zsign 移植版，产出标准 Apple CS（含 `LC_CODE_SIGNATURE`、CodeDirectory、CMS/ad-hoc）。
- `trust_nxt2_sign` / `trust_nxt2_read`（`Surface/trust/signing.c`，细节见 `trust-and-kext.md`）。

---

## 4. 执行：NSExtension 承载（`Nyxian/LindChain/ProcEnvironment/PEExtension.m`）

iOS 上 App 不能 `fork`，也不能创建任意子进程；**唯一能合法产生"第二个进程"的机制是 App Extension**（系统为你 spawn）。Nyxian 把它当成进程工厂。

### 起一个 guest 的完整流程（`PESpawnFBProcess`）

1. `PEGetLiveProcessBundle()`：`NSBundle.mainBundle.builtInPlugInsPath + "/LiveProcess.appex"`（`dispatch_once` 缓存）。→ 仓库根的 `LiveProcess/` 目录就是它：`main.c`、`Info.plist`、`LiveProcess.entitlements`、`NXLiveProcessABI.h`、`NXLiveProcessBootstrap.h`、`NXLiveProcessBroker.h`、`NXLiveProcessDispatch.c`、`NXCoWCache.h`。
2. `PEGetNSExtension()`：`[NSExtension extensionWithIdentifier:bundleIdentifier error:]`；注释："每个进程必须一个 NSExtension，这类的设计比较奇怪"。
3. **PEExtensionHasGetTaskAllowed()**：读 `[extension _plugIn].entitlements[@"get-task-allow"]`。→ LiveProcess.appex 必须带 `get-task-allow`，否则 host 拿不到它的 task port（与 `task_handoff` 的机制严格相关）。
4. **填输入项**（`NSExtensionItem.userInfo`，即 guest 的"启动参数"）：
   - `PESyscallPort`：`PEMachPort` 包装 `syscall_server_get_port(ksurface->sys_server)`，`sendOnce = YES`（guest 只能拿到一个 send-once 引用，不能自己复制）；
   - `PEEndpoint`：`[Server getTicket]`，注释标 deprecated（未来的 guest→host 全走 syscall 服务端）；
   - `PEEnvironment`：默认补 `HOME` / `CFFIXED_USER_HOME` = `NXBootstrap.rootfsURL`，`TMPDIR` = `<rootfs>/tmp`；
   - `DEBUG && KSURFACE_KLOG_ENABLE_PROCESSES` 时再塞 `PEFileTable`，把 guest 的 stdout/stderr 接到 host 的 `kfd`（kmsg）。
5. `beginExtensionRequestWithInputItems:` → `NSUUID`；失败就 `_kill:SIGKILL`。
6. `pidForRequestIdentifier:` 拿 pid；再 `RBSProcessHandle`/`RBSProcessPredicate` 取 `auditToken`，并**校验 `at.val[5] == pid`**（防 pid 竞态）。
7. `FBProcessManager registerProcessForAuditToken:` 得到 `FBProcess`，把 `nsExtension` 与 request `identifier` 用 `objc_setAssociatedObject` 挂上去（`FBProcess (ProcEnvironment)` 分类）。

`PEProcessManager.m` 再用这个 `FBProcess` 造 `PEProcess`，按 pid 存字典，并作为 observer 处理 `didExitWithWait4Code:`。`spawnProcessWithBundleIdentifier:withItems:withKernelSurfaceProcess:doRestartIfRunning:` 会从 `LDEApplicationWorkspace` 取 `LDEApplicationObject`，填 `PEExecutablePath`、`PEArguments`、`PEEnvironment`（`HOME/CFFIXED_USER_HOME` = 容器，`TMPDIR` = `<容器>/Tmp`）、`PEWorkingDirectory` = `<容器>/Documents`。

### guest 侧接手（`Shims/environment.m`）

`environment_init(exec, executablePath, argc, argv)` 是 LiveProcess 的 main 里最先跑的东西（顺序见 `surface.md` §5）：抬 `RLIMIT_NOFILE` → 装 shim → **轮询 `SYS_getppid` 等 host 登记** → `task_handoff()` → 改写可执行路径/`CFBundle`/`NSBundle` 槽位 → 可选 `dlopen(NXROOT/boot/rtpatch)` → 处理 `DYLD_INSERT_LIBRARIES` → `LCBootstrapMain()`。

`NXCoWCache.h`（`LiveProcess/`）名字指向"写时复制缓存"：**推测**用于把 guest 的初始内存镜像共享给多个实例（例如多个 clang 进程共享同一份 dyld 缓存），我没有读到它的实现。

---

## 5. `BootHandoff`：启动参数

`BootHandoff/NXBootArgs.h`（唯一文件）不参与 App 构建，是**给 bootloader / 早期启动环境用的一套头文件**：

- `const char *NXBootGetArguments(void)`：由 bootloader（0.11.6.2+）`dlsym` 提供；`NXBootArgsCopy()` 先用 `dlsym(RTLD_DEFAULT, "NXBootGetArguments")`，拿不到就**回退读旧版 NSUserDefaults 键**：
  ```c
  nyxian.boot.verbose            → " -v"
  nyxian.boot.kextLoading        → " -x"（关掉时）
  nyxian.boot.log.obfuscated     → " klog_obfuscate=0"
  nyxian.boot.sandbox.filesystems→ " fs_sandbox=0"
  ```
  注释明确：0.11.6.1 没有 boot arg host，这套回退让两种版本"读起来一样"。
- 词法工具：`NXBootArgsNextToken`（按空格/tab/换行切）、`NXBootArgsHasFlag`（独立 token，如 `-v`）、`NXBootArgsGetValue`（`key=value`，取**最后一个**）、`NXBootArgsGetBool`（1/yes/true/on）。
- 四个已知参数：`-v`（verbose）、`-x`（不加载 kext）、`klog_obfuscate`、`fs_sandbox`。

注意 `fs_sandbox` 与 `Shims/environment.m` 里读的 `nyxian.boot.sandbox.filesystems`、`trust.m` 里读的同一个键是**同一个开关**：BootHandoff 负责"早启动时读"，运行期各处再读 NSUserDefaults。这就是 `trust-and-kext.md` §5 里"总开关关掉就把整个 rootfs 读写打开"的入口。

**推断**：`NXBootGetArguments` 的提供方与 `RomGen.py` 生成的 ROM/NXSlot 引导器是同一套（RomGen 提到 ROM 里有 `NXSlotMain`），但引导器源码不在本仓库，**未能证实**。

---

## 6. `Recovery/binpack` 与 `KEXTs/` 的角色

### `Recovery/binpack`

`Makefile` 的 `recovery-binpack` 目标调用 `Recovery/binpack/mkbinpack.py`，输入是 **emexOS** 的 `bootstrap/` 与 `.rompkg/ROM/binpack/usr/lib`（vroot 库），可选 `Recovery/binpack/debs/*.deb`（注释举例 nano/curl/wget），输出 **`Shared/Recovery/binpack.zip`**。Makefile 注释："由 TWRP 终端解包（unpacked by the TWRP terminal）"。

→ 这是一份**最小用户态 bootstrap**（procursus 风格），用途是当 Nyxian 还没起来、或系统需要恢复时，给一个能跑 shell/包管理器的环境。它与 ksurface 的 guest 环境是**两条不同的路径**：binpack 是"真 rootfs 上的真进程"，ksurface guest 是"NSExtension 里伪装的进程"。`Shared/Recovery/` 是随包分发的资源目录，`Shared/` 下还有 `Protocol/`、`RoothideRoot.swift`、`XPCShim/`（roothide 引导相关）。

### `KEXTs/`

10 个 zip，每个是一个 kext bundle：`BaseEntitlementLoader`、`BasePreferenceLoader`、`ColorWinMix`、`CrashReporter`、`KRW`、`NyxianMount`、`RelHomeMount`、`SharedTheme`、`TestTweak`、`UISingleFlight`。

它们的**角色**（结合 `trust-and-kext.md` §7）：

- 不是 iOS 内核扩展，而是 `MH_KEXT_BUNDLE` 形态的用户态模块，被 kxld 链入 **Nyxian 进程**；
- 提供"给 ksurface 加能力"的东西：`BaseEntitlementLoader`（给 App 装 entitlement 预设）、`BasePreferenceLoader`（设置项）、`NyxianMount`/`RelHomeMount`（挂载视图）、`UISingleFlight`/`ColorWinMix`/`SharedTheme`（窗口/主题行为）、`CrashReporter`（崩溃上报）、`KRW`（名字指向"kernel read/write"，在用户态语境里应是直接读写 guest 内存的调试工具）、`TestTweak`（示例）。
- 它们必须同时有 Apple CS 与带 `org.emexlabs.nyxian.ksurface.kernelextension.loading` 的 NXT2 blob 才能被加载（`PEKext.initWithPath:`）。

`KEXTs/*.zip` 本身只有 1.8–20 KB，说明它们是**极小的 Mach-O + `__ksurfacemod` 段 + Info.plist**，不是真正的内核代码。

---

## 7. 分发与自举：`RomGen.py` 与 `version.sh`、`superslotfix.sh`

- `version.sh`（1.4 KB）：被 `Makefile` 的 `compile` 调用，写版本号（具体内容未读）。
- `superslotfix.sh`（700 B）：名字指向 "superblock slot fix"，具体未读。
- `RomGen.py`（115 KB）：见 `trust-and-kext.md` §8。它的 `generate` 子命令会从一份 Nyxian checkout **烘一个 ROM 模板**（注释原文："bakes a ROM template from a Nyxian checkout (the kernel surface, the window server, an NXSlotMain and a Hello app)"），即 **ksurface + WindowServer + 引导 slot + 示例 App** 组成一个可引导镜像；`sign` 打 `NXROM001` 尾部签名 + `NXRomFiles.plist`；`verify` 用 TrustStore；`prove` 用于向 Developer Portal 证明私钥归属；`digest` 给 TSS 登记安装票据。
- 我在 `RomGen.py` 里还看到它**内联生成**了几份源码（`SHIMCACHE_M`、`LDE_APPLICATION_OBJECT_M` 等），说明 ROM 版是一个"裁剪过的 host"：例如 shimcache 在 ROM 版里是空实现（"no host-side compiler; shimcache build skipped"），而 App 版会真的编译 guest shim 源码。

---

## 8. 一条端到端的时序（把四段串起来）

```
用户点 Run
  └─ NXBuilder.install(.run)
       ├─ checkSigningSetup()                    用户证书就绪？
       ├─ LCUtils.signAppBundle / signMachO      zsign → Apple CS
       ├─ trust_nxt2_sign(entitlements, true)    本机私钥 → NXT2 blob
       └─ LDEApplicationWorkspace.installApplication  → 注册到宿主 workspace
              │
              ▼  （用户从启动器点开 / pectl OpenBundleIdentifier）
       PEProcessManager.spawnProcessWithBundleIdentifier
              └─ PEExtension.PESpawnFBProcess
                   ├─ NSExtension(builtInPlugInsPath/LiveProcess.appex)
                   ├─ 注入 PESyscallPort / PEEndpoint / PEEnvironment / PEFileTable
                   ├─ beginExtensionRequestWithInputItems → 系统 spawn 进程
                   └─ RBSProcessHandle + auditToken → FBProcess → PEProcess(pid)
              │
              ▼  （guest 进程里）
       LiveProcess main → environment_init
              ├─ 装 posix_spawn/vfork/LS shim
              ├─ 轮询 SYS_getppid 等 host 登记
              ├─ task_handoff(): 设 breakpoint 异常端口 → SYS_handoffep → brk #1
              │     └─ host: 从 Mach 异常消息里取 IKOT_TASK → ksurface_proc.task
              ├─ 改写 executable path / CFBundle / NSBundle
              └─ LCBootstrapMain → 用户的 main()
                     │
                     ▼  （用户的程序调用 libc）
              posix_spawn → SYS_sign / proxy spawn / SYS_waittask
              sysctl      → host 组装 kinfo_proc → mach_vm_write 回 guest
              task_for_pid→ host 权限判定 → 端口描述符回传
```

---

## 9. 本节的推断与缺口

- `MobileDevelopmentKit`、`NXRemoteCompiler`、`NXPhaseEngine` 的实现不在仓库里（外部 framework / 二进制），**phase 划分与增量粒度只能从 `NXBuilder.swift` 的调用面推断**。
- `LLVM-On-iOS` 是 submodule，`Makefile` 里只有"`make` 出 `LLVM.xcframework` + `CoreCompilerSupportLibs`"这一层用法；其内部的 clang/ld64/Swift 驱动、SDK 打包方式未看，按要求不深入。
- `LiveProcess/` 只列了目录，`main.c`、`NXLiveProcessDispatch.c`、`NXCoWCache.h` 未读；guest main 的引导细节（`LCBootstrapMain` 内部）**属推断**。
- `NXBootGetArguments` 的提供方（bootloader / NXSlotMain）源码不在本仓库，已在 §5 标注。
- `Recovery/binpack/mkbinpack.py`、`version.sh`、`superslotfix.sh`、`TrustStore/` 未读（`TrustStore/` 甚至不在根 listing 里，与 `Makefile` 的引用不一致）。
- `RomGen.py` 115 KB，我只读了文件头与 `genkey/sign/verify/info/prove/digest` 的实现、以及 `file_hash`/`nxt2_plist` 的解析逻辑；`generate`（ROM 模板烘焙）的正文未读，因此"ROM 里具体放了哪些文件"来自文件头注释而非代码。
