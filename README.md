<p align="center"><img src="Documents/Site/icon.png" width="112" alt=""></p>

<h1 align="center">Luros</h1>

<p align="center"><b>Write. Build. Install. On the device.</b></p>

<p align="center">
  <a href="https://github.com/1103945342/Luros/releases"><img src="https://img.shields.io/github/v/release/1103945342/Luros?label=release&color=blue" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/iOS%20%7C%20iPadOS-16.0%2B-000000?logo=apple&logoColor=white" alt="iOS and iPadOS 16.0 or later">
  <img src="https://img.shields.io/badge/bootstrap-roothide%20%7C%20rootless-2ea44f" alt="roothide and rootless">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
  <a href="https://github.com/1103945342/Luros/actions/workflows/ci.yml"><img src="https://github.com/1103945342/Luros/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

<p align="center"><b>English</b> · <a href="README.zh-Hans.md">简体中文</a></p>

Luros is an IDE for a jailbroken iPhone or iPad on iOS or iPadOS 16 or later. Its agent writes, builds, installs and debugs tweaks, apps, command-line tools and preference bundles on the device itself — no Mac, no Xcode, no Apple ID. It works with both roothide and rootless bootstraps.

![Preview](Documents/screenshots.jpg)

> **A fork, with its own release line.** Luros began as a fork of [Apelin](https://github.com/owngoal-dev/Apelin) and has been carried forward here: its own identifiers and daemon, its own terminal and file browser, its own agent features, and since 0.3.4 every build and release from this repository's own pipeline. What changed is below. The package and bundle identifiers differ from Apelin's, so Luros installs beside it rather than over it.

## Why Luros

- **One package, nothing else to install.** `icli`, `irisind` and `irisin-install`, the four development extensions and the agent's assembler and disassembler ride inside `Luros.app`. Installing or updating Luros does not depend on Irisin's or icli's own packages, and a device with no extension package installed can still make a project of every kind.
- **A terminal and a file browser of its own.** A project's chat opens the project's folder and General Chat opens that conversation's own scratch folder, in a terminal with numbered, bounded scrollback and a file browser with a breadcrumb path bar — no Fila and no iGhostVT needed.
- **Work that survives the app.** Builds, installs, toolchain setups, imports, terminals and agent sessions run in an on-demand session host. A killed app or daemon picks the task up where it stopped instead of leaving a half-finished build behind.
- **An agent with a real toolbox.** It opens conversations of its own and works beside them as subagents, keeps a sealed ledger of who owes what, plans before it writes, reads issues and pull requests, reviews, comments, closes and merges, keeps checkpoints you can restore, and takes orders from your phone over WeChat when you are away.
- **It tells you how full the context is.** A ring in the composer shows the share in use; each model's context window and reply ceiling can be set by hand; the chat compacts by the figure you set rather than by what a provider happens to report.
- **Failures you can read.** *Waiting for Network…*, one red line naming the problem in your language, a Stop that ends the turn within seconds whatever a tool is waiting on.
- **Releases only CI verified.** Every push is compiled, tested and packaged by CI; a tag ships those exact bytes with `SHA256SUMS`, never a rebuild.

## What this fork changed

- **Its own identity.** An icon, identifiers (`com.fluoxetine.luros`), a `lurosd` daemon, its own paths and `luros-project.json` — beside Apelin, not over it.
- **A package that needs nothing else.** `icli`, `irisind`, `irisin-install`, the four development extensions and the two agent tool extensions are inside `Luros.app`, and the package depends on neither Irisin nor icli.
- **A terminal and a file browser of its own**, so a chat's … menu no longer needs Fila or iGhostVT installed.
- **Third-Party Tools** that reads the device's own repositories, resolves a missing tool's dependency closure from the indexes already on disk, and installs it through irisind.
- **An Xcode project for every new project**, written from the same description beside `luros-project.json`.
- **Team collaboration**: an opener assigns bounded steps with acceptance criteria, children report back, and the assignment is sealed into one account of what was delivered and what was only claimed.
- **Settings ▸ Memory**, the agent's long-term notes, on the device and editable by hand.
- **GitHub beyond pushing**: read a repository's issues and pull requests, comment, close, reopen, open a pull request and merge one.
- **An incremental build cache** keyed by toolchain, SDK, flags and source digests, and build folders bounded to the newest two so a week of building cannot fill the device.
- **`.ipa` builds** that carry the app's extensions under `PlugIns/`, and an install that replaces the app of the same bundle ID in place.
- **A release line only CI verified**: every push is compiled, tested and packaged, and a tag publishes those bytes with `SHA256SUMS`.

Each version's own notes are in [Documents/Releases](Documents/Releases/).

## What it does

**Build and ship**

- Apple's Command Line Tools, set up on the device: C, C++, Objective-C, Swift as an option. Releases 14.2 to 27.2 are kept side by side, each self-tested before it is registered; a setup that is interrupted resumes from its job record.
- iPhoneOS SDKs imported from an archive, a folder or a branch of a one-SDK-per-branch repository, checked file by file and refused when a slice or member would not belong there.
- Templates for tweaks, apps, command-line tools and preference bundles, a workspace that keeps its repository's own build script, or an app built as an `.ipa` — with its widgets and other extensions under `PlugIns/`.
- Build, sign with `ldid`, package, install through the bundled irisind, respring and confirm that a tweak loaded — one loop, on the device.
- Distribute… checks a package before it goes out, builds a release for roothide and for rootless, and publishes it to a package repository of your own, its depiction page included.

**The agent**

- GitHub Copilot, Claude, ChatGPT Codex, DeepSeek, OpenCode, Antigravity, Trae and Trae CN, Raccoon, WorkBuddy, OpenRouter, any number of OpenAI-compatible endpoints, or an API key.
- Plan, build and automatic run modes; Strict, Relaxed and Full approvals; every root command asks; the screen is used only after you agree.
- Messages queue in FIFO order, or steer the running turn at its next input boundary; Stop ends the turn and keeps the queue paused until you say so.
- Rewind, fork, edit or delete a message; every turn is checkpointed in git, and a restore saves what it replaces on a backup branch first.
- Skills, tool extensions you install, memory, notifications, screenshots, the UI tree, the live log and crash reports symbolicated against your own dSYM.
- GitHub Sign In with a device code, repositories created for you, issues filed, read and closed, pull requests opened and merged.
- A WeChat channel (Settings ▸ Plugins) that runs a conversation from your phone: commands to pick a session, a project, a model; approvals and questions answered by number; files both ways.

**Device and git**

- A code editor with syntax highlighting, a terminal with a bounded replayable history, and a file browser that treats an SDK or a toolchain folder as a record rather than a folder to edit.
- Git in full: branches, merges, tags, stashes, squash, force-with-lease with a preview of what leaves the branch, and *remote wins* with the lost work kept on `luros-backup/<time>`.
- Tools transferred between your own devices as one file: a toolchain (`.apetc`), an SDK (`.apesdk`) or a project (`.apeproj`), rebuilt for the target's bootstrap.
- Thirteen languages, and a headless console that drives every operation from a JSON script for testing.

## Install

Download the package for your bootstrap from [Releases](https://github.com/1103945342/Luros/releases) and check it against `SHA256SUMS`:

| Bootstrap | Package |
| --- | --- |
| roothide | `com.fluoxetine.luros_<version>_iphoneos-arm64e.deb` |
| rootless (`/var/jb`) | `com.fluoxetine.luros_<version>_iphoneos-arm64.deb` |

Requires iOS or iPadOS 16.0 or later and an A12 chip or later. Irisin and icli do not have to be installed: Luros carries the daemon it installs through and the tool it drives the device with. Which iOS versions and CPUs can run Swift depends on the toolchain release — [Compatibility](Documents/Compatibility.md) lists them.

The release notes for every version are in [Documents/Releases](Documents/Releases/), and the source on `main` is ahead of the newest published release.

Bundled with the app, so no extra package is needed:

| Component | Adds |
| --- | --- |
| `com.fluoxetine.luros.dev.app` | UIKit apps in Objective-C or Swift |
| `com.fluoxetine.luros.dev.tweak` | Tweaks |
| `com.fluoxetine.luros.dev.cli` | Command-line tools in C or Objective-C |
| `com.fluoxetine.luros.dev.preferences` | Preference bundles |
| `com.fluoxetine.luros.agent-tools.disassembler` | A disassembler for the agent, on Capstone |
| `com.fluoxetine.luros.agent-tools.assembler` | An assembler for the agent, on Keystone (GPL-2.0; its source is published with each release) |

An extension package installed on its own wins over the bundled copy, and Luros still works if you remove one. The tweak template depends on an injection framework, which Luros itself does not.

## Open in Luros

A repository's README can carry a button that opens the repository in Luros, which asks before importing it into a new project:

```markdown
[![Open in Luros](https://1103945342.github.io/Luros/open/badge.svg)](https://1103945342.github.io/Luros/open/?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo)
```

`url` is the repository's HTTPS address, URL-encoded. Add `&branch=<name>` to check out a branch other than the default. The link carries nothing else: no command, no message for the agent and no credential. Luros shows the address, the branch and the new project's name, and imports only once you confirm. Nothing in the repository runs, and nothing is sent to the agent. A private repository needs Sign In with GitHub in Settings ▸ Git. Without Luros, the page explains how to install it and lets you copy the address.

## Report a problem

Choose Report a Problem in Settings, or [open an issue on GitHub](https://github.com/1103945342/Luros/issues/new). Search the existing issues first to avoid duplicates.

If Luros crashes or a build or an installation fails, include the log from Settings ▸ Logs. The log may contain your project names, paths and repository addresses, so review it before you share it.

## Privacy

Agent and git credentials are kept in the keychain, on this device only, and never synced. There is no telemetry: your conversations go only to the model provider you signed in to, and the diagnostic journal is redacted before it is written.

## Build from source

Open `Luros.xcodeproj` in the newest Xcode. To build the packages:

```sh
make harness      # run the tests on the Mac
make check        # project, packaging, string and accessibility checks
make deb-all      # build the roothide and rootless packages
make install DEVICE_HOST=<address> FLAVOR=roothide
```

You need `dpkg`, `ldid`, `zstd` and `swiftformat` from your preferred package manager. There is no Simulator build. Notes for contributors are in [AGENTS.md](AGENTS.md), and you can drive the app headless through the [console](Documents/Console.md).

`ci.yml` compiles, tests and packages every push and pull request; `release.yml` publishes a tag's CI artifact without rebuilding it, and refuses when that run did not pass.

## Credits

Luros is a fork of [Apelin](https://github.com/owngoal-dev/Apelin) by OwnGoal Studio, and keeps the same MIT licence; the design it grew from is theirs. Apple's Command Line Tools and iPhoneOS SDKs remain Apple's, under Apple's terms — Luros never ships them. The SDK source it reads by default is [1103945342/iOS-SDKs](https://github.com/1103945342/iOS-SDKs), after [owngoal-dev/iOS-SDKs](https://github.com/owngoal-dev/iOS-SDKs) and [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs).

Third-party components keep their own licences. Their notices are in [Licenses/](Licenses/) and in the app under Settings ▸ Open Source Licenses.

## Sponsor

[LookInside](https://lookinside-app.com/) lets you inspect the interface of a running iOS or macOS app from your Mac.

---

Copyright © 2026 OwnGoal Studio and the Luros contributors. Released under the [MIT License](LICENSE).
