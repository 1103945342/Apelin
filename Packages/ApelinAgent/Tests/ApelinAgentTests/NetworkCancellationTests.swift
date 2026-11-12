@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Stopping a provider that does not finish")
struct NetworkCancellationTests {
    private static let model = Model(id: "test-1", api: "test", provider: "test")

    private static func message(_ text: String = "", stopReason: StopReason = .stop) -> AssistantMessage {
        AssistantMessage(
            content: text.isEmpty ? [] : [.text(TextContent(text: text))],
            api: model.api, provider: model.provider, model: model.id, stopReason: stopReason,
        )
    }

    /// Poll only the test's completion flag. On failure, the test releases
    /// the provider itself, so an old implementation fails rather than hangs.
    private static func soon(_ predicate: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private final class Box<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? { lock.withLock { stored } }
        func set(_ value: Value) { lock.withLock { stored = value } }
    }

    /// Unlike Task.sleep or AsyncStream, this suspension deliberately ignores
    /// cancellation, just as a provider's stuck setup might.
    private actor Creation {
        private var waiter: CheckedContinuation<AssistantMessageStream, Never>?
        private var released: AssistantMessageStream?
        let entered = Box<Bool>()

        func wait() async -> AssistantMessageStream {
            await withCheckedContinuation { continuation in
                if let released {
                    continuation.resume(returning: released)
                } else {
                    waiter = continuation
                }
                entered.set(true)
            }
        }

        func release(_ stream: AssistantMessageStream) {
            released = stream
            waiter?.resume(returning: stream)
            waiter = nil
        }
    }

    private static func wrapped(_ inner: @escaping StreamFn) -> StreamFn {
        NetworkRecovery.stream(path: NetworkPath { true }, inner: inner, onWait: {})
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `stopping during stream creation does not wait for the provider`(cancelTask: Bool) async throws {
        let creation = Creation()
        let cancellation = CancellationHandle()
        let result = Box<Bool>()
        let stream = Self.wrapped { _, _, _ in await creation.wait() }
        let task = Task {
            do {
                _ = try await stream(Self.model, Context(), StreamOptions(cancellation: cancellation))
                result.set(false)
            } catch {
                result.set(error is CancellationError)
            }
        }
        let entered = creation.entered
        let started = await Self.soon { entered.value == true }
        if cancelTask { task.cancel() } else { cancellation.cancel() }
        let stopped = await Self.soon { result.value != nil }
        let (late, out) = AssistantMessageStream.makeStream()
        out.end(Self.message("Late"))
        await creation.release(late)
        await task.value
        #expect(started)
        #expect(stopped, "Stop must not wait for creation to return")
        #expect(result.value == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func `an already stopped request never calls the provider`() async throws {
        let cancellation = CancellationHandle()
        cancellation.cancel()
        let called = Box<Bool>()
        let stream = Self.wrapped { _, _, _ in
            called.set(true)
            return AssistantMessageStream.makeStream().stream
        }
        do {
            _ = try await stream(Self.model, Context(), StreamOptions(cancellation: cancellation))
            Issue.record("An already cancelled creation succeeded")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(called.value == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a creation failure still throws instead of becoming an aborted reply`() async throws {
        let stream = Self.wrapped { _, _, _ in throw ProviderNotFoundError.api("missing") }
        do {
            _ = try await stream(Self.model, Context(), nil)
            Issue.record("The creation failure was lost")
        } catch {
            #expect(error as? ProviderNotFoundError == .api("missing"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a stream that never ends is aborted and late text is not forwarded`() async throws {
        let (provider, out) = AssistantMessageStream.makeStream()
        defer { out.end(Self.message("Cleanup")) }
        out.push(.start(partial: Self.message()))
        out.push(.textDelta(contentIndex: 0, delta: "Partial", partial: Self.message("Partial")))
        let cancellation = CancellationHandle()
        let stream = Self.wrapped { _, _, _ in provider }
        let response = try await stream(Self.model, Context(), StreamOptions(cancellation: cancellation))
        var iterator = response.makeAsyncIterator()
        #expect(await iterator.next()?.type == "start")
        #expect(await iterator.next()?.type == "text_delta")
        let settled = Box<AssistantMessage>()
        let waiter = Task { settled.set(await response.result()) }
        cancellation.cancel()
        let stopped = await Self.soon { settled.value != nil }
        let late = Self.message("Late reply")
        out.push(.textDelta(contentIndex: 0, delta: "Late reply", partial: late))
        out.push(.done(reason: .stop, message: late))
        out.end(late)
        await waiter.value
        var remaining: [String] = []
        while let event = await iterator.next() { remaining.append(event.type) }
        #expect(stopped, "The final result must settle while the provider is still open")
        #expect(settled.value?.stopReason == .aborted)
        #expect(settled.value?.model == Self.model.id)
        #expect(settled.value?.content == [.text(TextContent(text: "Partial"))])
        #expect(remaining == ["error"], "No late text, done, or duplicate terminal event")
    }

    @Test(.timeLimit(.minutes(1)))
    func `completion racing Stop has one terminal event matching its result`() async throws {
        for _ in 0 ..< 200 {
            let (provider, out) = AssistantMessageStream.makeStream()
            let cancellation = CancellationHandle()
            let stream = Self.wrapped { _, _, _ in provider }
            let response = try await stream(Self.model, Context(), StreamOptions(cancellation: cancellation))
            let reply = Self.message("Reply")
            let completion = Task {
                out.push(.done(reason: .stop, message: reply))
                out.end(reply)
            }
            let stop = Task { cancellation.cancel() }
            var endings: [StopReason] = []
            for await event in response {
                switch event {
                case let .done(reason, _), let .error(reason, _): endings.append(reason)
                default: break
                }
            }
            let final = await response.result()
            await completion.value
            await stop.value
            #expect(endings.count == 1)
            #expect(endings.first == final.stopReason)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `stopping during TLS retry creation ends the outer stream`() async throws {
        let creation = Creation()
        let calls = NetworkRecoveryTests.Counter()
        let cancellation = CancellationHandle()
        var failure = Self.message(stopReason: .error)
        failure.failure = ProviderFailure(
            message: "TLS handshake", transportDomain: NSURLErrorDomain,
            transportCode: NSURLErrorSecureConnectionFailed,
        )
        let (first, out) = AssistantMessageStream.makeStream()
        out.push(.error(reason: .error, error: failure))
        out.end(failure)
        let stream = NetworkRecovery.stream(
            path: NetworkPath { true },
            patience: .init(secureConnectionPause: 1),
            inner: { _, _, _ in
                calls.add()
                if calls.count == 1 { return first }
                return await creation.wait()
            },
            onWait: {},
        )
        let response = try await stream(Self.model, Context(), StreamOptions(cancellation: cancellation))
        let entered = creation.entered
        let started = await Self.soon { entered.value == true }
        let settled = Box<AssistantMessage>()
        let waiter = Task { settled.set(await response.result()) }
        cancellation.cancel()
        let stopped = await Self.soon { settled.value != nil }
        let (late, lateOut) = AssistantMessageStream.makeStream()
        lateOut.end(Self.message("Late retry"))
        await creation.release(late)
        await waiter.value
        #expect(started)
        #expect(stopped)
        #expect(settled.value?.stopReason == .aborted)
        #expect(calls.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func `stopping releases the journal relay even while its provider stays open`() async throws {
        var journal: SessionJournal? = SessionJournal(
            sessionID: "cancel-test", file: nil, redaction: JournalRedaction(home: nil, installRoot: nil),
        )
        weak var retainedJournal = journal
        let (provider, out) = AssistantMessageStream.makeStream()
        defer { out.end(Self.message("Cleanup")) }
        out.push(.start(partial: Self.message()))
        let cancellation = CancellationHandle()
        let stream = try #require(journal).observingRequests { _, _, _ in provider }
        let response = try await stream(Self.model, Context(), StreamOptions(cancellation: cancellation))
        var iterator = response.makeAsyncIterator()
        #expect(await iterator.next()?.type == "start")
        journal = nil
        let settled = Box<AssistantMessage>()
        let waiter = Task { settled.set(await response.result()) }
        cancellation.cancel()
        let stopped = await Self.soon { settled.value != nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while retainedJournal != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let released = retainedJournal == nil
        out.end(Self.message("Late"))
        await waiter.value
        #expect(stopped)
        #expect(released, "The journal task must exit without waiting for its provider")
        #expect(settled.value?.stopReason == .aborted)
    }

    /// One hanging request, then ordinary replies. It deliberately never
    /// reads the cancellation handle; the wrapper must protect the session.
    private struct HangingProvider: APIProvider {
        let api = "apelin-cancel-test-\(UUID().uuidString)"
        let first = AssistantMessageStream.makeStream()
        let calls = NetworkRecoveryTests.Counter()

        func stream(model: Model, context _: Context, options _: StreamOptions?) -> AssistantMessageStream {
            calls.add()
            if calls.count == 1 {
                first.continuation.push(.start(partial: Self.message(model, "")))
                return first.stream
            }
            let (stream, out) = AssistantMessageStream.makeStream()
            let reply = Self.message(model, "Next turn")
            out.push(.start(partial: reply))
            out.push(.done(reason: .stop, message: reply))
            out.end(reply)
            return stream
        }

        static func message(_ model: Model, _ text: String) -> AssistantMessage {
            AssistantMessage(content: [.text(TextContent(text: text))], api: model.api, provider: model.provider, model: model.id)
        }

        func release(_ model: Model) {
            let late = Self.message(model, "Late reply")
            first.continuation.push(.textDelta(contentIndex: 0, delta: "Late reply", partial: late))
            first.continuation.push(.done(reason: .stop, message: late))
            first.continuation.end(late)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `a session stops or closes without a provider reply`(close: Bool) async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = HangingProvider()
        let model = Model(id: "test-1", api: provider.api, provider: "test")
        defer { provider.release(model) }
        await APIRegistry.shared.register(provider)
        defer { Task { await APIRegistry.shared.unregister(api: provider.api) } }
        let configuration = AgentSessionConfiguration(
            project: home.project, provider: .registered(model),
            approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot,
            network: NetworkPath { true },
        )
        let session = try await AgentSession(
            configuration: configuration,
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Wait for a reply")
        let started = await Self.soon { provider.calls.count == 1 }
        let ended = Box<Bool>()
        let stop = Task {
            if close {
                await session.close()
            } else {
                await session.abort()
                await session.waitForIdle()
            }
            ended.set(true)
        }
        let stopped = await Self.soon { ended.value == true }
        if !stopped { provider.release(model) } // bounded cleanup for the old implementation
        await stop.value
        #expect(started)
        #expect(stopped, "Neither close nor waitForIdle may await the provider's reply")
        let next: AgentSession
        if close {
            next = try await AgentSession(
                configuration: configuration,
                backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
            )
        } else {
            next = session
        }
        // Keep the old provider open across the next turn, including reopen
        // with the same ID after close. Do not confuse acceptance with idle.
        try await next.manageQueue(.init(sessionID: next.id, action: .resume))
        try await next.prompt("Try again")
        let nextStarted = await Self.soon { provider.calls.count >= 2 }
        #expect(nextStarted, "prompt returns before its queued acceptance establishes runTask")
        await next.waitForIdle()
        provider.release(model)
        let events = try await next.log.records(afterSeq: 0).map(\.event)
        #expect(events.contains(.finished(reason: .aborted)))
        #expect(!events.contains(.messageFinished(text: "Late reply")))
        #expect(!events.contains(.textDelta("Late reply")))
        #expect(events.contains(.messageFinished(text: "Next turn")))
        #expect(events.last == .finished(reason: .completed))
        await next.close()
    }

    /// The auxiliary model's lookup can suspend before complete() even
    /// creates a stream. Neither task nor handle cancellation resumes this.
    private actor HangingCredentials: CredentialSource {
        let entered = Box<Bool>()
        private var waiter: CheckedContinuation<OAuthCredentials?, Never>?
        private var released = false

        func providerIds() -> [String] { [] }
        func store(_ credentials: OAuthCredentials, for providerID: String) {}
        func remove(_ providerID: String) {}

        func credentials(for providerId: String) async -> OAuthCredentials? {
            if released { return nil }
            return await withCheckedContinuation { continuation in
                waiter = continuation
                entered.set(true)
            }
        }

        func release() {
            released = true
            waiter?.resume(returning: nil)
            waiter = nil
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `a title stuck resolving credentials cannot hold stop or close`(close: Bool) async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let credentials = HangingCredentials()
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(Self.model),
                approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot,
                modelDefaults: .init(title: .init(provider: .anthropic, model: "test-title")),
                network: NetworkPath { true },
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: credentials,
        )
        await session.generateTitle(for: "A title for this conversation")
        let entered = credentials.entered
        let started = await Self.soon { entered.value == true }
        let ended = Box<Bool>()
        let stop = Task {
            if close {
                await session.close()
            } else {
                await session.abort()
                await session.waitForTitle()
            }
            ended.set(true)
        }
        let stopped = await Self.soon { ended.value == true }
        // Release only after observing whether Stop/close returned. On the
        // old implementation this cleanup also unblocks its failed test.
        await credentials.release()
        await stop.value
        #expect(started)
        #expect(stopped, "Title resolution must not hold the session open")
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(!events.contains { if case .titleUpdated = $0 { true } else { false } })
        if !close { await session.close() }
    }

    @Test(.timeLimit(.minutes(1)))
    func `closing cancels an open title stream without saving its late reply`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = HangingProvider()
        let model = Model(id: "title-test", api: provider.api, provider: "test")
        defer { provider.release(model) }
        await APIRegistry.shared.register(provider)
        defer { Task { await APIRegistry.shared.unregister(api: provider.api) } }
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(model),
                approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot,
                network: NetworkPath { true },
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        await session.generateTitle(for: "A title for this conversation")
        let started = await Self.soon { provider.calls.count == 1 }
        let ended = Box<Bool>()
        let close = Task { await session.close(); ended.set(true) }
        let stopped = await Self.soon { ended.value == true }
        provider.release(model)
        await close.value
        #expect(started)
        #expect(stopped)
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(!events.contains { if case .titleUpdated = $0 { true } else { false } })
    }
}
