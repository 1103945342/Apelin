import Foundation

/// The decisions one terminal attachment makes, with no socket, no view and no
/// clock — so the awkward ones can be tested: which event is next, when a gap
/// means the log no longer holds what this surface needs, where a rebuilt
/// surface starts again, and what an open that finishes into a page that has
/// moved on is worth.
///
/// The rules it encodes:
/// - A batch may repeat what was already applied (a replay overlapping the
///   cursor) and must never apply it twice; events are numbered with no gaps,
///   so a jump means bytes are missing.
/// - A rebuilt surface starts at the sequence number the host said its next
///   event would be, never at the beginning: restarting at zero would be told
///   the same truncation again, for ever.
/// - Rebuilds are bounded; past the bound the session keeps drawing the tail it
///   has and says the history is trimmed, rather than looping.
/// - A shell that opens while the page has gone is kept, not closed; one that
///   opens after the reader ended the terminal is closed.
struct TerminalAttachment: Equatable {
    enum Phase: Equatable {
        /// No surface wants this session.
        case idle
        /// Waiting for the shell to be created.
        case opening
        /// Asking for the task's events, from a fixed point.
        case reconnecting
        /// Replaying the log into a fresh surface.
        case catchingUp
        /// Following the task live.
        case live
        case ended
        case failed
    }

    /// What the next event is, against the last one applied.
    enum Verdict: Equatable {
        case apply
        case duplicate
        case gap
    }

    /// What an open that has just answered is worth.
    enum OpenArrival: Equatable {
        case adopt
        case close
    }

    /// How many rebuilds one attachment may ask for before it settles for the
    /// tail it can get.
    static let rebuildLimit = 3
    /// How many failed attaches in a row become a page the reader has to act on.
    static let retryLimit = 6

    private(set) var phase: Phase = .idle
    /// The last event applied.
    private(set) var cursor: UInt64 = 0
    /// Where the next attach starts: the log's beginning, or the sequence
    /// number a truncation named.
    private(set) var resumeFrom: UInt64 = 0
    /// Whether the reader still wants this shell at all.
    private(set) var wantsShell = true
    /// Whether a page is showing this session now.
    private(set) var wantsSurface = false
    private(set) var retries = 0
    private(set) var rebuilds = 0
    /// Where the replay of this attachment ends: the history's end at the
    /// moment the first batch was taken. A shell keeps writing while it is
    /// read, so "no events waiting" never happens; this fixed number does.
    private(set) var catchUpEnd: UInt64?

    /// A page is taking this session: open the shell when there is none, or
    /// reattach to the one there is.
    mutating func begin(openShell: Bool) {
        wantsSurface = true
        retries = 0
        cursor = resumeFrom
        catchUpEnd = nil
        phase = openShell ? .opening : .reconnecting
    }

    /// The shell's `ptyOpen` answered. A shell nobody wants is closed; one the
    /// page merely stopped watching is adopted and then let go of, never killed.
    mutating func shellOpened() -> OpenArrival {
        guard wantsShell else {
            phase = .ended
            return .close
        }
        phase = .catchingUp
        return .adopt
    }

    /// The first answer's events are being replayed into the surface.
    mutating func replaying() {
        if phase == .opening || phase == .reconnecting {
            phase = .catchingUp
        }
    }

    /// The history's end when this attachment's first batch was taken: the
    /// replay is done when the cursor reaches it, however much the shell keeps
    /// writing after that. A batch without the number leaves this nil, and the
    /// caller drains until the host answers nothing at all.
    mutating func replayEnding(at seq: UInt64?) {
        catchUpEnd = seq
    }

    /// Whether this attachment has replayed everything the history held when it
    /// started. False when the host named no end.
    var hasReachedReplayEnd: Bool {
        guard let catchUpEnd else { return false }
        return cursor >= catchUpEnd
    }

    /// One event as the batch runner needs it: its number, and — for a
    /// truncation — the sequence its tail continues from.
    struct BatchItem: Equatable {
        var seq: UInt64
        var truncation: Bool
        var throughSeq: UInt64?

        init(seq: UInt64, truncation: Bool = false, throughSeq: UInt64? = nil) {
            self.seq = seq
            self.truncation = truncation
            self.throughSeq = throughSeq
        }
    }

    /// What became of one batch walked through `runBatch`.
    enum BatchOutcome: Equatable {
        /// Every event that belonged to this generation was applied.
        case completed
        /// An event asked for a rebuild (a truncation, or a gap): this batch's
        /// remaining events belong to a generation that no longer exists.
        case rebuildRequested
        /// A newer attachment took over mid-batch: nothing further may be
        /// applied, and certainly not to the new generation's cursor.
        case superseded
    }

    /// Applies one batch's items in order, stopping the moment this generation
    /// ends: a truncation or a gap asked for a rebuild, or a newer attachment
    /// took over.
    ///
    /// The truncation, the gap and the cursor are handled here, on the
    /// attachment itself — not in `applyAtIndex`, which must not touch the
    /// attachment at all: a closure that mutated it while it is being modified
    /// here would be an overlapping exclusive access. `applyAtIndex` feeds the
    /// emulator and records what the page draws; nothing else.
    mutating func runBatch(
        items: [BatchItem],
        isCurrent: () -> Bool,
        applyAtIndex: (Int) -> Void
    ) -> BatchOutcome {
        for index in items.indices {
            guard isCurrent() else { return .superseded }
            let item = items[index]
            // A truncation is recognised before the numbering is judged: its
            // seq is the sequence the tail continues from and can be far ahead
            // of this surface's cursor, which is not a gap but the marker the
            // host put in front of the retained events.
            if item.truncation {
                let rebuild = truncated(throughSeq: item.throughSeq ?? item.seq)
                applyAtIndex(index)
                applied(seq: item.seq)
                if rebuild {
                    return .rebuildRequested
                }
                continue
            }
            switch judge(seq: item.seq) {
            case .duplicate:
                continue
            case .gap:
                // The log no longer holds what comes next. Rebuild once from
                // its beginning — where a truncation marker is waiting — and
                // otherwise keep the tail that arrives.
                if gapSeen() {
                    return .rebuildRequested
                }
            case .apply:
                break
            }
            applyAtIndex(index)
            applied(seq: item.seq)
            if phase == .ended || phase == .failed {
                return .completed
            }
        }
        return .completed
    }

    func judge(seq: UInt64) -> Verdict {
        if seq <= cursor {
            return .duplicate
        }
        if seq != cursor &+ 1 {
            return .gap
        }
        return .apply
    }

    mutating func applied(seq: UInt64) {
        if seq > cursor {
            cursor = seq
        }
    }

    /// How many times a replay that the surface could not take may be retried
    /// with a fresh surface before the page is told.
    static let replayRecoveryLimit = 3

    private(set) var replayRecoveries = 0

    /// A replay the surface did not take (unparsed output with no surface, a
    /// parser that stayed behind): true to build a fresh surface and try
    /// again, false once that has been tried too often — the page then says so
    /// and keeps the keys closed.
    mutating func replayRecoveryAllowed() -> Bool {
        guard replayRecoveries < Self.replayRecoveryLimit else {
            phase = .failed
            return false
        }
        replayRecoveries += 1
        phase = .reconnecting
        return true
    }

    /// The session cannot go on: the page shows a failure and offers a retry.
    mutating func giveUp() {
        phase = .failed
    }
    /// The replay has reached its end: the page may take keys.
    mutating func caughtUp() {
        phase = .live
        catchUpEnd = nil
        rebuilds = 0
        replayRecoveries = 0
    }

    /// The host dropped older output. Whether a rebuild is worth doing: the
    /// tail continues from the marker's own sequence, and only a marker at or
    /// ahead of this surface's cursor says something this surface is missing.
    /// One behind the cursor is old news — the bytes after it are already on
    /// screen — and rebuilding for it would throw a good screen away.
    @discardableResult
    mutating func truncated(throughSeq: UInt64) -> Bool {
        guard rebuilds < Self.rebuildLimit else { return false }
        guard throughSeq >= cursor else { return false }
        let next = max(throughSeq, cursor)
        guard rebuilds == 0 || next > resumeFrom else { return false }
        resumeFrom = next
        cursor = next
        rebuilds += 1
        phase = .reconnecting
        return true
    }

    /// The batch skipped numbers: bytes the log no longer has. Rebuild once
    /// from the log's own beginning — which is where a truncation marker, if
    /// there is one, will be waiting — and never loop.
    @discardableResult
    mutating func gapSeen() -> Bool {
        guard rebuilds < Self.rebuildLimit, rebuilds == 0 else { return false }
        resumeFrom = 0
        cursor = 0
        rebuilds += 1
        phase = .reconnecting
        return true
    }

    /// An attach or a poll failed in a way that may pass. True to try again,
    /// false once the page must say so and offer the reader a choice.
    mutating func transientFailure() -> Bool {
        retries += 1
        if retries > Self.retryLimit {
            phase = .failed
            return false
        }
        phase = .reconnecting
        return true
    }

    mutating func recovered() {
        retries = 0
    }

    /// The host no longer has this task: not something to resume, and not
    /// something to replace behind the reader's back.
    mutating func hostLost() {
        phase = .ended
        wantsShell = false
        wantsSurface = false
    }

    /// The shell exited or was closed.
    mutating func ended() {
        phase = .ended
        wantsShell = false
        wantsSurface = false
    }

    /// The page went away. The shell is left running and the next attach asks
    /// for the log again.
    mutating func detach() {
        wantsSurface = false
        retries = 0
        if phase != .ended, phase != .failed, phase != .opening {
            phase = .idle
        }
    }

    /// The reader ended the terminal.
    mutating func terminate() {
        wantsShell = false
        wantsSurface = false
        phase = .ended
    }

    /// A new shell replaces this attachment's bookkeeping: a fresh history,
    /// nothing trimmed yet.
    mutating func restart() {
        cursor = 0
        resumeFrom = 0
        rebuilds = 0
        retries = 0
        replayRecoveries = 0
        catchUpEnd = nil
        phase = .opening
    }
}

/// The suspension points of one batch: apply a slice of events, feed its bytes,
/// let the parser breathe — and stop the moment this attachment's generation
/// changes.
///
/// The loop lives here, apart from the session, so a test can flip the
/// generation during a feed and see that no later slice is applied and no old
/// task end acted on, without ghostty or a socket. `TerminalSession.ingest` is
/// this function with the session's closures.
enum TerminalIngestLoop {
    static func run(
        slices: Int,
        isCurrent: () -> Bool,
        applySlice: (Int) async throws -> TerminalAttachment.BatchOutcome,
        feedSlice: () async throws -> Void,
        breathe: () async throws -> Void
    ) async throws -> TerminalAttachment.BatchOutcome {
        for slice in 0 ..< slices {
            guard isCurrent() else { return .superseded }
            let outcome = try await applySlice(slice)
            guard isCurrent() else { return .superseded }
            if outcome != .completed {
                return outcome
            }
            try await feedSlice()
            guard isCurrent() else { return .superseded }
            try await breathe()
            guard isCurrent() else { return .superseded }
        }
        return .completed
    }
}
