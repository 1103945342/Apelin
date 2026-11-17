#!/bin/bash
# The confined writer a delegated conversation writes through: descriptor
# checks, links, exclusive creation and a parent replaced by a link.
# Mac: no arguments. Device: --device <entitlements>.
#
# The sources are copied into the work directory with the repository's
# trailing commas dropped first: the device's Swift 5.10 predates them.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mkdir -p build
work="$(mktemp -d build/team-confined-writer.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT
compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
entitlements=
if [[ "${1:-}" == --device ]]; then
    : "${2:?tool entitlements required}"
    entitlements="$2"
    compiler=(swiftc -target arm64-apple-ios16.0)
fi

python3 - "$root" "$work" <<'PYTHON'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
work = pathlib.Path(sys.argv[2])
trailing = re.compile(r",(\s*)([\)\]])")
for source in (
    "Packages/ApelinAgent/Sources/ApelinAgent/Paths/ConfinedWriter.swift",
    "Tests/TeamCollaboration/ConfinedWriterChecks.swift",
):
    text = (root / source).read_text()
    (work / pathlib.Path(source).name).write_text(trailing.sub(r"\1\2", text))
PYTHON

"${compiler[@]}" -swift-version 5 -parse-as-library \
    "${work:?}/ConfinedWriter.swift" \
    "${work:?}/ConfinedWriterChecks.swift" -o "${work:?}/confined-writer-checks"
if [[ -n "$entitlements" ]]; then
    ldid "-S$entitlements" "${work:?}/confined-writer-checks"
fi
"${work:?}/confined-writer-checks"
