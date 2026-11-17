#!/bin/bash
# The durable assignment ledger store (Documents/Plan/Team-Collaboration.md §6):
# one file per opener, atomic saves, fail-closed reads, idempotent registration,
# plan sync that adds a derived state and preserves explicit ones, a finished
# plan that never becomes acceptance, stale-plan refusal, a failed write that
# publishes nothing, and everything surviving a restart.
#
# The store sits in Apelind and imports ApelinProtocol as a module; the device
# has no `swift build`, so every source it reaches is copied into one scratch
# module exactly as test-terminal.sh does: package imports go, Swift 6 trailing
# commas go (the device's swiftc is 5.10).
#
# Mac:    bash Scripts/test-team-assignment-store.sh
# Device: bash Scripts/test-team-assignment-store.sh --device <tool.entitlements>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mkdir -p build
work="$(mktemp -d build/team-assignment-store.XXXXXX)"
mkdir -p "$work/tmp"
# The checks make their scratch folders from NSTemporaryDirectory, so TMPDIR
# points at this run's own folder, handed over as the real absolute path.
export TMPDIR="${APELIN_PROJECT_ROOT:-$root}/$work/tmp"
trap 'rm -rf -- "${work:?}"' EXIT
compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
entitlements=
if [[ "${1:-}" == --device ]]; then
    : "${2:?tool entitlements required}"
    entitlements="$2"
    compiler=(swiftc -target arm64-apple-ios16.0)
fi

sources=(
    Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentDelegationBrief.swift
    Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentAssignmentLedger.swift
    Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentTurnReport.swift
    Apelind/Session/Agent/AgentAssignmentStore.swift
    Tests/TeamCollaboration/AssignmentStoreChecks.swift
)
python3 - "$work" "${sources[@]}" <<'PY'
import os
import re
import sys

work = sys.argv[1]
files = []
for path in sys.argv[2:]:
    # Top-level code is only allowed in a file named main.swift.
    name = "main.swift" if path.endswith("AssignmentStoreChecks.swift") else path.replace("/", "__")
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"^import (ApelinCore|ApelinProtocol)\n", "", text, flags=re.M)
    text = re.sub(r",(\s*[\)\]\}])", r"\1", text)
    target = os.path.join(work, name)
    open(target, "w", encoding="utf-8").write(text)
    files.append(target)
open(os.path.join(work, "files.txt"), "w").write("\n".join(files))
PY

"${compiler[@]}" -swift-version 5 -parse-as-library \
    -o "$work/assignment-store-checks" $(<"$work/files.txt")
if [[ -n "$entitlements" ]]; then
    ldid "-S$entitlements" "$work/assignment-store-checks"
fi
"$work/assignment-store-checks"
