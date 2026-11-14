#!/bin/bash
# The iLink (WeChat ClawBot) protocol's own checks, without the app around it:
# which addresses the bot token may go to and how a redirect is judged, the one
# session file (0600, atomic, a broken file kept), the inbound filter (direction,
# the bot's echo copies, stable ids), the whole login walk, the long poll with
# its cursor rule and its failure counting, and what a send puts on the wire.
#
# The package's sources are compiled into their module first, then the checks
# and Tests/WeChat/main.swift are compiled against it. Nothing here reaches the
# network: the checks answer from a transport of their own.
#
# Mac:    bash Scripts/test-wechat.sh
# Device: bash Scripts/test-wechat.sh --device <tool.entitlements>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mkdir -p build
# The checks make their fixtures under FileManager's temporary directory, so
# TMPDIR points at a folder of this run's own, inside the project's build/.
work="$(mktemp -d build/wechat.XXXXXX)"
mkdir -p "$work/tmp"
export TMPDIR="${APELIN_PROJECT_ROOT:-$root}/$work/tmp"
trap 'rm -rf -- "${work:?}"' EXIT

compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
entitlements=
if [[ "${1:-}" == --device ]]; then
    : "${2:?tool entitlements required, as test-sidebar-tree.sh takes one}"
    entitlements="$2"
    compiler=(swiftc -target arm64-apple-ios16.0)
fi

sources=(Packages/ApelinWeChat/Sources/ApelinWeChat/*.swift)
checks=(Packages/ApelinWeChat/Tests/ApelinWeChatTests/Checks/*.swift)
runner=(Tests/WeChat/main.swift)

"${compiler[@]}" -swift-version 5 -wmo -parse-as-library -module-name ApelinWeChat \
    -emit-module -emit-module-path "$work/ApelinWeChat.swiftmodule" \
    -c "${sources[@]}" -o "$work/ApelinWeChat.o"

"${compiler[@]}" -swift-version 5 -I "$work" \
    "${checks[@]}" "${runner[@]}" "$work/ApelinWeChat.o" -o "$work/wechat-checks"
if [[ -n "$entitlements" ]]; then
    ldid "-S$entitlements" "$work/wechat-checks"
fi
"$work/wechat-checks"
