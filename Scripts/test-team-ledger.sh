#!/bin/bash
# Assignment ledger model checks (Documents/Plan/Team-Collaboration.md §6):
# member state versus run outcome, receipts and missing checks, an unverified
# acceptance that stays unverified, group revision and seal, an outdated
# summary, and one deduplicated final account per revision — with the brief and
# plan compiled alongside to show the ledger uses their revisions unchanged.
#
# Mac:    bash Scripts/test-team-ledger.sh
# Device: bash Scripts/test-team-ledger.sh --device <tool.entitlements>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mkdir -p build
work="$(mktemp -d build/team-ledger.XXXXXX)"
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
    Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentAssignmentLedger.swift \
    Tests/TeamCollaboration/LedgerChecks.swift -o "$work/ledger-checks"
if [[ -n "$entitlements" ]]; then
    ldid "-S$entitlements" "$work/ledger-checks"
fi
"$work/ledger-checks"
