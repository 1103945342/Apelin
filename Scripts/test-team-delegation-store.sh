#!/usr/bin/env bash
# Isolated production store/policy tests. Wire/service wrappers alone are omitted.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mkdir -p build
work="$(mktemp -d build/team-delegation-store.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT
compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
entitlements=
if [[ "${1:-}" == --device ]]; then
    : "${2:?tool entitlements required}"
    entitlements="$2"
    compiler=(swiftc -target arm64-apple-ios16.0)
fi
python3 - "$work" <<'PY'
import pathlib, re, sys
work = pathlib.Path(sys.argv[1])
files = [
    'Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentDelegationBrief.swift',
    'Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentDelegation.swift',
    'Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentAssignmentLedger.swift',
    'Packages/ApelinKit/Sources/ApelinCore/CanonicalPath.swift',
    'Apelind/Session/Agent/AgentDelegationStore.swift',
    'Tests/TeamCollaboration/DelegationStoreChecks.swift',
]
for name in files:
    source = pathlib.Path(name)
    text = source.read_text()
    text = re.sub(r'^import (ApelinCore|ApelinProtocol)\n', '', text, flags=re.M)
    if source.name == 'AgentDelegation.swift':
        text = text.replace(': OperationRequest {', ': Codable, Sendable {')
        text = re.sub(r'^    public static let operation = .*\n', '', text, flags=re.M)
        start = text.index('public extension ApelinService {')
        end = text.index('/// A deliberately closed', start)
        text = text[:start] + text[end:]
    text = re.sub(r',(\s*)([)\]])', r'\1\2', text)
    (work / source.name).write_text(text)
PY
"${compiler[@]}" -swift-version 5 -parse-as-library "$work"/*.swift -o "$work/checks"
if [[ -n "$entitlements" ]]; then ldid "-S$entitlements" "$work/checks"; fi
"$work/checks" "$work"
