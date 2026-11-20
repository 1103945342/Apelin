#!/bin/bash
# The dependency resolver's rules, off a device: Debian version ordering, a
# `Depends` relation and its alternatives, a `Packages` index read for this
# architecture, dpkg's status read for what is installed, and the order a
# closure installs in — dependencies first, an installed alternative never
# fetched, a cycle ended, the newest version of a name chosen.
#
# Mac:    bash Scripts/test-package-resolution.sh
# Device: bash Scripts/test-package-resolution.sh --device
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mkdir -p build
work="$(mktemp -d build/package-resolution.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT
compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
device=
if [[ "${1:-}" == --device ]]; then
    device=1
    compiler=(swiftc -target arm64-apple-ios16.0)
fi
"${compiler[@]}" -swift-version 5 \
    Packages/ApelinKit/Sources/ApelinCore/Packages/PackageResolution.swift \
    Packages/ApelinKit/Sources/ApelinCore/Packages/PackageSources.swift \
    Tests/PackageResolution/ResolutionChecks.swift -o "$work/resolution-checks"
if [[ -n "$device" ]]; then
    ldid -S "$work/resolution-checks"
fi
"$work/resolution-checks"
