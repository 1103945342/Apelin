#!/bin/bash
# Pure onboarding and project policy against the protocol/Core objects the
# harness built.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
modules="$1"
work="$(mktemp -d -t luros-onboarding)"
trap 'rm -rf -- "${work:?}"' EXIT
objects=()
for module in ApelinCore ApelinProtocol; do
    if [[ -f "$modules/$module.o" ]]; then
        objects+=("$modules/$module.o")
    else
        while IFS= read -r object; do objects+=("$object"); done < <(find "$modules/.." "$modules" -maxdepth 2 -path "*/$module.build/*.o" | sort -u)
    fi
done
[[ ${#objects[@]} -ge 2 ]] || { echo "error: onboarding tests need the harness modules" >&2; exit 1; }
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
    -I "$root/Shared/XPCShim" -I "$modules" "${objects[@]}" \
    "$root/Luros/Interface/Onboarding/WelcomeEnvironmentRecommendation.swift" \
    "$root/Luros/Interface/Projects/ProjectCreationDraft.swift" \
    "$root/Luros/Interface/Projects/ProjectBuildMethod.swift" \
    "$root/Tests/Onboarding/main.swift" -o "$work/onboarding"
"$work/onboarding"
