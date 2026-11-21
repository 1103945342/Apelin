#!/bin/bash
# The transcript measures a block of text with Core Text rather than by
# laying a label out (Luros/Interface/Chats/Messages/TraceBody.swift); its
# row height is only right while the two agree. This runs the comparison on
# the device, where the fonts and UIKit are the ones the app draws with.
#
# Device: bash Scripts/test-text-height.sh --device <tool.entitlements>
set -euo pipefail

# The path the toolchain can open: on roothide `pwd -P` answers `/rootfs/…`.
root="$(cd "$(dirname "$0")/.." && pwd -P)"
root="${root#/rootfs}"
cd "$root"

if [[ "${1:-}" != --device ]]; then
    echo "usage: test-text-height.sh --device <tool.entitlements>" >&2
    exit 64
fi
: "${2:?tool entitlements required}"
entitlements="$2"

mkdir -p build
work="$(mktemp -d build/text-height.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT

python3 - "$work" <<'PY'
import re, sys
work = sys.argv[1]
text = open("Tests/LayoutMetrics/TextHeightChecks.swift", encoding="utf-8").read()
text = re.sub(r",(\s*[\)\]\}])", r"\1", text)
open(work + "/main.swift", "w", encoding="utf-8").write(text)
PY

swiftc -swift-version 5 -target arm64-apple-ios16.0 -Onone -parse-as-library \
    -o "$work/text-height" "$work/main.swift"
ldid "-S$entitlements" "$work/text-height"
"$work/text-height"
