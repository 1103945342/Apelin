#!/bin/bash
# The terminal page's pure logic, without the app around it: where a terminal
# starts and what a record may write down about it (TerminalTarget), what a
# task's events mean to the screen (TerminalWireEvent), what survives of
# `Terminals/sessions.json` (TerminalSessionRecord), and the decisions that keep
# a replay honest — numbering, truncation, the fixed end of the history, and
# what an open that lands after the page moved on is worth (TerminalAttachment,
# TerminalBatchCheck).
#
# The model imports ApelinCore for JSONCoding, JSONValue, PreservedList and
# UnreadableFile alone, so the module is built from those two files here: two
# stages, then the model and the checks against it. None of it needs UIKit,
# SnapKit or ghostty; the page and the session are typechecked by the app.
#
# Mac:    bash Tests/TerminalUI/run.sh
# Device: bash Tests/TerminalUI/run.sh --device <tool.entitlements>
set -euo pipefail

root="$(cd -P "$(dirname "$0")/../.." && pwd -P)"
# On roothide the bootstrap's `/var` is not where the project is, and `/rootfs`
# is not part of a real path; the compiler wants the physical one.
root="${root#/rootfs}"
if [[ -n "${APELIN_PROJECT_ROOT:-}" ]]; then
    root="${APELIN_PROJECT_ROOT#/rootfs}"
fi
cd "$root"
mkdir -p build
work="$(mktemp -d build/terminal-ui.XXXXXX)"
# The checks make their fixtures from FileManager's temporary directory, so
# TMPDIR points at this run's own folder inside the project's build/, handed
# over as the real absolute path $root already is.
mkdir -p "$work/tmp"
export TMPDIR="$root/$work/tmp"
trap 'rm -rf -- "${work:?}"' EXIT

compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
entitlements=
if [[ "${1:-}" == --device ]]; then
    : "${2:?tool entitlements required, as test-sidebar-tree.sh takes one}"
    entitlements="$2"
    compiler=(swiftc -target arm64-apple-ios16.0)
fi

core=(
    Packages/ApelinKit/Sources/ApelinCore/JSON.swift
    Packages/ApelinKit/Sources/ApelinCore/PreservedList.swift
)
"${compiler[@]}" -swift-version 5 -parse-as-library -module-name ApelinCore \
    -emit-module -emit-module-path "$work/ApelinCore.swiftmodule" "${core[@]}"
"${compiler[@]}" -swift-version 5 -parse-as-library -wmo -module-name ApelinCore \
    -c -o "$work/ApelinCore.o" "${core[@]}"

model=(
    Apelin/Interface/Terminal/TerminalTarget.swift
    Apelin/Interface/Terminal/TerminalAttachment.swift
    Apelin/Interface/Terminal/TerminalInputRouter.swift
    Apelin/Interface/Terminal/TerminalWireEvent.swift
    Apelin/Interface/Terminal/TerminalSessionRecord.swift
)
checks=(
    Tests/TerminalUI/TerminalTargetCheck.swift
    Tests/TerminalUI/TerminalWireEventCheck.swift
    Tests/TerminalUI/TerminalSessionStoreCheck.swift
    Tests/TerminalUI/TerminalAttachmentCheck.swift
    Tests/TerminalUI/TerminalBatchCheck.swift
    Tests/TerminalUI/TerminalFeedCheck.swift
    Tests/TerminalUI/TerminalUIChecks.swift
)

# Exclusive-access checks on: runBatch hands a closure to code that is itself
# modifying the attachment, and a closure that reached back into it would trap
# here rather than in the app.
"${compiler[@]}" -swift-version 5 -parse-as-library -enforce-exclusivity=checked \
    -I "$work" -o "$work/check" "${model[@]}" "${checks[@]}" "$work/ApelinCore.o"

if [[ -n "$entitlements" ]]; then
    ldid "-S$entitlements" "$work/check"
fi

"$work/check"
