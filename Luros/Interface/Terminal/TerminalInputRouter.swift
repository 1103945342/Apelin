import Foundation

/// What the emulator's write callback reaches: where this moment's bytes go,
/// and whether they may go at all.
///
/// Ghostty writes two different things through the same callback — the user's
/// keystrokes, and the replies the terminal engine itself emits while parsing
/// (`DA`, `DSR`, `DECRPM`). While a session's history is being replayed into a
/// fresh surface the second kind is a side effect the user did not ask for: the
/// same query, answered again, would reach a shell that already had its answer.
/// So input is closed for the whole replay window — and closed again the moment
/// a live session starts reconnecting — and opened only after the replayed
/// bytes have been parsed and the queue behind them has drained.
final class TerminalInputRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var forward: (@Sendable (Data) -> Void)?
    private var accepting = false
    private var replaying = false

    /// Where bytes go now. The previous destination is not closed here: the
    /// session owns its socket and closes it.
    func attach(_ forward: (@Sendable (Data) -> Void)?) {
        lock.lock()
        self.forward = forward
        lock.unlock()
    }

    /// Whether the session is live: an ended or failed terminal takes nothing.
    func setAccepting(_ accepting: Bool) {
        lock.lock()
        self.accepting = accepting
        lock.unlock()
    }

    func beginReplay() {
        lock.lock()
        replaying = true
        lock.unlock()
    }

    func endReplay() {
        lock.lock()
        replaying = false
        lock.unlock()
    }

    /// Whether a byte would go out right now — for tests and for the page's own
    /// idea of whether the keyboard is live.
    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting && !replaying && forward != nil
    }

    func send(_ data: Data) {
        lock.lock()
        let allowed = accepting && !replaying
        let forward = self.forward
        lock.unlock()
        guard allowed, let forward else { return }
        forward(data)
    }
}

/// How one event's output is cut into `receive` calls.
///
/// The host delivers up to 16 KiB per output event, and before the surface
/// attaches ghostty keeps at most 1 MiB, dropping the oldest past it; a slice
/// of 64 events is therefore not a byte bound. Each piece is sent on its own,
/// with the queue's room checked between pieces.
enum TerminalFeedPlan {
    /// Small enough that a burst of pieces cannot cross the pre-surface buffer
    /// on its own, large enough that a big paste is not thousands of calls.
    static let chunkBytes = 48 * 1024

    static func chunks(of data: Data, size: Int = chunkBytes) -> [Range<Int>] {
        guard !data.isEmpty else { return [] }
        let step = max(1, size)
        var ranges: [Range<Int>] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + step, data.count)
            ranges.append(offset ..< end)
            offset = end
        }
        return ranges
    }
}

/// What every attempt at an attachment does before it awaits anything: closes
/// the keyboard, and puts the replay gate down.
///
/// A reconnect the reader can see must be a keyboard that is already closed —
/// at the start of an attempt, and again the moment one fails, before the page
/// is told and before the backoff sleep. Otherwise the page says Reconnecting
/// while a keystroke, or a reply the parser generated from history, still goes
/// out.
enum TerminalAttemptGate {
    static func reopen(_ router: TerminalInputRouter) {
        router.setAccepting(false)
        router.beginReplay()
    }
}

/// Whether this attachment's surface has been seen attached, recorded only by
/// the generation that saw it.
///
/// Waiting for a surface suspends. If another attachment takes over while the
/// wait sleeps, the surface that answers belongs to that newer generation; an
/// older attempt that wrote "ready" anyway would let the new one skip its own
/// check and feed a surface it never confirmed.
struct TerminalSurfaceLatch: Equatable {
    private(set) var ready = false

    /// True when `token` still owns the session and the latch is now ready.
    mutating func markReady(token: Int, current: Int) -> Bool {
        guard token == current else { return false }
        ready = true
        return true
    }
}
