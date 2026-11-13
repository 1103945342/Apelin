#!/bin/bash
# The terminal backend's own checks — the bounded history, where a terminal
# starts, a real pty with an input-only socket — as Tests/SessionHost's
# TerminalChecks.swift runs them, on the device.
#
# On a Mac and in CI the same checks run inside `make harness`, through
# Scripts/test-session-host.sh, against the modules `swift build` leaves. This
# script is the device's half: `swift build` does not run there, so every
# source the checks reach is copied into one scratch module and built by the
# device's own swiftc. The copy is rewritten in three ways only — the package
# imports go (one module here), Swift 6's trailing comma in argument lists and
# collection literals goes (the device's swiftc is 5.10), and a key path to
# `\.self` used as a function becomes a closure.
#
# Device: bash Scripts/test-terminal.sh --device <tool.entitlements>
#
# The entitlements are the ones a program shell_run starts needs, as
# test-sidebar-tree.sh takes them; without --device there is nothing here to
# do, since the Mac path is the harness.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"

if [[ "${1:-}" != --device ]]; then
    echo "usage: test-terminal.sh --device <tool.entitlements>" >&2
    echo "on a Mac, run the same checks with: make harness" >&2
    exit 64
fi
: "${2:?tool entitlements required, as test-sidebar-tree.sh takes one}"
entitlements="$2"

mkdir -p build
work="$(mktemp -d build/terminal-backend.XXXXXX)"
mkdir -p "$work/tmp"
# The checks make their scratch folders from NSTemporaryDirectory, so TMPDIR
# points at this run's own folder. It is made through the relative path above
# and handed over as the real absolute path, taken at run time.
export TMPDIR="${APELIN_PROJECT_ROOT:-$root}/$work/tmp"
trap 'rm -rf -- "${work:?}"' EXIT

# Everything the checks reach, and the two stand-ins they compile instead of
# Apelind/Spawn.swift and Apelind/System.swift.
mapfile -t sources < <(
    ls Packages/ApelinKit/Sources/ApelinCore/*.swift
    ls Packages/ApelinKit/Sources/ApelinProtocol/*.swift
    find Packages/ApelinKit/Sources/ApelinProtocol -mindepth 2 -name '*.swift' | sort
    echo Apelind/Session/CallerPolicy.swift
    echo Apelind/Session/Files/FileScopes.swift
    echo Apelind/Session/Files/ProtectedEditPolicy.swift
    echo Apelind/Session/TaskRegistry.swift
    echo Apelind/Session/Terminal/TerminalSession.swift
    echo Apelind/Session/Terminal/TerminalHost.swift
    echo Tests/SessionHost/TerminalChecks.swift
    echo Tests/TerminalBackend/SpawnShim.swift
    echo Tests/TerminalBackend/main.swift
)

python3 - "$work" "${sources[@]}" <<'PY'
import os
import re
import sys

work = sys.argv[1]
seen = set()
files = []
for path in sys.argv[2:]:
    if path in seen:
        continue
    seen.add(path)
    # Top-level code is only allowed in a file named main.swift.
    name = "main.swift" if path.endswith("Tests/TerminalBackend/main.swift") else path.replace("/", "__")
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"^import (ApelinCore|ApelinProtocol)\n", "", text, flags=re.M)
    text = text.replace("compactMap(\\.self)", "compactMap { $0 }")
    text = re.sub(r",(\s*[\)\]\}])", r"\1", text)
    target = os.path.join(work, name)
    open(target, "w", encoding="utf-8").write(text)
    files.append(target)
open(os.path.join(work, "files.txt"), "w").write("\n".join(files))
PY

swiftc -swift-version 5 -target arm64-apple-ios16.0 -Onone \
    -o "$work/terminal-backend" $(<"$work/files.txt")
ldid "-S$entitlements" "$work/terminal-backend"
APELIN_TERMINAL_SHELL="$(command -v sh || true)" "$work/terminal-backend"
