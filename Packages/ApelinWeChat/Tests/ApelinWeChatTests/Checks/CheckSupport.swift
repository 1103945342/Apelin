import ApelinWeChat
import Foundation

/// A failed expectation. `<Scripts/test-wechat.sh>` runs these functions as
/// they are; the XCTest target wraps the same ones, so the checks exist once.
struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw CheckFailure(message: message()) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String) throws {
    if actual != expected {
        throw CheckFailure(message: "\(what): expected \(expected), got \(actual)")
    }
}

/// A value two tasks touch: the poll loop, the checks, and the transport.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }
}

/// The transport the checks drive the protocol with: it records every request
/// and answers from the handler the test sets. Nothing reaches the network.
final class FakeTransport: IlinkTransport, @unchecked Sendable {
    typealias Handler = @Sendable (IlinkHTTPRequest) throws -> IlinkHTTPResponse

    private let lock = NSLock()
    private var handler: Handler
    private var recorded: [IlinkHTTPRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func set(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    var requests: [IlinkHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: IlinkHTTPRequest) async throws -> IlinkHTTPResponse {
        let current = record(request)
        return try current(request)
    }

    /// The lock is taken in a synchronous method: NSLock is not available
    /// directly from an asynchronous context under Swift 6.
    private func record(_ request: IlinkHTTPRequest) -> Handler {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        return handler
    }
}

func httpResponse(_ status: Int, _ body: String) -> IlinkHTTPResponse {
    IlinkHTTPResponse(status: status, headers: [:], body: Data(body.utf8))
}

func jsonObject(_ data: Data?) throws -> [String: Any] {
    guard let data, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CheckFailure(message: "body is not a JSON object")
    }
    return object
}

func makeTemporaryFolder(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("apelin-wechat-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeSession(
    botID: String = "bot-1",
    token: String = "token-1",
    cursor: String? = nil,
    tokens: [String: String] = [:]
) -> IlinkSession {
    IlinkSession(
        credentials: IlinkCredentials(
            botID: botID,
            token: token,
            userID: "user-1",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        cursor: cursor,
        contextTokens: tokens,
        baseURL: nil,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

/// Waits for an asynchronous state, such as a cursor the poll loop writes
/// after the event was delivered.
func waitFor(
    _ what: String,
    timeout: TimeInterval = 5,
    _ condition: @escaping () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CheckFailure(message: "timed out waiting for \(what)")
}
