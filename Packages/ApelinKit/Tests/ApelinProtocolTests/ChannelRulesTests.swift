import ApelinProtocol
import XCTest

/// The channel's rules, as the host and the worker both apply them: an empty
/// allowlist admits nobody, a message has a ceiling, a channel never opens a
/// conversation in a mode looser than the app's, and one inbound ID is taken
/// once.
final class ChannelRulesTests: XCTestCase {
    func testAllowlistNormalizationKeepsOrderAndDropsBlanks() {
        let list = ChannelRules.normalizeAllowlist(["  wxid_a ", "", "wxid_b", "wxid_a", "   "])
        XCTAssertEqual(list, ["wxid_a", "wxid_b"])
    }

    func testEmptyAllowlistIsTheFailureThatMatters() {
        XCTAssertEqual(ChannelRules.allowlistProblem([]), .emptyAllowlist)
        XCTAssertEqual(ChannelRules.allowlistProblem(["  ", ""]), .emptyAllowlist)
        XCTAssertNil(ChannelRules.allowlistProblem(["wxid_a"]))
    }

    func testAllowlistLimits() {
        let many = (0...ChannelRules.maximumAllowlistEntries).map { "wxid_\($0)" }
        XCTAssertEqual(ChannelRules.allowlistProblem(many), .tooManyEntries)
        let long = String(repeating: "a", count: ChannelRules.maximumAllowlistEntryBytes + 1)
        XCTAssertEqual(ChannelRules.allowlistProblem(["wxid_a", long]), .entryTooLong)
    }

    func testAdmitsIsExactAndCaseSensitive() {
        XCTAssertTrue(ChannelRules.admits(peer: "wxid_a", allowlist: [" wxid_a "]))
        XCTAssertFalse(ChannelRules.admits(peer: "WXID_A", allowlist: ["wxid_a"]))
        XCTAssertFalse(ChannelRules.admits(peer: "wxid_a", allowlist: []))
        XCTAssertFalse(ChannelRules.admits(peer: "", allowlist: ["wxid_a"]))
    }

    func testMessageProblems() {
        let allowlist = ["wxid_a"]
        XCTAssertEqual(ChannelRules.messageProblem("  ", allowlist: allowlist, peer: "wxid_a"), .messageEmpty)
        XCTAssertEqual(ChannelRules.messageProblem("hi", allowlist: [], peer: "wxid_a"), .emptyAllowlist)
        XCTAssertEqual(ChannelRules.messageProblem("hi", allowlist: allowlist, peer: "wxid_b"), .peerNotAllowed)
        let long = String(repeating: "a", count: ChannelRules.maximumMessageBytes + 1)
        XCTAssertEqual(ChannelRules.messageProblem(long, allowlist: allowlist, peer: "wxid_a"), .messageTooLong)
        XCTAssertNil(ChannelRules.messageProblem("hi", allowlist: allowlist, peer: "wxid_a"))
    }

    func testAChannelNeverOpensLooserThanTheApp() {
        XCTAssertEqual(
            ChannelRules.effectiveMode(configured: .relaxed, app: .confirm),
            .confirm
        )
        XCTAssertEqual(
            ChannelRules.effectiveMode(configured: .relaxed, app: .relaxed),
            .relaxed
        )
        XCTAssertEqual(
            ChannelRules.effectiveMode(configured: .confirm, app: .relaxed),
            .confirm
        )
        XCTAssertEqual(
            ChannelRules.effectiveMode(configured: .confirm, app: nil),
            .confirm
        )
        // A channel cannot be configured with Full at all, so nothing here
        // can turn Full into anything else.
        XCTAssertEqual(ChannelApprovalMode.allCases, [.confirm, .relaxed])
    }

    func testBudgetsAreClampedBothWays() {
        XCTAssertEqual(ChannelRules.readBudget(0), 1024)
        XCTAssertEqual(ChannelRules.readBudget(1 << 20), ChannelRules.maximumReadBytes)
        XCTAssertEqual(ChannelRules.readBudget(4096), 4096)
        XCTAssertEqual(ChannelRules.messageBudget(0), 1024)
        XCTAssertEqual(ChannelRules.messageBudget(1 << 20), ChannelRules.maximumMessageBytes)
    }

    func testChannelIDsAreFolderNamesNeverPaths() {
        XCTAssertTrue(ChannelRules.isValidChannelID("2f1c6f0f-0f3b-4b8a-9c2d-0f3b4b8a9c2d"))
        XCTAssertTrue(ChannelRules.isValidChannelID("wechat_1"))
        XCTAssertFalse(ChannelRules.isValidChannelID(""))
        XCTAssertFalse(ChannelRules.isValidChannelID("../config"))
        XCTAssertFalse(ChannelRules.isValidChannelID("a/b"))
        XCTAssertFalse(ChannelRules.isValidChannelID("微信"))
        XCTAssertFalse(ChannelRules.isValidChannelID(String(repeating: "a", count: 65)))
    }

    func testInboxTakesEachMessageOnceAndPrunes() {
        var inbox = ChannelInbox()
        XCTAssertTrue(inbox.accept("m1", at: Date(timeIntervalSince1970: 1)))
        XCTAssertFalse(inbox.accept("m1", at: Date(timeIntervalSince1970: 2)))
        XCTAssertFalse(inbox.accept("  ", at: Date(timeIntervalSince1970: 3)))
        for index in 0...(ChannelRules.inboxLimit + 10) {
            _ = inbox.accept("m\(index)", at: Date(timeIntervalSince1970: TimeInterval(index + 10)))
        }
        XCTAssertEqual(inbox.seen.count, ChannelRules.inboxLimit)
        XCTAssertTrue(inbox.contains("m\(ChannelRules.inboxLimit + 10)"))
    }

    /// Signing in is a scan; there is no token to configure, so starting a
    /// channel can never wait for one.
    func testStartingNeverNeedsAToken() {
        XCTAssertNil(ChannelRules.startProblem(allowlist: ["wxid_a"], mode: .relaxed))
        XCTAssertNil(ChannelRules.startProblem(allowlist: ["wxid_a"], mode: .confirm))
        XCTAssertEqual(ChannelRules.startProblem(allowlist: [], mode: .relaxed), .emptyAllowlist)
    }

    /// Signing out clears the sign-in and keeps the chat and its settings.
    func testLogoutKeepsTheConversation() {
        let outcome = ChannelRules.logoutOutcome
        XCTAssertTrue(outcome.keepsConversation)
        XCTAssertTrue(outcome.keepsAllowlist)
        XCTAssertTrue(outcome.keepsProject)
        XCTAssertFalse(outcome.signedIn)
        XCTAssertTrue(outcome.removesLoginState)
    }

    /// The number WeChat shows is a fallback, never the way in.
    func testSignInIsAScan() {
        XCTAssertEqual(ChannelRules.maximumLoginCodes, 3)
        XCTAssertEqual(ChannelRules.loginStep("wait"), .wait)
        XCTAssertEqual(ChannelRules.loginStep("scaned"), .scanned)
        XCTAssertEqual(ChannelRules.loginStep("confirmed"), .confirmed)
        XCTAssertEqual(ChannelRules.loginStep("need_verifycode"), .needsCode)
        XCTAssertEqual(ChannelRules.loginStep("verify_code_blocked"), .blocked)
        XCTAssertEqual(ChannelRules.loginStep("expired"), .newCode)
        XCTAssertEqual(ChannelRules.loginStep("something-new"), .wait)
    }
}
