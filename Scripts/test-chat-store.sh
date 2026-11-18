#!/bin/bash
# The chat store's own checks (Tests/ChatStore/Check.swift) on the device's own
# toolchain: the record kept without its events, the events beside it, the
# one-time move out of a record that still carries them, and what a launch cut
# off between the two reads.
#
# The app's store is compiled with the packages it reads (ApelinCore,
# ApelinProtocol) and the two app types it needs, into one program, because the
# app target itself needs xcodebuild. Imports between them are dropped for that
# one module, and the Swift 6 spellings a 5.10 toolchain lacks are rewritten.
#
# usage: test-chat-store.sh --device [<tool.entitlements>]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"

if [[ "${1:-}" != --device ]]; then
    echo "usage: $0 --device [<tool.entitlements>]" >&2
    exit 64
fi
shift
entitlements="${1:-build/Tool.entitlements}"
[[ -f "$entitlements" ]] || { echo "error: no such entitlements file: $entitlements" >&2; exit 64; }

mkdir -p build
work="$(mktemp -d build/store-checks.XXXXXX)"
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import glob
import os
import re
import sys

work = sys.argv[1]
source = os.path.join(work, "src")
os.makedirs(source)

files = []
for package in ("ApelinProtocol", "ApelinCore"):
    files += glob.glob(f"Packages/ApelinKit/Sources/{package}/**/*.swift", recursive=True)
files += [
    "Apelin/Interface/Chats/ChatSummary.swift",
    "Apelin/Interface/Chats/Composer/ComposerDraft.swift",
    "Apelin/Interface/Chats/ChatStore.swift",
    "Apelin/Interface/Chats/ChatEventsFile.swift",
    "Tests/ChatStore/Check.swift",
]

for number, path in enumerate(sorted(files)):
    text = open(path).read()
    # One module: the imports between these files point at modules that are
    # not built here.
    text = re.sub(r"^import (ApelinCore|ApelinProtocol)\n", "", text, flags=re.M)
    # A 5.10 toolchain: no trailing commas in collections, no `count(where:)`,
    # no bare `\.self` transforms.
    text = re.sub(r",(\s*[)\]])", r"\1", text)
    text = re.sub(r"\.count \{ (\$0\.kind == [^}]+) \}", r".filter { \1 }.count", text)
    text = text.replace("compactMap(\\.self)", "compactMap { $0 }").replace("flatMap(\\.self)", "flatMap { $0 }")
    name = re.sub(r"[^A-Za-z0-9_.]", "_", os.path.basename(path))
    open(os.path.join(source, f"{number:03d}_{name}"), "w").write(text)

# The two members of `ChatTranscript` the record and its replay name, and the
# one of `ChatSummary` the record uses: the real ones live in files this check
# has no other reason to build.
open(os.path.join(source, "900_stubs.swift"), "w").write('''
import Foundation

enum ChatTranscript {
    static func endsTask(_ event: TaskEvent) -> Bool { false }
    static func userMessageID(of event: TaskEvent) -> UUID? { nil }
    static func acceptedMessages(in event: TaskEvent) -> [TaskEvent] { [] }
    static func rowID(forEventAt index: Int) -> UUID { UUID() }
}

extension ChatSummary {
    @discardableResult
    mutating func markRead() -> Bool { true }
}
''')

open(os.path.join(source, "main.swift"), "w").write('''
import Foundation

var checks = 0
var failures = 0
func check(_ condition: Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL \\(what) (line \\(line))\\n".utf8))
    }
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("chat-store-\\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
try await checkChatStore(scratch) { condition, what in check(condition, what) }
print("\\(checks - failures)/\\(checks) chat store checks passed")
exit(failures == 0 ? 0 : 1)
''')
PY

swiftc -sdk "$SDKROOT" -target arm64-apple-ios16.0 -swift-version 5 -Onone \
    -o "$work/storecheck" "$work/src"/*.swift
ldid -S"$entitlements" "$work/storecheck"
"$work/storecheck"
