<p align="center"><img src="Documents/Site/icon.png" width="112" alt=""></p>

<h1 align="center">Luros</h1>

<p align="center">写、编译、安装，都在手机上。</p>

<p align="center">
  <a href="https://github.com/1103945342/Luros/releases"><img src="https://img.shields.io/github/v/release/1103945342/Luros?label=release&color=blue" alt="最新发布"></a>
  <img src="https://img.shields.io/badge/iOS%20%7C%20iPadOS-16.0%2B-000000?logo=apple&logoColor=white" alt="要求 iOS 与 iPadOS 16.0 或更高">
  <img src="https://img.shields.io/badge/bootstrap-roothide%20%7C%20rootless-2ea44f" alt="支持 roothide 与 rootless">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT 许可证"></a>
</p>

<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

Luros 是越狱 iPhone / iPad 上的 IDE，iOS 16 起，roothide 和 rootless 都能用。插件、App、命令行工具、设置面板，从写代码到编译、签名、打包、安装、看日志、符号化崩溃报告，都可以在设备上做完。不用 Mac，不用 Xcode，也不用 Apple ID。

![预览](Documents/screenshots.jpg)

## 这个仓库

它 fork 自 [Apelin](https://github.com/owngoal-dev/Apelin)。包名、bundle ID、`lurosd` 守护进程和 `luros-project.json` 都换成了自己的，所以能跟 Apelin 装在同一台设备上，不会互相覆盖。0.3.4 之后，构建和发布走本仓库的 CI：打 tag 时发出去的就是那次 CI 跑出来的包，附 `SHA256SUMS`，发布时不重新编译一遍。

跟上游比，这边做的改动：

- 一个包就够。`icli`、`irisind`、`irisin-install`、四个开发扩展，还有汇编器和反汇编器，都在 `Luros.app` 里，不用先装 Irisin 和 icli。
- 自己的终端和文件浏览器。「打开终端」「浏览文件」直接用，不必先装 Fila 或 iGhostVT。
- 新建项目时会在 `luros-project.json` 旁边写一份 Xcode 工程，拿到 Mac 上直接能打开。
- 第三方工具页会读设备上已有的软件源，算出缺的那个工具需要装什么，再交给 irisind 装上。
- agent 之间可以派活：发起方把任务拆成带验收标准的小步，子对话各自做完回报，最后封成一份总账，交付了什么、什么只是声称，分得开。
- 设置里有「记忆」，agent 的长期笔记存在设备上，可以直接改。
- GitHub 不只是 push：能读 issue 和 PR，评论、关闭、重开，也能开 PR 和合并。
- 编译有增量缓存，构建目录只留最近两个。
- App 可以打成 `.ipa`，扩展放进 `PlugIns/`；同一个 bundle ID 重装是就地替换，不用先卸载。

## 能做什么

**编译。** Apple 的 Command Line Tools 在设备上装好，C、C++、Objective-C，Swift 可选。14.2 到 27.2 可以并存，每个装完先自测再登记，中途断了会从任务记录接着装。iPhoneOS SDK 可以从压缩包、文件夹，或者「一个分支一个 SDK」的仓库导入，进树的每个文件都会检查。项目来自模板：插件、App、命令行工具、设置面板，或者一个保留自己构建脚本的空工作区；App 也可以打成 `.ipa`。之后是签名（`ldid`）、打包、交给内置的 irisind 安装，再 respring、确认插件真的加载了。分发… 会先体检，分别为 roothide 和 rootless 出 release 包，也可以直接发到你自己的软件源。

**Agent。** 它改代码、编译安装、读日志和崩溃报告、截图。模型服务商有 GitHub Copilot、Claude、ChatGPT Codex、DeepSeek、OpenCode、Antigravity、Trae、Raccoon、WorkBuddy，任意多个 OpenAI 兼容端点，或者直接填 API key。规划模式下它只读不写；Strict、Relaxed、Full 决定它自己能做多少事，root 命令一律要问过你。跑着的时候再发消息，可以排队，也可以在下一处输入边界插进去。一轮可以回溯、分叉、改消息、删回复，动手前都会先打 git 检查点。另外有技能、你自己装的工具扩展、记忆、通知、一个用手机跑对话的微信通道，以及一个可以用脚本无人值守测整条链路的后台控制台。

**设备和 git。** 代码编辑器、滚回有编号也有上限的终端，以及把 SDK、工具链目录当作记录的文件夹浏览器。git 这边有分支、合并、tag、stash、squash、带租约的强制推送（先告诉你哪些提交会离开分支），还有「以远端为准」，丢掉的工作会先存到 `luros-backup/<时间>`。工具链（`.apetc`）、SDK（`.apesdk`）或项目（`.apeproj`）可以打成一个文件，在自己的设备之间搬，落地时按目标引导重新打包。界面有十三种语言。

## 安装

到 [Releases](https://github.com/1103945342/Luros/releases) 下载对应引导的包，对照 `SHA256SUMS` 校验：

| 引导 | 包 |
| --- | --- |
| roothide | `com.fluoxetine.luros_<版本>_iphoneos-arm64e.deb` |
| rootless（`/var/jb`） | `com.fluoxetine.luros_<版本>_iphoneos-arm64.deb` |

iOS 或 iPadOS 16.0 起，A12 及以后的芯片。Irisin 和 icli 不必预先安装：装包用的守护进程、驱动设备的工具，Luros 自己带着。Swift 能跑到哪个系统、哪种 CPU，取决于工具链版本，见 [Compatibility](Documents/Compatibility.md)。

四个项目模板和 agent 的汇编器、反汇编器都在 App 里，不用另装扩展包：

| 组件 | 提供 |
| --- | --- |
| `com.fluoxetine.luros.dev.app` | Objective-C 或 Swift 的 UIKit App |
| `com.fluoxetine.luros.dev.tweak` | 插件（tweak） |
| `com.fluoxetine.luros.dev.cli` | C 或 Objective-C 的命令行工具 |
| `com.fluoxetine.luros.dev.preferences` | 设置面板 |
| `com.fluoxetine.luros.agent-tools.disassembler` | agent 用的反汇编器（基于 Capstone） |
| `com.fluoxetine.luros.agent-tools.assembler` | agent 用的汇编器（基于 Keystone，GPL-2.0，源码随每个发布附上） |

自己单独装了同名扩展包，会优先于内置副本；删掉某个扩展，Luros 照样能用。插件模板依赖一个注入框架，Luros 本身不依赖。

每个版本的说明在 [Documents/Releases](Documents/Releases/)；`main` 比最新一次发布更靠前。

## 在 Luros 中打开

仓库的 README 里可以放一个按钮，在 Luros 里打开它，导入成新项目前会先问过你：

```markdown
[![Open in Luros](https://1103945342.github.io/Luros/open/badge.svg)](https://1103945342.github.io/Luros/open/?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo)
```

`url` 是仓库的 HTTPS 地址，URL 编码过。要检出别的分支，加 `&branch=<分支名>`。链接里不带别的东西：没有命令，没有给 agent 的话，也没有凭据。Luros 会显示地址、分支和新项目名，你确认之后才导入。仓库里的东西一概不运行，也不会有内容发给 agent。私有仓库要先在设置 ▸ Git 里用 GitHub 登录。没装 Luros 时，页面会说明怎么安装，并让你复制地址。

## 反馈问题

在设置里选「反馈问题」，或者[在 GitHub 上开 issue](https://github.com/1103945342/Luros/issues/new)。先搜一下已有的 issue。

如果 Luros 崩溃，或者编译、安装失败，请附上设置 ▸ 日志里的记录。日志可能包含项目名、路径和仓库地址，分享前先看一遍。

## 隐私

agent 与 git 的凭据存在钥匙串里，只在这台设备上，不云同步。没有遥测：对话只发给你登录的那个模型服务商；诊断日志写盘前已经脱敏。

## 从源码构建

用最新的 Xcode 打开 `Luros.xcodeproj`。打包：

```sh
make harness      # 在 Mac 上跑测试
make check        # 工程、打包、字符串与无障碍检查
make deb-all      # 构建 roothide 与 rootless 两个包
make install DEVICE_HOST=<地址> FLAVOR=roothide
```

需要用你的软件包管理器装好 `dpkg`、`ldid`、`zstd` 和 `swiftformat`。没有模拟器构建。给贡献者的说明在 [AGENTS.md](AGENTS.md)，也可以用[控制台](Documents/Console.md)无人值守地驱动 App。

## 致谢

Luros 是 OwnGoal Studio 的 [Apelin](https://github.com/owngoal-dev/Apelin) 的 fork，沿用同一份 MIT 许可证。Apple 的 Command Line Tools 与 iPhoneOS SDK 仍归 Apple，按其条款使用，Luros 不分发它们。默认读取的 SDK 源是 [1103945342/iOS-SDKs](https://github.com/1103945342/iOS-SDKs)，源自 [owngoal-dev/iOS-SDKs](https://github.com/owngoal-dev/iOS-SDKs) 与 [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs)。第三方组件的声明在 [Licenses/](Licenses/) 与 App 内的 设置 ▸ 许可证 里。

---

Copyright © 2026 OwnGoal Studio 与 Luros 贡献者。以 [MIT 许可证](LICENSE)发布。
