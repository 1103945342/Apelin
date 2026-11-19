#!/bin/bash
# Pure delegation model checks. Mac: no arguments. Device: --device <entitlements>.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mkdir -p build
work="$(mktemp -d build/team-brief.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT
compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
entitlements=
if [[ "${1:-}" == --device ]]; then
    : "${2:?tool entitlements required}"
    entitlements="$2"
    compiler=(swiftc -target arm64-apple-ios16.0)
fi
"${compiler[@]}" -swift-version 5 -parse-as-library \
    Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentDelegationBrief.swift \
    Tests/TeamCollaboration/BriefChecks.swift -o "$work/brief-checks"
if [[ -n "$entitlements" ]]; then
    ldid "-S$entitlements" "$work/brief-checks"
fi
"$work/brief-checks"
