#!/bin/bash
# Type-checks and runs the session host's delegation authority: the real
# AgentDelegationStore and AgentDelegationAdmission, against the real
# ApelinCore and ApelinProtocol modules, with lightweight host stubs.
# Mac: no arguments. Device: --device <entitlements>.
#
# The sources are copied into the work directory with the repository's
# trailing commas dropped first: the device's Swift 5.10 predates them.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mkdir -p build
work="$(mktemp -d build/team-delegation-handler.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT
compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
target=arm64-apple-macos13.0
entitlements=
if [[ "${1:-}" == --device ]]; then
    : "${2:?tool entitlements required}"
    entitlements="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
    compiler=(swiftc)
    target=arm64-apple-ios16.0
fi

python3 - "$root" "$work" <<'PYTHON'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
work = pathlib.Path(sys.argv[2])
trailing = re.compile(r",(\s*)([\)\]])")

SELF_IMPORT = __import__("re").compile(r"^import (?:struct |enum |class |protocol )?Apelin(?:Core|Protocol)(?:\.[^\n]*)?\n", __import__("re").M)

def copy(source: str, into: str) -> None:
    text = (root / source).read_text()
    text = trailing.sub(r"\1\2", text)
    text = text.replace("octets.compactMap(\\.self)", "octets.compactMap { $0 }")
    # One module: a file does not import the package it is copied into.
    text = SELF_IMPORT.sub("", text)
    destination = work / into
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)

for path in (root / "Packages/ApelinKit/Sources/ApelinCore").rglob("*.swift"):
    copy(str(path.relative_to(root)), str(pathlib.Path("Core") / "ApelinCore" / path.relative_to(root / "Packages/ApelinKit/Sources/ApelinCore")))
for path in (root / "Packages/ApelinKit/Sources/ApelinProtocol").rglob("*.swift"):
    copy(str(path.relative_to(root)), str(pathlib.Path("Protocol") / path.relative_to(root / "Packages/ApelinKit/Sources/ApelinProtocol")))
copy("Apelind/Session/Agent/AgentDelegationStore.swift", "Host/AgentDelegationStore.swift")
copy("Apelind/Session/Agent/AgentDelegationAdmission.swift", "Host/AgentDelegationAdmission.swift")
copy("Apelind/Dispatch/AgentDelegationHandler.swift", "Host/AgentDelegationHandler.swift")
copy("Apelind/Session/Agent/AgentAssignmentStore.swift", "Host/AgentAssignmentStore.swift")
copy("Tests/TeamCollaboration/DelegationHandlerChecks.swift", "Checks/DelegationHandlerChecks.swift")
(work / "mods").mkdir()
PYTHON

cd "$work"
# One module: the two packages' sources are copied in without their own
# imports, so the handler compiles against the very code the app ships
# rather than against a second build of it.
"${compiler[@]}" -target "$target" -swift-version 5 -parse-as-library \
    -module-name DelegationHandlerChecks \
    $(find Core Protocol Host Checks -name '*.swift') \
    -o delegation-handler-checks
if [[ -n "$entitlements" ]]; then
    ldid "-S$entitlements" delegation-handler-checks
fi
./delegation-handler-checks
