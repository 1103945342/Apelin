#!/usr/bin/env bash
# Type-checks LurosKit's LurosCore and LurosProtocol against the registered
# SDK, on the device itself. `swift test` cannot run here (no resolved SwiftPM
# dependencies), and this device's Swift 5.10 predates two things the repository
# uses: trailing commas in argument lists, and backticked test names with
# spaces. This copies the two modules into build/, drops the trailing commas,
# and builds them in an ignored project-local scratch directory, so a protocol
# change is checked by a real compiler.
#
# Usage: Scripts/typecheck-luroskit-protocol.sh [module ...]
# Without arguments it checks LurosCore and LurosProtocol. Sources are unchanged.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
: "${SDKROOT:?run this where the Luros toolchain environment is set}"
mkdir -p build
work="$(mktemp -d build/protocol-check.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT
mkdir -p "$work/mods"

python3 - "$root" "$work" <<'PYTHON'
import pathlib
import re
import shutil
import sys

root = pathlib.Path(sys.argv[1])
work = pathlib.Path(sys.argv[2])
trailing = re.compile(r",(\s*)([\)\]])")

for module in ("LurosCore", "LurosProtocol"):
    source = root / "Packages/LurosKit/Sources" / module
    target = work / module
    for path in source.rglob("*.swift"):
        text = path.read_text()
        # Swift 6 (the repository) allows a trailing comma; 5.10 does not.
        text = trailing.sub(r"\1\2", text)
        # Swift 6 infers the key-path overload; 5.10 needs the closure.
        text = text.replace("octets.compactMap(\\.self)", "octets.compactMap { $0 }")
        destination = target / path.relative_to(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text)
PYTHON

target="arm64-apple-ios16.0"

modules=("$@")
if [ ${#modules[@]} -eq 0 ]; then
    modules=(LurosCore LurosProtocol)
fi

for module in "${modules[@]}"; do
    files=()
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$work/$module" -name "*.swift" | sort)
    echo "checking $module (${#files[@]} files)"
    case "$module" in
    LurosCore)
        swiftc -sdk "$SDKROOT" -target "$target" -swift-version 5 \
            -emit-module -parse-as-library -module-name LurosCore "${files[@]}" \
            -emit-module-path "$work/mods/LurosCore.swiftmodule"
        ;;
    LurosProtocol)
        if [ ! -f "$work/mods/LurosCore.swiftmodule" ]; then
            echo "error: check LurosCore first" >&2
            exit 1
        fi
        swiftc -sdk "$SDKROOT" -target "$target" -swift-version 5 \
            -typecheck -module-name LurosProtocol -I "$work/mods" "${files[@]}"
        ;;
    *)
        echo "error: only LurosCore and LurosProtocol are checked here" >&2
        exit 1
        ;;
    esac
done

echo "ok: ${modules[*]} type-checked against $SDKROOT ($target)"
