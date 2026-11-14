import ApelinWeChat
import XCTest

/// The same checks the device harness runs, wrapped for `swift test`.
final class IlinkChecksTests: XCTestCase {
    func testTrustPolicy() throws {
        try checkIlinkTrustPolicy()
    }

    func testSessionStore() throws {
        try checkIlinkSessionStore()
    }

    func testInboundFilter() throws {
        try checkIlinkInboundFilter()
    }

    func testLoginFlow() async throws {
        try await checkIlinkLoginFlow()
    }

    func testLoginRedirects() async throws {
        try await checkIlinkLoginRedirects()
    }

    func testLoginCodeReplacement() async throws {
        try await checkIlinkLoginCodeReplacement()
    }

    func testPolling() async throws {
        try await checkIlinkPolling()
    }

    func testParseFallback() async throws {
        try await checkIlinkParseFallback()
    }

    func testPollingFailures() async throws {
        try await checkIlinkPollingFailures()
    }

    func testRetSemantics() async throws {
        try await checkIlinkRetSemantics()
    }

    func testCursorNeedsTheWrite() async throws {
        try await checkIlinkCursorNeedsTheWrite()
    }

    func testUnreadableSession() async throws {
        try await checkIlinkUnreadableSession()
    }

    func testSending() async throws {
        try await checkIlinkSending()
    }
}
