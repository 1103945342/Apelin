#!/bin/bash
# Standalone signing regression, using the real installer and its two core
# path utilities. No package dependencies or daemon privileges required.
# Mac: bash Scripts/test-application-install.sh
# Device: bash Scripts/test-application-install.sh --device <tool.entitlements>
# Device mode also calls real ldid on a project-local fixture, never installs it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
work="$(mktemp -d build/application-install.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT
core=Packages/ApelinKit/Sources/ApelinCore
compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
live=()
if [[ "${1:-}" == --device ]]; then
    : "${APELIN_PROJECT_ROOT:?}" "${APELIN_TOOLCHAIN_BIN:?}" "${2:?tool entitlements required}"
    compiler=(swiftc -target arm64-apple-ios16.0)
    install_root="${APELIN_TOOLCHAIN_BIN%%/usr/lib/apelin/toolchains/*}"
    [[ -n "$install_root" && "$install_root" != "$APELIN_TOOLCHAIN_BIN" ]] || exit 64
    printf 'int main(void) { return 0; }\n' > "$work/fixture.c"
    clang -arch arm64 "$work/fixture.c" -o "$work/fixture"
    printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>get-task-allow</key><true/></dict></plist>' > "$work/app.plist"
    ldid "-S$work/app.plist" "$work/fixture"
    live=("$install_root" "$install_root/usr/bin/ldid" "$APELIN_PROJECT_ROOT/$work/fixture")
fi
"${compiler[@]}" -swift-version 5 -parse-as-library -whole-module-optimization \
    -module-name ApelinCore -emit-module -emit-module-path "$work/ApelinCore.swiftmodule" \
    -emit-object "$core/CanonicalPath.swift" "$core/BootstrapRootPath.swift" -o "$work/ApelinCore.o"
"${compiler[@]}" -swift-version 5 -I "$work" "$work/ApelinCore.o" \
    Apelind/Session/Install/ApplicationInstall.swift Tests/ApplicationInstall/main.swift \
    -o "$work/check"
if [[ "${1:-}" == --device ]]; then
    ldid "-S$2" "$work/check"
    "$work/check" "$APELIN_PROJECT_ROOT/$work/data" "${live[@]}"
else
    "$work/check" "$PWD/$work/data"
fi
