<p align="center"><img src="Documents/Site/icon.png" width="112" alt=""></p>

<h1 align="center">Luros</h1>

<p align="center">写、编译、安装，都在手机上。</p>

<p align="center">
  <a href="https://github.com/1103945342/Luros/releases"><img src="https://img.shields.io/github/v/release/1103945342/Luros?label=release&color=blue" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/iOS%20%7C%20iPadOS-16.0%2B-000000?logo=apple&logoColor=white" alt="iOS and iPadOS 16.0 or later">
  <img src="https://img.shields.io/badge/bootstrap-roothide%20%7C%20rootless-2ea44f" alt="roothide and rootless">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

<p align="center"><b>English</b> · <a href="README.zh-Hans.md">简体中文</a></p>

Luros is an IDE for a jailbroken iPhone or iPad, iOS 16 or later, on roothide or rootless. You can write a tweak, an app, a command-line tool or a preference bundle and take it all the way through on the device: compile, sign, package, install, read the log, symbolicate a crash. No Mac, no Xcode, no Apple ID.

![Preview](Documents/screenshots.jpg)

## This repository

Luros is a fork of [Apelin](https://github.com/owngoal-dev/Apelin). The package name, bundle ID, `lurosd` daemon and `luros-project.json` are ours, so it installs next to Apelin instead of over it. Since 0.3.4 the builds and releases come from this repository's CI: a tag publishes the packages that run produced, with `SHA256SUMS`, and nothing is rebuilt at release time.

What we've done on top of upstream:

- One package to install. `icli`, `irisind`, `irisin-install`, the four development extensions and the assembler and disassembler all live inside `Luros.app`, so neither Irisin nor icli has to be installed first.
- A terminal and a file browser of our own. Open Terminal and Browse Files work without Fila or iGhostVT.
- Every new project gets an Xcode project next to `luros-project.json`, which opens on a Mac as it is.
- Third-Party Tools reads the repositories the device already has, works out what a missing tool needs, and installs the closure through irisind.
- Agents can hand work to each other: the opener splits a job into steps with acceptance criteria, the children report back, and the whole assignment is sealed into one account that keeps what was delivered apart from what was only claimed.
- Settings ▸ Memory keeps the agent's long-term notes on the device, where you can edit them.
- GitHub does more than push. The app reads issues and pull requests, comments, closes, reopens, opens a pull request and merges it.
- Builds are cached by their sources and flags, and only the newest two build folders are kept.
- An app builds to an `.ipa` with its extensions under `PlugIns/`, and reinstalling the same bundle ID replaces it in place.

## What it does

**Building.** Apple's Command Line Tools are set up on the device, for C, C++ and Objective-C, with Swift as an option. Releases 14.2 to 27.2 stay side by side, and each one runs a self-test before it is registered; an interrupted setup picks up from its job record. iPhoneOS SDKs can be imported from an archive, a folder, or a branch of a one-SDK-per-branch repository, and every file is checked on the way in. Projects come from templates for tweaks, apps, CLI tools and preference bundles, from an empty workspace that keeps the repository's own build script, or as an app that builds to an `.ipa`. From there a build is signed with `ldid`, packaged, installed through the bundled irisind, and followed by a respring and a check that the tweak actually loaded. Distribute… checks a package before it goes out, builds a release for roothide and for rootless, and can publish either to a package repository of your own.

**The agent.** It edits the project, builds and installs it, reads logs and crash reports, and takes screenshots. Model providers include GitHub Copilot, Claude, ChatGPT Codex, DeepSeek, OpenCode, Antigravity, Trae, Raccoon and WorkBuddy, any number of OpenAI-compatible endpoints, or a plain API key. Plan mode answers without touching anything; Strict, Relaxed and Full decide what it may do on its own, and a root command always asks. Messages sent mid-turn queue up or steer the running turn at its next input boundary. A turn can be rewound, forked, edited or deleted, and each one is checkpointed in git first. There are skills, tool extensions you install, memory, notifications, a WeChat channel for running a conversation from your phone, and a headless console for scripted tests.

**The device and git.** A code editor, a terminal whose scrollback is numbered and bounded, and a file browser that treats an SDK or toolchain folder as a record instead of something to edit by hand. Git covers branches, merges, tags, stashes, squash, a force-with-lease that shows what leaves the branch, and remote-wins with the lost work kept on `luros-backup/<time>`. A toolchain (`.apetc`), an SDK (`.apesdk`) or a project (`.apeproj`) moves between your own devices as one file and is rebuilt for the target's bootstrap. The app speaks thirteen languages.

## Install

Download the package for your bootstrap from [Releases](https://github.com/1103945342/Luros/releases) and check it against `SHA256SUMS`:

| Bootstrap | Package |
| --- | --- |
| roothide | `com.fluoxetine.luros_<version>_iphoneos-arm64e.deb` |
| rootless (`/var/jb`) | `com.fluoxetine.luros_<version>_iphoneos-arm64.deb` |

iOS or iPadOS 16.0 or later, an A12 chip or later. Irisin and icli don't have to be installed: Luros carries the daemon it installs through and the tool it drives the device with. Which iOS versions and CPUs can run Swift depends on the toolchain release — [Compatibility](Documents/Compatibility.md) lists them.

The app carries the four project templates and the agent's assembler and disassembler, so no extension package is needed:

| Component | Adds |
| --- | --- |
| `com.fluoxetine.luros.dev.app` | UIKit apps in Objective-C or Swift |
| `com.fluoxetine.luros.dev.tweak` | Tweaks |
| `com.fluoxetine.luros.dev.cli` | Command-line tools in C or Objective-C |
| `com.fluoxetine.luros.dev.preferences` | Preference bundles |
| `com.fluoxetine.luros.agent-tools.disassembler` | A disassembler for the agent, on Capstone |
| `com.fluoxetine.luros.agent-tools.assembler` | An assembler for the agent, on Keystone (GPL-2.0; its source is published with each release) |

An extension package installed on its own wins over the bundled copy, and Luros still works if you remove one. The tweak template depends on an injection framework, which Luros itself does not.

Each version's notes are in [Documents/Releases](Documents/Releases/); `main` is ahead of the newest published release.

## Open in Luros

A repository's README can carry a button that opens the repository in Luros, which asks before importing it into a new project:

```markdown
[![Open in Luros](https://1103945342.github.io/Luros/open/badge.svg)](https://1103945342.github.io/Luros/open/?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo)
```

`url` is the repository's HTTPS address, URL-encoded. Add `&branch=<name>` to check out a branch other than the default. The link carries nothing else: no command, no message for the agent and no credential. Luros shows the address, the branch and the new project's name, and imports only once you confirm. Nothing in the repository runs, and nothing is sent to the agent. A private repository needs Sign In with GitHub in Settings ▸ Git. Without Luros, the page explains how to install it and lets you copy the address.

## Report a problem

Choose Report a Problem in Settings, or [open an issue on GitHub](https://github.com/1103945342/Luros/issues/new). Search the existing issues first to avoid duplicates.

If Luros crashes, or a build or an installation fails, include the log from Settings ▸ Logs. The log may contain your project names, paths and repository addresses, so read it before you share it.

## Privacy

Agent and git credentials stay in the keychain, on this device, and are never synced. There is no telemetry: a conversation goes only to the model provider you signed in to, and the diagnostic journal is redacted before it is written.

## Build from source

Open `Luros.xcodeproj` in the newest Xcode. To build the packages:

```sh
make harness      # run the tests on the Mac
make check        # project, packaging, string and accessibility checks
make deb-all      # build the roothide and rootless packages
make install DEVICE_HOST=<address> FLAVOR=roothide
```

You need `dpkg`, `ldid`, `zstd` and `swiftformat` from your preferred package manager. There is no Simulator build. Notes for contributors are in [AGENTS.md](AGENTS.md), and the [console](Documents/Console.md) drives the app headless.

## Credits

Luros is a fork of [Apelin](https://github.com/owngoal-dev/Apelin) by OwnGoal Studio, under the same MIT licence. Apple's Command Line Tools and iPhoneOS SDKs remain Apple's, under Apple's terms; Luros never ships them. The SDK source it reads by default is [1103945342/iOS-SDKs](https://github.com/1103945342/iOS-SDKs), after [owngoal-dev/iOS-SDKs](https://github.com/owngoal-dev/iOS-SDKs) and [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs). Third-party notices are in [Licenses/](Licenses/) and in the app under Settings ▸ Open Source Licenses.

---

Copyright © 2026 OwnGoal Studio and the Luros contributors. Released under the [MIT License](LICENSE).
