import Foundation

/// The two pieces of the feed path that can run without ghostty or a socket:
/// the input gate the emulator's write callback goes through, and the batch
/// loop's suspension points — where a page that left, or a rebuild that
/// replaced this attachment, must stop the old bytes and the old task's end.
/// Run by `Tests/TerminalUI/run.sh`.
enum TerminalFeedCheck {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("ok   \(message)")
        } else {
            failures += 1
            print("FAIL \(message)")
        }
    }

    /// Collects what the router forwarded, from whichever thread it did.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [Data] = []

        func append(_ data: Data) {
            lock.lock()
            bytes.append(data)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return bytes.count
        }

        var all: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }
    }

    /// The attachment generation a running ingest compares against.
    final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int

        init(_ value: Int) {
            self.value = value
        }

        var token: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    /// A deterministic suspension between two tasks: the feeder says it has
    /// arrived and waits; another task changes the generation, then lets it go.
    /// No sleep, no timing guess.
    final class Handshake: @unchecked Sendable {
        private let lock = NSLock()
        private var arrived: [CheckedContinuation<Void, Never>] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var hasArrived = false
        private var released = false

        /// Suspends until `release()` is called.
        func arrive() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                hasArrived = true
                let pending = arrived
                arrived.removeAll()
                let alreadyReleased = released
                if !alreadyReleased {
                    waiters.append(continuation)
                }
                lock.unlock()
                for waiting in pending {
                    waiting.resume()
                }
                if alreadyReleased {
                    continuation.resume()
                }
            }
        }

        /// Suspends until `arrive()` has been entered.
        func waitUntilArrived() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if hasArrived {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                arrived.append(continuation)
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            released = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for waiting in pending {
                waiting.resume()
            }
        }
    }

    /// A value written from one task and read from another, for the checks
    /// below: the loop suspends on the global executor, the test waits for it.
    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) {
            stored = value
        }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func update(_ body: (inout Value) -> Void) {
            lock.lock()
            body(&stored)
            lock.unlock()
        }
    }

    static func run() -> Int {
        failures = 0

        // The gate: closed with no destination, closed while accepting is off,
        // closed during a replay, open only when both are right.
        let router = TerminalInputRouter()
        let sink = Sink()
        router.send(Data([0x61]))
        check(sink.count == 0, "no destination takes nothing")
        router.attach { data in sink.append(data) }
        router.send(Data([0x61]))
        check(sink.count == 0, "a session that has not said live takes nothing")
        router.setAccepting(true)
        router.send(Data([0x61]))
        check(sink.count == 1, "a live session forwards")
        router.beginReplay()
        router.send(Data([0x62]))
        check(sink.count == 1, "a replayed surface's writeback does not reach the shell")
        check(router.isOpen == false, "the gate says it is closed during a replay")
        router.endReplay()
        router.send(Data([0x63]))
        check(sink.count == 2, "opening the replay gate forwards again")
        check(router.isOpen, "the gate says it is open")
        router.setAccepting(false)
        router.send(Data([0x64]))
        check(sink.count == 2, "a session that is no longer live takes nothing")
        router.attach(nil)
        router.setAccepting(true)
        router.send(Data([0x65]))
        check(sink.count == 2, "with no destination nothing goes out")

        // The window between a failure and the next attempt: the gate closes
        // at the failure, before the page is told and before any backoff sleep.
        let reconnecting = TerminalInputRouter()
        let reconnectingSink = Sink()
        reconnecting.attach { data in reconnectingSink.append(data) }
        reconnecting.setAccepting(true)
        reconnecting.send(Data([0x61]))
        check(reconnectingSink.count == 1, "a live session forwards before the failure")
        reconnecting.send(Data([0x61]))
        check(reconnectingSink.count == 2, "and keeps forwarding while it is live")
        TerminalAttemptGate.reopen(reconnecting)
        reconnecting.send(Data([0x62]))
        check(reconnectingSink.count == 2, "the backoff window takes no keystrokes")
        check(reconnecting.isOpen == false, "the gate is closed before the page says Reconnecting")

        // The surface latch: only the generation that waited may mark it.
        var latch = TerminalSurfaceLatch()
        check(latch.markReady(token: 1, current: 2) == false,
              "a stale generation cannot mark the surface ready")
        check(latch.ready == false, "and leaves the latch unset")
        check(latch.markReady(token: 2, current: 2), "the current generation marks it")
        check(latch.ready, "the latch records it")

        // The batch loop: a generation that changes while a feed suspends stops
        // the next slice, and one that changes on the final breather still stops
        // the old task's end from being acted on.
        let duringFeed = Generation(1)
        let feedRun = Box<(outcome: TerminalAttachment.BatchOutcome?, applied: Int, fed: Int)>((nil, 0, 0))
        let feedDone = DispatchSemaphore(value: 0)
        Task {
            let outcome = try? await TerminalIngestLoop.run(
                slices: 3,
                isCurrent: { duringFeed.token == 1 },
                applySlice: { _ in
                    feedRun.update { $0.applied += 1 }
                    return .completed
                },
                feedSlice: {
                    feedRun.update { $0.fed += 1 }
                    duringFeed.advance()
                },
                breathe: {}
            )
            feedRun.update { $0.outcome = outcome }
            feedDone.signal()
        }
        feedDone.wait()
        check(feedRun.value.outcome == .superseded, "a detach while feeding stops the batch")
        check(feedRun.value.applied == 1, "no slice after the detach is applied")
        check(feedRun.value.fed == 1, "no bytes after the detach are fed")

        let duringBreathe = Generation(1)
        let breatheRun = Box<(outcome: TerminalAttachment.BatchOutcome?, applied: Int)>((nil, 0))
        let breatheDone = DispatchSemaphore(value: 0)
        Task {
            let outcome = try? await TerminalIngestLoop.run(
                slices: 2,
                isCurrent: { duringBreathe.token == 1 },
                applySlice: { _ in
                    breatheRun.update { $0.applied += 1 }
                    return .completed
                },
                feedSlice: {},
                breathe: {
                    if breatheRun.value.applied == 2 {
                        duringBreathe.advance()
                    }
                }
            )
            breatheRun.update { $0.outcome = outcome }
            breatheDone.signal()
        }
        breatheDone.wait()
        check(breatheRun.value.outcome == .superseded,
              "a detach on the last breather stops the batch before its end is acted on")

        let steady = Generation(1)
        let steadyRun = Box<(outcome: TerminalAttachment.BatchOutcome?, applied: Int)>((nil, 0))
        let steadyDone = DispatchSemaphore(value: 0)
        Task {
            let outcome = try? await TerminalIngestLoop.run(
                slices: 3,
                isCurrent: { steady.token == 1 },
                applySlice: { _ in
                    steadyRun.update { $0.applied += 1 }
                    return .completed
                },
                feedSlice: {},
                breathe: {}
            )
            steadyRun.update { $0.outcome = outcome }
            steadyDone.signal()
        }
        steadyDone.wait()
        check(steadyRun.value.outcome == .completed, "an unchanged generation completes the batch")
        check(steadyRun.value.applied == 3, "every slice was applied")

        // A feed that really suspends, with the generation changed by another
        // task while it is suspended: a deterministic handshake, not a sleep.
        let suspending = Generation(1)
        let handshake = Handshake()
        let suspendRun = Box<(outcome: TerminalAttachment.BatchOutcome?, applied: Int, fed: Int)>((nil, 0, 0))
        let suspendedFirst = Box<Bool>(false)
        let suspendDone = DispatchSemaphore(value: 0)
        Task {
            let outcome = try? await TerminalIngestLoop.run(
                slices: 3,
                isCurrent: { suspending.token == 1 },
                applySlice: { _ in
                    suspendRun.update { $0.applied += 1 }
                    return .completed
                },
                feedSlice: {
                    suspendRun.update { $0.fed += 1 }
                    // Suspends here until the other task has switched.
                    await handshake.arrive()
                },
                breathe: {}
            )
            suspendRun.update { $0.outcome = outcome }
            suspendDone.signal()
        }
        Task {
            await handshake.waitUntilArrived()
            // The feeder is suspended here: nothing after its feed has run.
            let state = suspendRun.value
            suspendedFirst.update { $0 = state.applied == 1 && state.fed == 1 }
            suspending.advance()
            handshake.release()
        }
        suspendDone.wait()
        check(suspendedFirst.value, "the feed had suspended before the generation changed")
        check(suspendRun.value.outcome == .superseded,
              "a generation that changes during a real suspension stops the batch")
        check(suspendRun.value.applied == 1, "only the slice that was in flight was applied")
        check(suspendRun.value.fed == 1, "and only its bytes were fed")

        // The same decision on the live path: replay finished, a later batch's
        // numbering advanced, feeding it failed — the recovery is a fresh
        // surface from the resume point, never a backward cursor on this one.
        var live = TerminalAttachment()
        live.begin(openShell: false)
        live.replaying()
        live.replayEnding(at: 64)
        for seq in 1 ... 64 {
            live.applied(seq: UInt64(seq))
        }
        live.caughtUp()
        check(live.phase == .live, "the session is live before the failure")
        live.applied(seq: 65)
        check(live.cursor == 65, "a live batch's numbering advanced before its feed failed")
        check(live.replayRecoveryAllowed(), "a live feed failure asks for a fresh surface")
        check(live.phase == .reconnecting, "and the session is reconnecting, not live")
        live.begin(openShell: false)
        check(live.cursor == live.resumeFrom && live.cursor < 65,
              "the new surface replays from the resume point, not the advanced cursor")
        check(live.hasReachedReplayEnd == false, "the live replay is not over until its new end")

        // The same failure inside catch-up, kept as its own case.
        var advanced = TerminalAttachment()
        advanced.begin(openShell: false)
        advanced.replaying()
        advanced.replayEnding(at: 64)
        for seq in 1 ... 64 {
            advanced.applied(seq: UInt64(seq))
        }
        check(advanced.cursor == 64, "the batch's numbering advanced before the feed failed")
        check(advanced.replayRecoveryAllowed(), "a feed failure asks for a fresh surface")
        check(advanced.phase == .reconnecting, "and the session is reconnecting, not live")
        advanced.begin(openShell: false)
        check(advanced.cursor == advanced.resumeFrom && advanced.cursor < 64,
              "the new surface replays from the resume point, not the advanced cursor")
        check(advanced.hasReachedReplayEnd == false, "the replay is not over until its new end")

        // Byte-bounded feeding: a slice of events is not a byte bound, and one
        // output event can be larger than a chunk.
        check(TerminalFeedPlan.chunks(of: Data()).isEmpty, "nothing to feed has no pieces")
        check(TerminalFeedPlan.chunks(of: Data(count: 16 * 1024)).count == 1,
              "a 16 KiB output is one piece")
        let exact = TerminalFeedPlan.chunks(of: Data(count: TerminalFeedPlan.chunkBytes * 2))
        check(exact.count == 2, "an exact multiple is that many pieces")
        let large = Data(count: 200 * 1024)
        let pieces = TerminalFeedPlan.chunks(of: large)
        check(pieces.count == 5, "a 200 KiB output is cut into five pieces")
        check(pieces.reduce(0) { $0 + $1.count } == large.count,
              "the pieces cover every byte exactly")
        check(pieces.first?.lowerBound == 0 && pieces.last?.upperBound == large.count,
              "the pieces run from the first byte to the last")
        check(zip(pieces, pieces.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound },
              "the pieces are contiguous")
        check(pieces.allSatisfy { $0.count <= TerminalFeedPlan.chunkBytes },
              "no piece exceeds the chunk size")

        print(failures == 0 ? "TerminalFeedCheck: all checks passed" : "TerminalFeedCheck: \(failures) failed")
        return failures
    }
}
