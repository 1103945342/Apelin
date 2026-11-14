#!/bin/bash
# The channel's rules, run where they are written: this device.
#
# `make check` and `swift test` need Xcode, which the device does not have.
# `ChannelRules` is deliberately free of everything but Foundation, so this
# compiles it with a small driver, signs the result with ldid and runs it —
# the same rules the session host and apelin-channel apply at run time.
#
# Usage: Scripts/test-channel.sh
# Exit:  0 all checks passed, 1 a check failed or the build did, 65 usage.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
# roothide: the bootstrap's compiler reads a path as the bootstrap spells it,
# and an absolute one it is given already looks rooted, so the sources are
# named relative to this directory and the scratch folder sits inside the
# project (build/ is ignored).
source_file="Packages/ApelinKit/Sources/ApelinProtocol/ChannelRules.swift"
[[ -f "$source_file" ]] || { echo "error: $source_file is missing" >&2; exit 65; }

mkdir -p build
scratch="$(mktemp -d "$root/build/channel-test.XXXXXX")"
relative_scratch="build/$(basename "$scratch")"
trap 'rm -rf "${scratch:?}"' EXIT

cat > "$scratch/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition {
        print("ok: \(name)")
    } else {
        failures += 1
        print("FAIL: \(name)")
    }
}

// Trimming, order, duplicates.
check(
    "allowlist normalizes",
    ChannelRules.normalizeAllowlist(["  a ", "", "b", "a", "   "]) == ["a", "b"]
)

// An empty list admits nobody.
check("empty allowlist fails", ChannelRules.allowlistProblem([]) == .emptyAllowlist)
check("blank entries fail", ChannelRules.allowlistProblem([" ", ""]) == .emptyAllowlist)
check("one entry is fine", ChannelRules.allowlistProblem(["a"]) == nil)

// Limits.
let many = (0...ChannelRules.maximumAllowlistEntries).map { "a\($0)" }
check("too many entries", ChannelRules.allowlistProblem(many) == .tooManyEntries)
let long = String(repeating: "a", count: ChannelRules.maximumAllowlistEntryBytes + 1)
check("entry too long", ChannelRules.allowlistProblem(["a", long]) == .entryTooLong)

// Exact, case-sensitive membership.
check("admits trimmed peer", ChannelRules.admits(peer: "a", allowlist: [" a "]))
check("rejects other case", !ChannelRules.admits(peer: "A", allowlist: ["a"]))
check("rejects when empty", !ChannelRules.admits(peer: "a", allowlist: []))
check("rejects empty peer", !ChannelRules.admits(peer: "", allowlist: ["a"]))

// Message problems.
let allow = ["a"]
check("empty message", ChannelRules.messageProblem("   ", allowlist: allow, peer: "a") == .messageEmpty)
check("empty list", ChannelRules.messageProblem("hi", allowlist: [], peer: "a") == .emptyAllowlist)
check("stranger", ChannelRules.messageProblem("hi", allowlist: allow, peer: "b") == .peerNotAllowed)
let huge = String(repeating: "a", count: ChannelRules.maximumMessageBytes + 1)
check("message too long", ChannelRules.messageProblem(huge, allowlist: allow, peer: "a") == .messageTooLong)
check("plain message passes", ChannelRules.messageProblem("hi", allowlist: allow, peer: "a") == nil)

// A channel never opens looser than the app.
check(
    "app Strict wins",
    ChannelRules.effectiveMode(configured: .relaxed, app: .confirm) == .confirm
)
check(
    "app Relaxed keeps the channel's",
    ChannelRules.effectiveMode(configured: .relaxed, app: .relaxed) == .relaxed
)
check(
    "configured Strict stays Strict",
    ChannelRules.effectiveMode(configured: .confirm, app: .relaxed) == .confirm
)
check(
    "no app mode",
    ChannelRules.effectiveMode(configured: .confirm, app: nil) == .confirm
)
check("Full is not a channel mode", ChannelApprovalMode.allCases == [.confirm, .relaxed])

// Budgets clamp both ways.
check("read budget low", ChannelRules.readBudget(0) == 1024)
check("read budget high", ChannelRules.readBudget(1 << 20) == ChannelRules.maximumReadBytes)
check("message budget", ChannelRules.messageBudget(1 << 20) == ChannelRules.maximumMessageBytes)

// A channel ID is a folder name, never a path.
check("uuid id", ChannelRules.isValidChannelID("2f1c6f0f-0f3b-4b8a-9c2d-0f3b4b8a9c2d"))
check("underscore id", ChannelRules.isValidChannelID("wechat_1"))
check("empty id", !ChannelRules.isValidChannelID(""))
check("dot-dot id", !ChannelRules.isValidChannelID("../config"))
check("slash id", !ChannelRules.isValidChannelID("a/b"))
check("non-ascii id", !ChannelRules.isValidChannelID("微信"))
check("long id", !ChannelRules.isValidChannelID(String(repeating: "a", count: 65)))

// One inbound message is taken once; the ledger is bounded.
var inbox = ChannelInbox()
check("first accepted", inbox.accept("m1", at: Date(timeIntervalSince1970: 1)))
check("second refused", !inbox.accept("m1", at: Date(timeIntervalSince1970: 2)))
check("blank refused", !inbox.accept("  ", at: Date(timeIntervalSince1970: 3)))
for index in 0...(ChannelRules.inboxLimit + 10) {
    _ = inbox.accept("m\(index)", at: Date(timeIntervalSince1970: TimeInterval(index + 10)))
}
check("ledger bounded", inbox.seen.count == ChannelRules.inboxLimit)
check("newest kept", inbox.contains("m\(ChannelRules.inboxLimit + 10)"))

// A channel starts without a token: signing in is how one comes.
check("starts with an allowlist", ChannelRules.startProblem(allowlist: ["a"], mode: .relaxed) == nil)
check("starts in Strict too", ChannelRules.startProblem(allowlist: ["a"], mode: .confirm) == nil)
check("still needs somebody", ChannelRules.startProblem(allowlist: [], mode: .relaxed) == .emptyAllowlist)

// Signing out clears the sign-in and keeps the chat and its settings.
let logout = ChannelRules.logoutOutcome
check("logout keeps the conversation", logout.keepsConversation)
check("logout keeps the allowlist", logout.keepsAllowlist)
check("logout keeps the project", logout.keepsProject)
check("logout is signed out", !logout.signedIn)
check("logout removes the login state", logout.removesLoginState)

// The scan is the way in; the number is a fallback, and a block needs a new code.
check("three codes", ChannelRules.maximumLoginCodes == 3)
check("wait", ChannelRules.loginStep("wait") == .wait)
check("scanned", ChannelRules.loginStep("scaned") == .scanned)
check("confirmed", ChannelRules.loginStep("confirmed") == .confirmed)
check("needs the number", ChannelRules.loginStep("need_verifycode") == .needsCode)
check("blocked", ChannelRules.loginStep("verify_code_blocked") == .blocked)
check("expired issues a new code", ChannelRules.loginStep("expired") == .newCode)
check("unknown status waits", ChannelRules.loginStep("something-new") == .wait)

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("all checks passed")
SWIFT

target="${APELIN_CHANNEL_TEST_TARGET:-arm64-apple-ios16.0}"
echo "building ChannelRules for $target"
swiftc -Onone -g -target "$target" -o "$relative_scratch/test-channel" \
    "$source_file" "$relative_scratch/main.swift"

# An unsigned Mach-O is killed as it starts; ldid signs ad hoc in place.
if command -v ldid >/dev/null 2>&1; then
    ldid -S "$relative_scratch/test-channel"
else
    echo "error: ldid is not on PATH; the test binary cannot be signed" >&2
    exit 65
fi

"$root/$relative_scratch/test-channel"
