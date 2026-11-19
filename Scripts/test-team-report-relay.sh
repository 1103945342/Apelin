#!/bin/bash
# The report relay's own checks, on the device: a finished turn becomes one
# report and one message with a stable UUID; a rejected delivery and a restart
# retry that same UUID and frozen text; reports that arrive during a delivery
# travel in the next wave; a sealed group's final account is found through
# agent-assignments, acknowledged before its wave is cleared and retried whole
# when the acknowledgement fails; a blocked member is announced at once as a
# host status wave and the same status is not pushed twice; an outbox that does
# not read delivers nothing and is left as it was.
#
# The relay and the outbox are the real sources. ApelinCore and ApelinProtocol
# are copied into one scratch module (package imports dropped, Swift 6 trailing
# commas removed, the key-path overload spelled as a closure), together with the
# assignment ledger the final account comes from, and the two host types the
# relay reads are lightweight stand-ins in the checks file.
#
# Mac:    bash Scripts/test-team-report-relay.sh
# Device: bash Scripts/test-team-report-relay.sh --device <tool.entitlements>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mkdir -p build
work="$(mktemp -d build/team-report-relay.XXXXXX)"
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

sources=()
while IFS= read -r file; do sources+=("$file"); done < <(
    find Packages/ApelinKit/Sources/ApelinCore Packages/ApelinKit/Sources/ApelinProtocol -name '*.swift' | sort
)
sources+=(
    Apelind/Session/Agent/AgentReportRelay.swift
    Apelind/Session/Agent/AgentReportOutbox.swift
    Apelind/Session/Agent/AgentAssignmentStore.swift
    Tests/TeamCollaboration/ReportRelayChecks.swift
)

python3 - "$work" "${sources[@]}" <<'PY'
import os
import re
import sys

work = sys.argv[1]
trailing = re.compile(r",(\s*[\)\]\}])")
files = []
for path in sys.argv[2:]:
    # Top-level code is only allowed in a file named main.swift.
    name = "main.swift" if path.endswith("ReportRelayChecks.swift") else path.replace("/", "__")
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"^import (ApelinCore|ApelinProtocol)\n", "", text, flags=re.M)
    text = trailing.sub(r"\1", text)
    text = text.replace("octets.compactMap(\\.self)", "octets.compactMap { $0 }")
    target = os.path.join(work, name)
    open(target, "w", encoding="utf-8").write(text)
    files.append(target)
open(os.path.join(work, "files.txt"), "w").write("\n".join(files))
PY

"${compiler[@]}" -swift-version 5 -parse-as-library \
    -o "$work/report-relay-checks" $(<"$work/files.txt")
if [[ -n "$entitlements" ]]; then
    ldid "-S$entitlements" "$work/report-relay-checks"
fi
"$work/report-relay-checks"
