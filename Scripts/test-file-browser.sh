#!/bin/bash
# The file browser's model, without the app around it: where a place may
# change and why not, how far Up goes and what a link is judged by, the path
# trail under the bar and when it moves sideways, what one folder lists, what
# each operation is held to, and what a save is refused for after the page
# that opened it is gone — plus the locations menu, read off the bundle's own
# path.
#
# The model imports ApelinCore for CanonicalPath alone, so the module is built
# from that one file here: two stages, then the model, the tests and
# Shared/RoothideRoot.swift against it.
#
# Mac:    bash Scripts/test-file-browser.sh
# Device: bash Scripts/test-file-browser.sh --device <tool.entitlements>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
mkdir -p build
# The tests make their fixtures under FileManager's temporary directory, so
# TMPDIR points at a folder of this run's own, inside the project's build/.
# The shell here is the bootstrap's, whose view of a path is not the one a
# program it runs opens: the folder is made through the relative path, and
# the program is handed the real absolute path, taken at run time from
# $APELIN_PROJECT_ROOT and never written down.
work="$(mktemp -d build/file-browser.XXXXXX)"
mkdir -p "$work/tmp"
export TMPDIR="${APELIN_PROJECT_ROOT:-$root}/$work/tmp"
trap 'rm -rf -- "${work:?}"' EXIT

compiler=(xcrun --sdk macosx swiftc -target arm64-apple-macos13.0)
entitlements=
if [[ "${1:-}" == --device ]]; then
    : "${2:?tool entitlements required, as test-sidebar-tree.sh takes one}"
    entitlements="$2"
    compiler=(swiftc -target arm64-apple-ios16.0)
fi

core=(Packages/ApelinKit/Sources/ApelinCore/CanonicalPath.swift)
"${compiler[@]}" -swift-version 5 -parse-as-library -module-name ApelinCore \
    -emit-module -emit-module-path "$work/ApelinCore.swiftmodule" "${core[@]}"
"${compiler[@]}" -swift-version 5 -parse-as-library -module-name ApelinCore \
    -c -o "$work/ApelinCore.o" "${core[@]}"

model=(
    Apelin/Interface/Files/FileBrowserBreadcrumb.swift
    Apelin/Interface/Files/FileBrowserFailure.swift
    Apelin/Interface/Files/FileBrowserListing.swift
    Apelin/Interface/Files/FileBrowserLocation.swift
    Apelin/Interface/Files/FileBrowserLocations.swift
    Apelin/Interface/Files/FileBrowserOperations.swift
    Apelin/Interface/Files/FileBrowserPolicy.swift
    Apelin/Interface/Files/FileBrowserWriteGuard.swift
)
checks=(
    Tests/FileBrowser/FileBrowserLocationCheck.swift
    Tests/FileBrowser/FileBrowserBreadcrumbCheck.swift
    Tests/FileBrowser/FileBrowserPolicyCheck.swift
    Tests/FileBrowser/FileBrowserListingCheck.swift
    Tests/FileBrowser/FileBrowserOperationsCheck.swift
    Tests/FileBrowser/FileBrowserWriteGuardCheck.swift
    Tests/FileBrowser/FileBrowserLocationsCheck.swift
    Tests/FileBrowser/main.swift
)

"${compiler[@]}" -swift-version 5 -I "$work" \
    "${model[@]}" Shared/RoothideRoot.swift "$work/ApelinCore.o" "${checks[@]}" \
    -o "$work/file-browser"
if [[ -n "$entitlements" ]]; then
    ldid "-S$entitlements" "$work/file-browser"
fi
"$work/file-browser"

# The two UIKit files are parsed only, not type-checked: the page needs the
# app's SnapKit, Then, SPIndicator and AlertController modules, which this
# harness does not build. The Xcode build of the app type-checks them.
"${compiler[@]}" -swift-version 5 -parse \
    Apelin/Interface/Files/FileBrowserController.swift \
    Apelin/Interface/Files/FileBrowserPresenter.swift
