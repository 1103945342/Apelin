import Foundation

/// The stream `IlinkClient.updates()` hands out.
///
/// The stream buffers, so a message the poll loop yields is held until the
/// caller reads it; the cursor of that batch is committed only after every
/// message of it went in.
final class IlinkUpdateHub: @unchecked Sendable {
    let stream: AsyncThrowingStream<IlinkInboundMessage, Error>
    private var continuation: AsyncThrowingStream<IlinkInboundMessage, Error>.Continuation?
    private let lock = NSLock()
    private var finished = false

    init() {
        var captured: AsyncThrowingStream<IlinkInboundMessage, Error>.Continuation?
        self.stream = AsyncThrowingStream { captured = $0 }
        self.continuation = captured
    }

    /// Answers whether the message was taken; false means the stream is over.
    func yield(_ message: IlinkInboundMessage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let continuation else { return false }
        switch continuation.yield(message) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func finish(throwing failure: IlinkFailure? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let failure {
            continuation?.finish(throwing: failure)
        } else {
            continuation?.finish()
        }
    }
}
