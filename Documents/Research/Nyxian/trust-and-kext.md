# 信任、签名与 kext 加载

> 路径相对仓库根 https://github.com/emexlab/Nyxian。两套**互不相同**的信任链在这里并存，先分清：
>
> 1. **NXT2**：给"guest 可执行文件"用的自造 entitlement blob，跟 ksurface 的运行时权限模型直接对接。代码在 `Nyxian/LindChain/ProcEnvironment/Surface/trust/`。
> 2. **NXROM001**：给"Nyxian 自己的 ROM / 启动产物"用的发布签名，配 emexLabs 的 TrustStore。工具在 `RomGen.py`、`TrustStore/`、`fetchtruststore.sh`。
>
> 另一条独立轴是 **kxld**：把已通过 NXT2 校验的"kext"链入 Nyxian 进程并执行，代码在 `Surface/libkern/kxld/` 与 `KextLoader/`。

---

## 1. 为什么需要 NXT2

guest 可执行文件要在 iOS 上被 `posix_spawn` 起来，必须有一份 **Apple 格式的代码签名**（ad-hoc 也行，因为 App 自己有 `get-task-allow`）。但 Apple 的 CS blob 里放的是 **Apple entitlement 名字**（`get-task-allow`、`platform-application`、`com.apple.private.security.no-sandbox`…），ksurface 需要的是**自己的**能力位（`TaskForPid`、`ProcessSpawn`、`LoadKEXT`…），而且这些名字在 Apple CS 里根本表达不了（也没有对应字段）。

NXT2 的做法：**在文件末尾追加一段自签名的 blob**，装的是 ksurface 自己的 entitlement 字典；Apple CS 保持原样（只用来让 dyld/内核接受这个二进制）。于是"能被系统执行"和"在 Nyxian 里拥有哪些能力"被拆成两份签名。

---

## 2. NXT2 blob 的物理格式

`Surface/trust/entitlement.h`（结构）+ `Surface/trust/signing.h`（常量）：

```c
struct __attribute__((packed)) ksurface_nxt2_blob_header {
    char     cdhash[USER_FSIGNATURES_CDHASH_LEN];   /* 20 字节，被签内容的一部分 */
    uint64_t nonce;                                 /* 随机，抬高构造难度 */
    size_t   plist_len;
    const char plist_data[];                        /* 变长 entitlement plist（XML） */
};

struct __attribute__((packed)) ksurface_nxt2_blob_footer {
    size_t  mac_len;      /* 实测 8..72 */
    uint8_t mac[72];      /* ECDSA P-256 签名（DER） */
};

#define APPEND_TAG_NXTR "NXTR"   /* 旧格式（走 entitlements API），只用于识别与剥离 */
#define APPEND_TAG_NXT2 "NXT2"
```

文件布局（`signing.c::trust_nxt2_sign_fd` / `trust_nxt2_read_fd`）：

```
[ 原始 Mach-O ................ ][ header + plist ][ footer ][ uint32 len ][ "NXT2" ]
                                  └──── 被签名的范围（plist_len）────┘
```

- **尾部 4 字节是 tag**，往前 4 字节是 `len`（= header+plist+footer 的总长）。所以读取只需 `lseek(-4, SEEK_END)`。
- **被签名的范围** = `offsetof(header, plist_data) + plist_len`，即"cdhash + nonce + plist_len + plist 正文"。footer 不签（它本来就是签名）。
- `trust_remove_blob_fd()`：按同样的尾部布局 `ftruncate()` 掉整段，用于重签前"切到 EOF"。NXTR 与 NXT2 都在剥离范围内。

### 签名算法

`signing.c`（OpenSSL，`d2i_PrivateKey(EVP_PKEY_EC)`）：

- 曲线 **prime256v1 (P-256)**；
- `EVP_DigestSignInit(..., EVP_sha256(), ..., priv)` + `EVP_DigestSign(mdctx, footer->mac, &mac_len, header, header_size)`；
- 私钥来源两种：
  - **host 内**：`get_static_kernel_key(&p, &p_len, NULL, NULL)`——安装期生成的一对密钥，私钥在 nyxian 自己的 keychain 里，公钥缓存在 `ksurface->pub_key`（`surface.m::ksurface_kinit_get_keys`）；用后 `OPENSSL_cleanse` 清零。
  - **`nxtool` 离线工具**（`__NXTOOL`）：从 `priv_der_path` 读 DER 私钥（`O_NOFOLLOW`、必须是常规文件、≤64 KB）。
- 不签名时（`signBlob == false`）：cdhash 全零、`mac_len = 0`、mac 全零——只承载 entitlement 字典，不防篡改。**导出的 deb/ipa 走这条路**（见 `build-and-run.md`：`trust_nxt2_sign(..., false, nil)`）。

### 校验（`trust_nxt2_read_fd`）

1. 读 tag，非 `NXT2` → `KERN_FAILURE`。
2. 读 `len`，校验：`len >= min_blob`（header 固定部分 + footer）且 **`len <= PAGE_SIZE`**（注释：否则可能是内存耗尽攻击）。
3. 读入整段 blob，校验 `mac_len <= 72`、`plist_len <= 剩余空间`。
4. `plist_data` → `CFPropertyListCreateWithData` 且必须是 dictionary → `result->isValid = true`。
5. 重算 `CDHashOfMachO()`（`trust/cdhash.c`，对去掉签名后的内容算 CDHash）与 blob 里的 cdhash 比对 → `isCdHashValid`。
6. 仅在 `isCdHashValid && isValid` 时才做签名验证（省一次昂贵运算）：`d2i_PUBKEY(ksurface->pub_key)` → `EVP_DigestVerify(..., EVP_sha256())` → `isSigned`。
7. `HOST_ENV` 额外一步：`ksurface_keychain_match(blob_footer, blob_header)` 成功但静态密钥验不过 → `needsResign = true`（`trust/keychain.m`，`ksurface_keychain_update()` 在 `ksurface_kinit` 里加载）。这是给"供应商用 RootCA 私钥签的 blob"留的口子。

`ksurface_nxt2_t` 的四个布尔量就是全部结论：`isValid`（能解析）、`isSigned`（自签通过）、`isCdHashValid`（绑定了这个二进制）、`needsResign`（要用本机密钥重签）。

---

## 3. Apple CS → NXT2 的互译

`Surface/trust/apple.c::CopyAppleCSEntitlementsForPath()`：

```c
SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
SecCodeCopySigningInformation(code, kSecCSSigningInformation | kSecCSRequirementInformation, &info);
ents = CFDictionaryGetValue(info, kSecCodeInfoEntitlementsDict);
```

即**读 Apple CS 里那份 entitlement 字典**（不验签，验签由 `LCCheckCodeSignature` 另做）。

`ExtractNXT2OutOfAppleCSEntitlements()` 是**唯一的翻译表**（原文全在 `apple.c`）：

| Apple CS 键 | 条件 | NXT2 结果 |
| --- | --- | --- |
| `get-task-allow` | `true` | `GetTaskAllow` |
| `task_for_pid-allow` | `true` | `TaskForPid` |
| `com.apple.system-task-ports` | `true` | `SystemTaskPorts` |
| `platform-application` | `true` | `Platform` |
| `proc_info-allow` | `true` | `ProcessEnumeration` |
| `com.apple.private.security.no-sandbox` / `no-container` / `container-required == false` | 任一 | `ProcessEnumeration` + `ProcessKill` + `ProcessSpawnSignedOnly`，并给只读根 `$(NXROOT)` |
| `com.apple.security.exception.files.absolute-path.read-write[]` | 数组 | 每项前加 `$(NXROOT)` → `SandboxFileReadWrite` |
| `com.apple.security.exception.files.absolute-path.read-only[]` | 数组 | 每项前加 `$(NXROOT)` → `SandboxFileRead` |
| `com.apple.private.MobileContainerManager.allowed` | `true` | `LaunchServicesGetEndpointAllowList` += `org.emexlabs.bootstrapd` |
| `com.apple.private.security.storage.AppDataContainers` | `true` | 读写路径 += `$(ROOTFS)/var/mobile/Containers/Data/Application` |
| `com.apple.private.security.storage.AppBundles` | `true` | 读写路径 += `$(ROOTFS)/var/containers/Bundle/Application` |
| `com.apple.security.temporary-exception.sbpl[]` | 含 `(allow signal)` | `ProcessKill` |
| 同上 | 前缀 `(allow process-info` | `ProcessEnumeration` |

要点：

- 这是**单向翻译**（Apple → NXT2），代码里没有反向函数；反向只存在"NXT2 字典 → legacy 位掩码"（`trust.m::trust_identity_entitlement_flags_from_entitlements`）。所以"互译"准确说是：**Apple CS 进 → NXT2 中间表示 → ksurface 位掩码**。
- `$(NXROOT)` / `$(ROOTFS)` / `$(EXECUTABLE)` / `$(BUNDLE)` / `$(CONTAINER)` 这些占位符**在翻译阶段就写进字典**，到 `trust_identity_give_file_permissions()` 才替换成真实路径（见下节）。这样同一个 blob 不绑定设备路径。
- 沙箱允许列表用的是 `append` 而不是 `set`，因此 Apple 给的原路径和派生的 `$(NXROOT)` 根会同时存在。

---

## 4. 信任身份与三档信任级别

`Surface/trust/trust.h`：

```c
typedef enum : UInt8 { kPETrustLevelFallback = 0, kPETrustLevelSignature = 1, kPETrustLevelTrusted = 2 } PETrustLevel;

typedef struct {
    char path[MAXPATHLEN];
    char cdhash[USER_FSIGNATURES_CDHASH_LEN];
    CFDictionaryRef entitlements;
    CFArrayRef filePermissions;      /* 预先算好的 sandbox extension token 数组 */
    PETrustLevel trustLevel;
} ksurface_trust_identity_t;
```

`trust.m::trust_identity_create_from_path()` 的三条分支，顺序就是优先级：

1. **`kPETrustLevelTrusted`（硬编码白名单）**：路径等于
   - `<rootfs>/boot/libexec/bootstrapd` → `kPEEntitlementsNXT2PresetsDaemonBootstrap`
   - `<rootfs>/boot/libexec/MobileDevelopmentService` → `kPEEntitlementsNXT2PresetsDaemonCompiler`

   两者都要求 `LCCheckCodeSignature` 通过（Apple 签名）。注释写明路径"不可变"，所以可以跳过 NXT2。预设字典在 `Surface/trust/presets.m`。
   内核自己的身份 `trust_identity_get_kernel()`（同文件）也是 `Trusted`，entitlements 取 `kPEEntitlementsNXT2PresetsKernel`，路径用 `_NSGetExecutablePath`。
2. **`kPETrustLevelSignature`**（`KSURFACE_CS_ALLOW_NXT2`）：用 `vnode_inaccessible_open(path, O_RDWR)` 打开（避免 TOCTOU）→ `trust_nxt2_read_fd()` → 若 `needsResign` 先走 `trust_resign_with_fd()` → `LCCheckCodeSignature` 必须通过 → 必须 `isSigned && isValid && isCdHashValid` → 复制 cdhash、`trust_identity_validate_entitlements()` 清洗 → 计算 filePermissions。
3. **`kPETrustLevelFallback`**：只有 Apple 签名、没有可用 NXT2 → **空 entitlement**，但 `trust_identity_validate_entitlements()` 仍会给它"容器访问"（见下），所以它能跑、能读自己容器。

`trust_resign_with_fd()`：拿 `F_GETPATH` → `LCUtils signMachOAtURL:`（zsign，ad-hoc Apple CS）→ `vnode_inaccessible_reopen(fd)` → `trust_nxt2_sign_fd(fd, entitlements, true, NULL)`（用本机静态密钥重签）→ 重读校验 → 换掉 `result_nxt2`。整段用一把静态 `os_unfair_lock` 串行——因为要改文件内容。

### enforcement 三态

`trust.m`：`g_enforcement_mode` 用一次 CAS 固化（`trust_enforcement_set_mode` 只能设一次，且不接受 `Enforcing` 之外的"再来一次"）：

| 模式 | `trust_enforcement_should_deny()` | `trust_enforcement_overrides()` |
| --- | --- | --- |
| `Enforcing`（默认） | `true`（拒绝并打日志） | `false` |
| `Permissive` | `false`（只打日志） | `true`（放宽可见性） |
| `Disabled` | `false` | `true` |

这两个函数被 `permit.c`、`proc/list.c`、`sysctl.m` 等每一处权限判定调用，于是存在一个**全局调试开关**，能一键把"内核"变成"什么都允许"。

---

## 5. entitlement 清洗与文件权限

### 清洗（`trust_identity_validate_entitlements`）

- 用一张 **schema 表**（键 + 期望 CFTypeID）逐项过滤：不在表里的键**直接丢弃**，类型不符也丢弃，CFArray 还要求"全是 CFString"。表覆盖：platform 四项、`GetTaskAllow`、`TaskForPid`、`SUGID`、`SystemTaskPorts`、`ProcessEnumeration/Kill/Spawn/SpawnSignedOnly/SpawnInheriteEntitlements`、`ManagementHost`、LaunchServices 七项、`SandboxFileRead/ReadWrite/NoContainer/Host`、`KsurfaceKEXTLoading`。
- 然后**无条件追加**（这正是 Fallback 身份也能跑的原因）：
  - 只读：`$(EXECUTABLE)`、`$(BUNDLE)`
  - 除非有 `SandboxNoContainer`：只读 `$(CONTAINER)`，读写 `$(CONTAINER)/*`
- 返回一个新的 `CFMutableDictionary`（原字典不动）。

### 路径模板 → sandbox extension

`trust_identity_give_file_permissions()`：

- 变量表：`ROOTFS`（= `NXROOT`，`NXBootstrap.shared.rootfsURL`）、`NXROOT`、`EXECUTABLE`，若是 App bundle 再加 `CONTAINER`、`BUNDLE`（`LDEApplicationObject` 提供）。
- **总开关** `NSUserDefaults` 键 `nyxian.boot.sandbox.filesystems`：**关**的时候只给一条 `$(NXROOT)` 读写（整个 rootfs 全开），**开**的时候才逐条按 entitlement 来。
- 逐条：`PEResolveEntitlementPaths()` 替换占位符；路径以 `/*` 结尾则展开成目录下的每一项（排序保证稳定）；`PECanonicalizePath()` 用 `realpath()` **先规范化再判断**；然后：
  - `over_sbfs_layer = true`：`ksurface_fs_sandbox_copy_sandbox_extensions_for_entitlements(path, permission, entitlements)`（`Surface/fs/sandbox.m`）
  - `false`：`ksurface_fs_sandbox_copy_sandbox_extension_for_arbitary_path(path, permission)`
- 两个**默认附加只读**：`$(NXROOT)/boot/rtpatch`、`$(NXROOT)/boot/patchfinder.bin`（前者正是 `environment.m` 会 `dlopen` 的运行时补丁）。
- 最强的那条：`SandboxHost` → `$(NXROOT)/../../*` 只读（宿主 data container 的父目录）、`$(NXROOT)/../*` 与 `$(NXROOT)/../Library/*` 读写、`$(NXROOT)/../tmp` 读写，并且走 `over_sbfs_layer = false`、`entitlements = NULL`。这就是 `entitlement.h` 里注的"EXTREMELY POWERFUL，给子进程和 host 一样多的文件访问"。

### spawn 时的继承

`trust_identity_create_from_path_with_parent_identity()`：

- 先按路径拿子身份；
- 若父**没有** `Platform`：把子进程里"父也没有"的键全删掉（子不能凭自己的 blob 越过父）；
- 若父有 `ProcessSpawnInheriteEntitlements`（且父不是 kernel）：合并父的字典，但**先剥掉** `Platform`、`PlatformRoot`、`PlatformUser`、`PlatformGroup`、`TaskForPid`、`SystemTaskPorts`、`SUGID`；
- 否则父的字典清空（不继承）。

---

## 6. 与签名相关的 syscall / 控制面

### `SYS_sign`（`Surface/sys/compat/sign.m`）

guest 拿不到私钥，所以"给我把某个二进制签了"是个 syscall：

1. `sys_need_in_ports(1, MACH_MSG_TYPE_MOVE_SEND)`，且要求调用者有 **`ProcessSpawn`** entitlement（注释：这是"用户可以任意 spawn"的意思，与 `ProcessSpawnSignedOnly` 相对）。→ **签名能力被等同于 spawn 能力**，这是刻意的授权粒度。
2. `fileport_makefd()` 把 fileport 变 fd；必须 `O_RDWR`；`F_GETPATH` 取路径。
3. `CDHashOfFD()` 记下 cdhash → `vnode_inaccessible_open(path, O_RDWR)` 重新打开同一路径 → `CDHashMatchesCodeDirectoryFD()` **比对 cdhash**，不一致就 `EIO`（注释：文件被换掉了）。
4. `LCUtils signMachOAtURL:`（`LiveContainer/LCUtils`，底层是 `LiveContainer/ZSign/zsigner`）。
5. `vnode_inaccessible_close(fd, true)`——第二个参数表示"内容变了，需要刷新 vnode"。

`posix_spawn` 的补丁正是它的客户：发现目标没有有效 CS → `liveshim_syscall(SYS_sign, fd)` → 再验一次（`Shims/posix_spawn.m`）。

### `SYS_pectl` 的 CodeSigning 子类（`Surface/sys/compat/pectl.m`）

| 动作 | 行为 |
| --- | --- |
| `GetPublicKey` | 把 `ksurface->pub_key` copy_out（长度不足给 `E2BIG`） |
| `GetPrivateKey` | **`ENOSYS`**（注释："太敏感"） |
| `SignPath` | **`ENOSYS`**（已由 `SYS_sign` 取代） |
| `GetCDHash` | 仅当自身信任级别是 `Signature` 时返回 `identity->cdhash`，否则 `ENOENT` |
| `AllEntitlements` / `GetEntitlements` | 返回位掩码 |
| `SetEntitlements` | 只能把 `maxEntitlements` 里已有的位加上去，越界 `EPERM`（"MARK: THIS IS USER SUPPLIED"） |
| `DropAllEntitlements` | 连 `maxEntitlements` 一起清零（不可恢复） |
| `LoadKernelExtension` / `UnloadKernelExtension` | **`ENOTSUP`** —— kext 加载**不对 guest 开放** |

最后一行很重要：`entitlement.h` 里虽有 `kPEEntitlementFlagLoadKEXT`（来自 `KsurfaceKEXTLoading`），但**没有任何 syscall 用它加载 kext**。kext 只由 host 自己在启动时装载（下节）。

### 其它 pectl 子类（同一文件）

- `LaunchService.GetEndpoint/SetEndpoint`：按 entitlement 或 NXT2 里的 `AllowList` 数组放行；`SetEndpoint` 还要求该服务实例"预留给"调用者（`instance.process.pid == 调用者 pid`），否则 `EACCES`——注释说明这是防止攻击者抢注 launch service 后读别人的容器。
- `UserInterface.Init`：把调用者交给 `NXWindowServer` 开窗；`dispatch_async` 到主队列后**通过 `syscall_send_reply()` 异步回复**（`*recv_buffer = NULL` 认领模式）。
- `UserInterface.OpenBundleIdentifier`：需要 `ManagementProcEnvironment`，走 `spawnProcessWithBundleIdentifier:`。
- `Userspace.Reboot`：需要 `Platform`，调 `PEUserspaceManager rebootUserspace`。
- `Misceleanous.GetBuildType`：`DEBUG` 与否。

---

## 7. kxld：把 kext 链进 Nyxian 进程

**"kext" 在这里不是 iOS 内核扩展**，而是一个用户态 Mach-O bundle（`MH_KEXT_BUNDLE`），被链入 Nyxian 进程、按 `kmod_info` 语义初始化并起线程。它提供的不是内核代码，而是**给 ksurface 加能力/行为**（见 `KEXTs/*.zip`：`BaseEntitlementLoader`、`BasePreferenceLoader`、`NYXIANMount`、`RelHomeMount`、`SharedTheme`、`UISingleFlight`、`ColorWinFilter`、`CrashReporter`、`KRW`、`TestTweak`）。

### 装载顺序（`KextLoader/PEKextLoader.m`）

1. 列 `kextFSRoot`（"kextfs"）下的每个目录，`PEKext initWithPath:` 解析；`isEnabled == NO`（`Info.plist` 里 `PEDisabled`）跳过。
2. 注入两个**伪 kext**：
   - `com.apple.iphoneos`，版本取 `sysctlbyname("kern.osproductversion")`——"我们不是 iOS，就假装它在"（源码原话）；
   - `ksurface`，版本取 `ksurface_version_get_string()`，依赖 `com.apple.iphoneos >= 18.0.0`。
   两者都带 `KMOD_FLAG_PERSISTENT|KMOD_FLAG_OVERRIDE_CORE|KMOD_FLAG_ALLOW_UNRESOLVED`。
3. **依赖收敛**：反复扫，把"依赖的 kext 根本不存在"或"版本不在 `[min,max]`"的整个剔除（每轮都重新扫，直到不动点）；报错信息里点名是哪个 bundle 缺哪个依赖、装了哪个版本。
4. **拓扑排序**（Kahn）：入度 0 的先入队；出队时优先 `KMOD_FLAG_OVERRIDE_CORE`（`PEKextPriority()` 返回 0，其余 2）。排序数量 != 节点数说明有环（函数此时返回 `nil`，注意这是个真实的 bug 形态：外层调用者会拿到 nil 而看不到原因）。
5. 逐个 `[kext load]` → `kxopen(path, KXLD_MAP_PRIVATE, NULL)`；`ksurface` 与 `com.apple.iphoneos` 直接跳过；某 kext 失败则它的依赖者一并跳过并记录原因。
6. **`kxld_seal()`**：之后 `kxopen` 返回 `KERN_DENIED`、`kxclose` 返回 `KERN_ALREADY_IN_SET`——**启动完成后不能再装/卸 kext**。

### 每个 kext 的三重校验（`PEKext.m::initWithPath:`）

1. `NSBundle` + `bundle.executablePath` 必须存在；
2. `LCMapMachO` + **`LCCheckCodeSignature(machO)`** —— 必须有 Apple CS；
3. **`trust_nxt2_read()`** 必须 `isValid && isSigned && isCdHashValid`；
4. NXT2 字典里必须有 **`org.emexlabs.nyxian.ksurface.kernelextension.loading`**（= `kNXT2EntitlementKsurfaceKEXTLoading`）；
5. 解析 `__DATA` 或 `__DATA_CONST` 段里名为 **`__ksurfacemod`** 的 section（`ksurface_locate_modinfo()`：手工走 load commands，校验 `cmdsize` 对齐/边界、section 不能在 `S_ZEROFILL`、`offset/size` 必须在文件内），内容布局 = `kinfo_mod_t` 紧跟 `dependency_count` 个 `kmod_dependency_t`；
6. 校验 `magic == KSURFACE_KMOD_MAGIC`、`abi_version == KSURFACE_KMOD_ABI_VERSION`、`identifier` 以 NUL 结尾；
7. **把 `init/start/stop` 三个函数指针清成 NULL**（`info.init = NULL; ...`）——磁盘上的指针值不可信，后面由 fixup 阶段重定位；
8. 依赖名/最小/最大版本从 `kmod_dependency_t` 的 `min_version/max_version`（major/minor/patch 位域）解出来。

注意第 7 步与 `kxopen` 里"`if(image_info->mod->init)` 才调用"配合：**函数指针是 fixup 之后才被填上的**。

### 加载管线（`Surface/libkern/kxld/kxopen.c::kxopen_with_fd`）

```
open(O_RDWR) → LCMapMachOFromFDRO
→ KXValidateCodeSignature(machO)                 (validation.c：验 Apple CS)
→ kvo_alloc_fastpath(kxld_image) → F_GETPATH 存进 image_info->path
→ KXMapMachOExecutable(machO, mode, image_info)  (mapper.c：按段映射到宿主地址空间)
→ KXLocateKmod(image_info)                       (kmod.c：找 __ksurfacemod)
→ 依赖逐个版本校验 + kvo_retain（失败则回滚已 retain 的）
→ mode & KXLD_NOCLOSE ⇒ 打上 KMOD_FLAG_PERSISTENT
→ KXApplyFixups(image_info)                      (fixup.c：符号/外部重定位)
→ KXRegisterKext(image_info)                     (进 ksurface->kext_info radix tree)
→ KXRegisterKextExports(image_info)              (export.c：导出符号表)
→ KXRegisterObjCImage(image_info)                (objc.c：注册 ObjC 类/协议/selector)
→ KXResealDataConst(image_info)                  (reseal.c：__DATA_CONST 重新 seal)
→ [KSURFACE_KEXT_ALLOW_CONSTRUCTORS] KXRunInitializers
→ image_info->mod->init()
→ image_info->mod->start() 在一个新 pthread 上跑（ksurface_kext_thread）
```

- `ksurface_kext_thread()`：调 `mod->start()`；返回后 `isStarted = false`（意思是它自己停了）；无 `KMOD_FLAG_PERSISTENT` 才 `kvo_release`。
- 全局 `g_kxld_sealed` 与 `g_kxld_lock`（`os_unfair_lock`）保护整个管线；`kxclose` 只允许关闭非 `PERSISTENT` 的 kext。
- `KSURFACE_KEXT_HARDENED_LOADING`（默认 0）= "失败就崩"。

相关开关都在仓库根的 `ksurface_config.h`：

```c
#define KSURFACE_CS_SANITIZE_ENTITLEMENTS      1
#define KSURFACE_CS_ALLOW_NXT2                 1
#define KSURFACE_DYLD_HARDENED_CDHASH_VERIFIER 1   /* cdhash 校验失败就直接彻底拒绝 */
#define KSURFACE_KEXT_HARDENED_LOADING         0
#define KSURFACE_KEXT_ALLOW_CONSTRUCTORS       0
```

`KSURFACE_DYLD_HARDENED_CDHASH_VERIFIER` 的注释是"关掉它会打开一个巨大的安全风险"——对应 dyld 加载 guest 时的 cdhash 复核（实现不在我读过的文件里，**属推断**）。

### ide → kext 的安装路径

`Nyxian/LindChain/IDEBuilder/NXBuilder.swift`（`schemeKind == .kSurfaceKext` 分支）：

```swift
macho.header.filetype = MH_KEXT_BUNDLE            // 源码把普通 Mach-O 改成 kext bundle
LCUtils.signMachOWithoutPatch(at: machoURL)        // Apple CS（不 patch）
trust_nxt2_sign(path, ["org.emexlabs.nyxian.ksurface.kernelextension.loading": true], true, nil)
vnode_refresh_with_path(path)
ksurface_fs_install_kext_at_path(bundleURL.path)   // 拷进 kextfs
PERestartSelf()                                    // 重启自己 → 下次 kinit 时 PEKextLoaderLoad 装载
```

所以 **kext 的"安装"= 签好放进 kextfs + 重启 Nyxian**，与本进程内的 `kxld_seal` 一致（运行期不可热装）。

---

## 8. 第二条链：NXROM001 / TrustStore（`RomGen.py`）

与 NXT2 无关，但同属"信任"话题，简单记录（细节见 `build-and-run.md`）：

- ROM ZIP 末尾追加固定 footer：`FOOTER = struct.Struct('<72sQI8s')` = `signature(72) | length(u64) | count(u32) | magic("NXROM001")`。
- 签名对象是 `sha256(b'NXROM-ARCHIVE-v1\0' + 整个 ZIP 内容)`，P-256 ECDSA。
- ZIP 内另有 `NXRomFiles.plist`：`{format, payload, signature}`，payload 里是**每个文件的哈希**（`NXROM-FILES-v1` 域），其哈希函数（`file_hash`）对 Mach-O 特意**忽略重签会改变的部分**：`LC_CODE_SIGNATURE` 的 dataoff、`__LINKEDIT` 的 filesize/vmsize、`__PAGEZERO` 的 vmaddr/vmsize、`MH_PIE`/`MH_NO_REEXPORTED_DYLIBS` 标志、首个 `LC_ID_DYLIB`（若为 LiveContainer 插入形态）、`LC_NX_LOADER`（0x114514）等。
- TrustStore（`fetchtruststore.sh`、`Makefile` 的 `truststore*` 目标、`TrustStore/truststore.py`）：由 emexLabs **根密钥**签名的 plist，`ROOT_KEYS` 硬编码在 `RomGen.py` 里；`NXRomSecurityVersion` 必须单调递增（"Nyxian 拒绝回退到更低的"）。
- 语义（`RomGen.py` 文件头）：*Nyxian 只启动由 TrustStore 中某个密钥签过 release 的 ROM；flash 时会用用户证书重签 ROM 里的 Mach-O，之后每次启动校验"除了代码签名什么都没变"（0.11.6.4+）*。

---

## 9. 本节的推断与缺口

- **`kxld` 的 fixup/export 内部**（`fixup.c` 15 KB、`export.c` 4 KB、`resolve.c` 7 KB、`pseudo.c`）未逐行读；"pseudo kext 提供未解析符号"来自 `KMOD_FLAG_ALLOW_UNRESOLVED` 与 `pseudo.c` 的存在，**属推断**。
- **thread local storage 的 fixup 未实现**（README 里该条未打勾），与 `fixup.c` 未读部分一致。
- `LiveContainer/LCUtils`、`LCMachOUtils`、`ZSign/zsigner` 未读：`LCCheckCodeSignature` / `CDHashOfMachO` / `signMachOAtURL` 的内部实现不在本文断言范围内。
- `TrustStore/` 目录未列内容（仓库根 listing 里没有它，只在 `Makefile` 与 `fetchtruststore.sh` 里被引用）——`RomGen.py` 头注释提到 `TrustStore/README.md`、`TrustStore/truststore.py`，但根目录 listing 里未见该目录，**可能是后来移出或改名**，此点记为不一致。
- NXT2 的 `needsResign` 路径里有一条 `FIXME`（"check if CS hashes matches the cdhash before trusting the rootca blindly"），说明这条第三方 RootCA 通道**尚无 cdhash 绑定**。
