import Foundation
import KWWKAgent
import KWWKAI
import Network

/// Whether the device has a route to the network, which a model request the
/// network failed waits for (`NetworkRecovery`).
public struct NetworkPath: Sendable {
    /// False only while the system says there is no route; true before it
    /// has said anything.
    public var isSatisfied: @Sendable () -> Bool

    public init(isSatisfied: @escaping @Sendable () -> Bool) {
        self.isSatisfied = isSatisfied
    }

    /// The system's answer: `NWPathMonitor`'s latest, from one monitor a
    /// process, started when a session is first configured.
    public static var system: NetworkPath {
        let monitor = PathMonitor.shared
        return NetworkPath { monitor.isSatisfied }
    }
}

/// `NWPathMonitor` kept running, its latest status readable from any task.
private final class PathMonitor: @unchecked Sendable {
    static let shared = PathMonitor()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    @objc private dynamic var unsatisfied = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(unsatisfied: path.status == .unsatisfied)
        }
        monitor.start(queue: DispatchQueue(label: "wiki.qaq.apelin.agent.network-path"))
    }

    /// A path that needs a connection counts: the request may bring it up.
    @objc dynamic var isSatisfied: Bool {
        lock.withLock { !unsatisfied }
    }

    @objc private dynamic func update(unsatisfied: Bool) {
        lock.withLock { self.unsatisfied = unsatisfied }
    }
}

/// Model requests the network failed, answered once it is back.
///
/// kwwk tries a failed request five times within about fifteen seconds
/// (`ProviderRetryPolicy`), and takes a failed TLS handshake for a refused
/// request it never tries again. A phone that changes networks or wakes
/// from sleep is often offline for longer, and the turn ended with "The
/// Internet connection appears to be offline." or "An SSL error has
/// occurred…" for a spell it would have outlived.
///
/// Around the requests a session's agent makes (`AgentOptions.streamFn`),
/// an attempt the network failed before kwwk had anything of the reply:
/// - is handed to kwwk only once `NetworkPath` has a route again, or after
///   `Patience.pathWait`, so kwwk's own retry goes out when it can get
///   through; kwwk still retries it and counts the attempts;
/// - is asked again here when its TLS handshake failed, at most
///   `Patience.secureConnectionRetries` times, after a pause.
///
/// `onWait` hears of each wait first. An attempt that streamed text,
/// thinking or a call is kwwk's alone to take back (`streamRewind`) and ask
/// again, and no tool runs twice: kwwk runs a call only once its message
/// has settled.
enum NetworkRecovery {
    struct Patience: Sendable {
        /// The longest one failure waits for a route, in milliseconds.
        var pathWait: UInt64 = 30000
        /// How often the route is looked at meanwhile.
        var pathPoll: UInt64 = 100
        /// The pause before a failed handshake is asked again.
        var secureConnectionPause: UInt64 = 1000
        var secureConnectionRetries = 2

        static let standard = Patience()
    }

    /// `inner` with the failures above waited on, or asked again.
    static func stream(
        path: NetworkPath,
        patience: Patience = .standard,
        inner: @escaping StreamFn = { model, context, options in
            try await KWWKAI.stream(model: model, context: context, options: options)
        },
        onWait: @escaping @Sendable () async -> Void,
    ) -> StreamFn {
        { model, context, options in
            let cancellation = options?.cancellation
            let first = try await cancellable(cancellation) {
                try await inner(model, context, options)
            }
            let (stream, continuation) = AssistantMessageStream.makeStream()
            let out = Output(continuation)
            Task {
                do {
                    try await cancellable(cancellation) {
                        try await relay(
                            first,
                            to: out,
                            path: path,
                            patience: patience,
                            cancellation: cancellation,
                            onWait: onWait,
                        ) {
                            try await inner(model, context, options)
                        }
                    }
                } catch {
                    let stopped = stopped(AssistantMessage(
                        content: [], api: model.api, provider: model.provider, model: model.id,
                    ))
                    finish(out, .error(reason: .aborted, error: stopped), stopped)
                }
            }
            return stream
        }
    }

    /// Do not use a task group here: leaving its scope waits for every child,
    /// including a provider that ignores cancellation. The one-result stream
    /// releases our waiter independently; the operation is still cancelled,
    /// and a late result is discarded by the finished continuation.
    static func cancellable<Value: Sendable>(
        _ cancellation: CancellationHandle?,
        operation: @escaping @Sendable () async throws -> Value,
    ) async throws -> Value {
        try checkCancellation(cancellation)
        let (results, out) = AsyncThrowingStream<Value, Error>.makeStream()
        let task = Task {
            do {
                try checkCancellation(cancellation)
                out.yield(try await operation())
                out.finish()
            } catch {
                out.finish(throwing: error)
            }
        }
        let registration = cancellation?.onCancel { _ in
            out.finish(throwing: CancellationError())
            task.cancel()
        }
        defer {
            registration?.cancel()
            task.cancel()
        }
        var iterator = results.makeAsyncIterator()
        guard let result = try await iterator.next() else { throw CancellationError() }
        // A buffered result may win the iterator race against cancellation.
        try checkCancellation(cancellation)
        return result
    }

    private static func checkCancellation(_ cancellation: CancellationHandle?) throws {
        try Task.checkCancellation()
        try cancellation?.throwIfCancelled()
    }

    /// A failure kwwk tries again and a missing route explains: a
    /// connection dropped, refused or timed out.
    static func isLostConnection(_ failure: ProviderFailure) -> Bool {
        failure.isRetryable && [.transport, .timeout].contains(failure.category)
    }

    /// `NSURLErrorSecureConnectionFailed`: a TLS handshake that failed, as
    /// one does while the network changes under it. A certificate that will
    /// not do (-1201 to -1206) is another failure, never asked again.
    static func isFailedHandshake(_ failure: ProviderFailure) -> Bool {
        failure.transportDomain == NSURLErrorDomain && failure.transportCode == NSURLErrorSecureConnectionFailed
    }

    /// Hands each attempt's events to `out` as they come, and its end once
    /// judged: as it came, after a wait for the route, or asked again.
    private static func relay(
        _ first: AssistantMessageStream,
        to out: Output,
        path: NetworkPath,
        patience: Patience,
        cancellation: CancellationHandle?,
        onWait: @Sendable () async -> Void,
        ask: @escaping @Sendable () async throws -> AssistantMessageStream,
    ) async throws {
        var attempt = first
        // Whether kwwk has had any of the reply: a start alone carries
        // nothing, and the next attempt's start stands in for it.
        var answered = false
        var retries = 0
        while true {
            try checkCancellation(cancellation)
            var ending: AssistantMessageEvent?
            for await event in attempt {
                // A provider may have queued events before noticing Stop.
                try checkCancellation(cancellation)
                switch event {
                case .done, .error:
                    ending = event
                case .start:
                    out.push(event)
                default:
                    answered = true
                    out.push(event)
                }
            }
            let final = await attempt.result()
            try checkCancellation(cancellation)
            guard !answered, final.stopReason == .error, let failure = final.providerFailure else {
                finish(out, ending, final)
                return
            }
            let asksAgain = isFailedHandshake(failure) && retries < patience.secureConnectionRetries
            guard asksAgain || (isLostConnection(failure) && !path.isSatisfied()) else {
                finish(out, ending, final)
                return
            }
            await onWait()
            try checkCancellation(cancellation)
            try await waitForRoute(path, patience: patience, cancellation: cancellation)
            if asksAgain {
                try await ProviderRetryPolicy.wait(patience.secureConnectionPause, cancellation: cancellation)
            }
            try checkCancellation(cancellation)
            guard asksAgain else {
                finish(out, ending, final)
                return
            }
            do {
                attempt = try await cancellable(cancellation, operation: ask)
            } catch {
                // Preserve the original failure when retry creation fails,
                // but never turn a cancelled retry back into a network error.
                try checkCancellation(cancellation)
                if error is CancellationError { throw error }
                finish(out, ending, final)
                return
            }
            retries += 1
        }
    }

    /// Returns once `path` has a route or `patience.pathWait` has passed;
    /// throws once the request is stopped.
    private static func waitForRoute(
        _ path: NetworkPath,
        patience: Patience,
        cancellation: CancellationHandle?,
    ) async throws {
        var waited: UInt64 = 0
        while !path.isSatisfied(), waited < patience.pathWait {
            try await ProviderRetryPolicy.wait(patience.pathPoll, cancellation: cancellation)
            waited += patience.pathPoll
        }
    }

    /// `push(terminal)` and `end` must be one operation: the relay can
    /// settle at the same time as its cancelled waiter. Stream.end alone
    /// cannot prevent both terminal events being queued before either end.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AssistantMessageStream.Continuation
        @objc private dynamic var ended = false

        init(_ continuation: AssistantMessageStream.Continuation) {
            self.continuation = continuation
        }

        func push(_ event: AssistantMessageEvent) {
            lock.withLock {
                guard !ended else { return }
                continuation.push(event)
            }
        }

        func finish(_ ending: AssistantMessageEvent?, _ final: AssistantMessage) {
            lock.withLock {
                guard !ended else { return }
                ended = true
                if let ending { continuation.push(ending) }
                continuation.end(final)
            }
        }
    }

    private static func finish(
        _ out: Output,
        _ ending: AssistantMessageEvent?,
        _ final: AssistantMessage,
    ) {
        out.finish(ending, final)
    }

    /// What a provider ends a request stopped before its reply with.
    private static func stopped(_ failed: AssistantMessage) -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: failed.api,
            provider: failed.provider,
            model: failed.model,
            stopReason: .aborted,
            errorMessage: "Request was aborted",
        )
    }
}
