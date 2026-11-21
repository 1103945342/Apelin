<p align="center"><img src="Documents/Site/icon.png" width="112" alt=""></p>

<h1 align="center">Luros</h1>

<p align="center"><b>写、编译、安装，全在设备上完成。</b></p>

<p align="center">
  <a href="https://github.com/1103945342/Luros/releases"><img src="https://img.shields.io/github/v/release/1103945342/Luros?label=release&color=blue" alt="最新发布"></a>
  <img src="https://img.shields.io/badge/iOS%20%7C%20iPadOS-16.0%2B-000000?logo=apple&logoColor=white" alt="要求 iOS 与 iPadOS 16.0 或更高">
  <img src="https://img.shields.io/badge/bootstrap-roothide%20%7C%20rootless-2ea44f" alt="支持 roothide 与 rootless">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT 许可证"></a>
  <a href="https://github.com/1103945342/Luros/actions/workflows/ci.yml"><img src="https://github.com/1103945342/Luros/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

Luros 是一个跑在越狱 iPhone、iPad 上的 IDE（iOS / iPadOS 16 或更高）。它的 agent 在设备本地写代码、编译、安装、调试插件（tweak）、App、命令行工具和设置面板——不需要 Mac、不需要 Xcode、不需要 Apple ID。roothide 与 rootless 两种引导都支持。

![预览](Documents/screenshots.jpg)

> **这是 Apelin 的 fork，走自己的发布线。** Luros 从 [Apelin](https://github.com/owngoal-dev/Apelin) 分叉而来，并在这里继续往前走：自己的图标、标识符与守护进程，自己的终端与文件浏览器，自己的 agent 能力；从 0.3.4 起，每一次编译和每一次发布都出自本仓库自己的流水线。改动见下。包名与 bundle ID 都和 Apelin 不同，所以 Luros 是装在它旁边，而不是覆盖它。

## 为什么选 Luros

- **一个包装完，不用再装别的。** `icli`、`irisind` 与 `irisin-install`、四个开发扩展，以及 agent 用的汇编器和反汇编器，全都随 `Luros.app` 一起发出。安装或升级 Luros 不再依赖 Irisin、icli 自己的包；一个没装任何扩展包的设备，也照样能建出每一种项目。
- **自带终端和文件浏览器。** 项目的对话打开项目目录，通用聊天打开那条对话自己的临时目录；终端滚回有编号、有上限、可重放，文件浏览器带面包屑路径栏——不用 Fila，也不用 iGhostVT。
- **App 死了，活还在。** 编译、安装、工具链安装、导入、终端和 agent 会话都跑在按需启动的会话宿主里。App 或守护进程被杀，任务从断点接着跑，而不是留下半个构建。
- **agent 手里有真家伙。** 会自己开对话、作为子代理并行干活，维护一份封账的账本说明谁交付了什么、什么只是声称；先出计划再动手；能读 issue 和 PR，评审、评论、关闭、合并；每轮都打 git 检查点，可以还原；你不在时还能从手机上通过微信给它下指令。
- **上下文用了多少，看得见。** 输入框旁有一圈进度环；每个模型的上下文窗口和回复上限可以手填；压缩按你设的数字走，而不是按服务商报的数字走。
- **出故障时，一句话说清。** 「正在等待网络…」、一行红字用你的语言点明问题、无论某个工具在等什么，Stop 都在几秒内结束这一轮。
- **发布只发 CI 验过的字节。** 每次 push 都由 CI 编译、测试、打包；打 tag 时发出去的就是那次跑出来的文件，并附 `SHA256SUMS`，绝不重新构建一遍。

## 这个 fork 改了什么

- **自己的身份。** 图标、标识符（`com.fluoxetine.luros`）、`lurosd` 守护进程、自己的路径与 `luros-project.json`——装在 Apelin 旁边，不覆盖它。
- **一个自给自足的包。** `icli`、`irisind`、`irisin-install`、四个开发扩展、两个 agent 工具扩展都在 `Luros.app` 里；包本身既不依赖 Irisin，也不依赖 icli。
- **自带终端和文件浏览器**，对话的「…」菜单不再要求先装 Fila 或 iGhostVT。
- **第三方工具页**读取设备上已有的软件源，从本地索引解出缺的那个工具的依赖闭包，再交给 irisind 安装。
- **每个新项目都附一份 Xcode 工程**，和 `luros-project.json` 由同一份描述写出。
- **团队协作**：发起方把任务拆成带验收标准的小步，子对话回报，最后封账成一份总账，分清「交付了」与「只是声称」。
- **设置 ▸ 记忆**：agent 的长期记忆就在设备上，可以手改。
- **GitHub 能力超出 push**：读仓库的 issue 与 pull request，评论、关闭、重开、开 PR、合并 PR。
- **增量编译缓存**（按工具链、SDK、编译参数和源码摘要做键），构建目录只留最近两个，连续构建一周也塞不满设备。
- **`.ipa` 构建**：App 的扩展按规矩放进 `PlugIns/`；同 bundle ID 的 App 就地替换，不用先卸载。
- **只发布 CI 验过的字节**：每次 push 都编译、测试、打包，打 tag 时发出去的就是那批文件并附 `SHA256SUMS`。

每个版本自己的说明在 [Documents/Releases](Documents/Releases/)。

## 它都能做什么

**编译与交付**

- 在设备上装好 Apple 的 Command Line Tools：C、C++、Objective-C，Swift 可选。14.2 到 27.2 多个版本并存，装完先自测才登记；中途断了会从任务记录接着装。
- iPhoneOS SDK 可从压缩包、文件夹，或「一个分支一个 SDK」的仓库导入；逐个文件校验，不该出现在树里的一律拒收。
- 模板覆盖插件、App、命令行工具、设置面板，以及保留自身构建脚本的工作区；App 也可以打成 `.ipa`，小组件等扩展按规矩放进 `PlugIns/`。
- 编译、用 `ldid` 签名、打包、交给内置的 irisind 安装、respring，再确认插件真的加载了——一个闭环，全在设备上。
- 分发… 在出门前先体检，分别为 roothide 和 rootless 出 release 包，并发布到你自己的软件源，带上包的详情页。

**Agent**

- GitHub Copilot、Claude、ChatGPT Codex、DeepSeek、OpenCode、Antigravity、Trae 与 Trae CN、Raccoon、WorkBuddy、OpenRouter，任意多个 OpenAI 兼容端点，或者直接用 API key。
- 规划 / 构建 / 自动三种运行模式；Strict、Relaxed、Full 三档审批；每条 root 命令都要问；动屏幕前必须经你同意。
- 消息按 FIFO 排队，也可以在下一处输入边界插进正在跑的那一轮；点「停止」就结束本轮并暂停队列，直到你说继续。
- 回溯、分叉、改一条消息、删一条回复；每一轮都有 git 检查点，还原前先把将被覆盖的工作存到备份分支。
- 技能、你装上的工具扩展、记忆、通知、截图、UI 树、实时日志，以及用你自己 dSYM 符号化的崩溃报告。
- GitHub 设备码登录；替你建仓库、开 issue、读并关闭 issue、开并合并 PR。
- 微信通道（设置 ▸ 插件）让你在手机上跑对话：选会话、选项目、选模型，用数字回答审批和问题，文件双向收发。

**设备与 git**

- 带语法高亮的代码编辑器；有上限、可重放的终端；把 SDK、工具链目录当作记录而不是随手可改的文件夹的文件浏览器。
- git 一整套：分支、合并、tag、stash、squash、带租约的强制推送（先给你看会丢掉什么），以及「以远端为准」（丢掉的工作先存到 `luros-backup/<时间>`）。
- 工具链（`.apetc`）、SDK（`.apesdk`）或项目（`.apeproj`）可以打成一个文件，在自己的设备之间搬家，落地时按目标引导重新打包。
- 十三种语言；还有一个无头控制台，可以用 JSON 脚本驱动每一个操作来做测试。

## 安装

到 [Releases](https://github.com/1103945342/Luros/releases) 下载对应引导的包，并对照 `SHA256SUMS` 校验：

| 引导 | 包 |
| --- | --- |
| roothide | `com.fluoxetine.luros_<版本>_iphoneos-arm64e.deb` |
| rootless（`/var/jb`） | `com.fluoxetine.luros_<版本>_iphoneos-arm64.deb` |

需要 iOS 或 iPadOS 16.0 或更高、A12 及以后的芯片。Irisin 和 icli 不必预先安装：装包用的守护进程、驱动设备用的工具，Luros 自己带着。Swift 能跑到哪个系统、哪种 CPU，取决于工具链版本——见 [Compatibility](Documents/Compatibility.md)。

每个版本的更新说明在 [Documents/Releases](Documents/Releases/)；`main` 上的源码比最新一次发布更靠前。

随 App 一起内置，无需另装：

| 组件 | 提供 |
| --- | --- |
| `com.fluoxetine.luros.dev.app` | Objective-C 或 Swift 的 UIKit App |
| `com.fluoxetine.luros.dev.tweak` | 插件（tweak） |
| `com.fluoxetine.luros.dev.cli` | C 或 Objective-C 的命令行工具 |
| `com.fluoxetine.luros.dev.preferences` | 设置面板 |
| `com.fluoxetine.luros.agent-tools.disassembler` | agent 用的反汇编器（基于 Capstone） |
| `com.fluoxetine.luros.agent-tools.assembler` | agent 用的汇编器（基于 Keystone，GPL-2.0，源码随每个发布附上） |

自己单独装了同名扩展包，会优先于内置副本；删掉某个扩展，Luros 也照样能用。插件模板依赖一个注入框架，Luros 本身不依赖。

## 在 Luros 中打开

仓库的 README 里可以放一个按钮，在 Luros 里打开它——会先问过你，再导入成新项目：

```markdown
[![Open in Luros](https://1103945342.github.io/Luros/open/badge.svg)](https://1103945342.github.io/Luros/open/?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo)
```

`url` 是仓库的 HTTPS 地址，经过 URL 编码。要检出默认以外的分支，加 `&branch=<分支名>`。链接里不带别的东西：没有命令，没有给 agent 的话，也没有凭据。Luros 会显示地址、分支和新项目名，你确认之后才导入。仓库里的东西一概不运行，也不会有内容被送给 agent。私有仓库需要先在设置 ▸ Git 里用 GitHub 登录。没装 Luros 时，页面会说明怎么安装，并让你复制地址。

## 反馈问题

在设置里选「反馈问题」，或者[在 GitHub 上开 issue](https://github.com/1103945342/Luros/issues/new)。先搜一下已有的 issue，避免重复。

如果 Luros 崩溃，或者编译、安装失败，请附上设置 ▸ 日志里的记录。日志可能包含你的项目名、路径和仓库地址，分享前先看一遍。

## 隐私

agent 与 git 的凭据存在钥匙串里，只在这台设备上，从不云同步。没有遥测：你的对话只发给你登录的那个模型服务商；诊断日志在写入前已做脱敏。

## 从源码构建

用最新的 Xcode 打开 `Luros.xcodeproj`。打包：

```sh
make harness      # 在 Mac 上跑测试
make check        # 工程、打包、字符串与无障碍检查
make deb-all      # 构建 roothide 与 rootless 两个包
make install DEVICE_HOST=<地址> FLAVOR=roothide
```

需要用你的软件包管理器装好 `dpkg`、`ldid`、`zstd` 和 `swiftformat`。没有模拟器构建。给贡献者的说明在 [AGENTS.md](AGENTS.md)，也可以通过[控制台](Documents/Console.md)无头驱动 App。

`ci.yml` 对每次 push 和 PR 编译、测试、打包；`release.yml` 发布 tag 对应那次 CI 的产物，不重新构建，那次没通过就拒绝发布。

## 致谢

Luros 是 OwnGoal Studio 的 [Apelin](https://github.com/owngoal-dev/Apelin) 的 fork，沿用同一份 MIT 许可证；它长出来的那套设计是他们的。Apple 的 Command Line Tools 与 iPhoneOS SDK 仍归 Apple，按其条款使用——Luros 从不分发它们。默认读取的 SDK 源是 [1103945342/iOS-SDKs](https://github.com/1103945342/iOS-SDKs)，源自 [owngoal-dev/iOS-SDKs](https://github.com/owngoal-dev/iOS-SDKs) 与 [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs)。

第三方组件各自保留自己的许可证，声明在 [Licenses/](Licenses/) 与 App 内的 设置 ▸ 许可证 里。

## 赞助

[LookInside](https://lookinside-app.com/) 让你从 Mac 上查看一台运行中的 iOS 或 macOS App 的界面。

---

Copyright © 2026 OwnGoal Studio 与 Luros 贡献者。以 [MIT 许可证](LICENSE)发布。
