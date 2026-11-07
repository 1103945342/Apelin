#!/bin/bash
# Pure production tree and title rules, without app dependencies.
# Mac: bash Scripts/test-sidebar-tree.sh
# Device: bash Scripts/test-sidebar-tree.sh --device <tool.entitlements>
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
work="$(mktemp -d build/sidebar-tree.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT
compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
if [[ "${1:-}" == --device ]]; then
    : "${2:?tool entitlements required}"
    compiler=(swiftc -target arm64-apple-ios16.0)
fi
sources=(
    Apelin/Interface/Chats/ChatSummary.swift
    Apelin/Interface/Root/SidebarOrder.swift
    Apelin/Interface/Root/SidebarTree.swift
)
"${compiler[@]}" -swift-version 5 "${sources[@]}" \
    Tests/ChatTranscript/SidebarTreeCheck.swift Tests/SidebarTree/main.swift -o "$work/check"
if [[ "${1:-}" == --device ]]; then
    ldid "-S$2" "$work/check"
    # Also type-check the real UIKit row, not a mock of its layout API.
    "${compiler[@]}" -swift-version 5 -typecheck "${sources[@]}" \
        Apelin/Interface/Root/ChatRowStatusView.swift Apelin/Interface/Root/SidebarTreeCell.swift
fi
"$work/check"
