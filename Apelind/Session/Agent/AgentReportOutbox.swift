import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

// What the host knows about the turns of a conversation an agent opened, and
// what it still owes the conversation that opened it: one value, written to
// one file and read back (`AgentReportRelay`).
//
// It is here on its own — no clock, no worker, no host — so every decision it
// makes can be tried without any of them (Tests/SessionHost/AgentReportChecks).
//
// One outbox belongs to one opener. Everything in it is committed in one
// write: the cursor that says which of a child's events were read, the turn
// being read, and the reports not delivered yet. An event that produced a
// report and the report itself are therefore never halves of each other.

struct AgentReportEnvelope: Codable, Equatable {
    /// The envelope's own identity, made once: what a delivery acknowledges by
    /// name, so a report that arrived while an earlier one was being
    /// delivered is never removed with it.
    var id: UUID
    var report: AgentTurnReport
}

/// The one message a wave travels as. Its ID is made before the first attempt
/// and kept for every retry, so a redelivery is the same message to the
/// opener's session, which drops a second copy by its message ID.
struct AgentReportWave: Codable, Equatable {
    var id: UUID
    /// The envelopes this message carries, oldest first.
    var members: [UUID]
    /// Fixed alongside the UUID, including the ledger snapshot. A retry never
    /// silently replaces the facts carried by an already accepted message.
    var text: String? = nil
    /// A host account shares the same durable wave and receiver deduplication.
    /// It is not a fabricated child's closing turn.
    var finalAccountEventID: String? = nil
    /// Group and member revisions of a host status notice, not a child turn.
    var statusKey: String? = nil
}

/// The turn of one child task being read, as its events arrive.
struct AgentReportTurn: Codable, Equatable {
    /// The opener's opening prompt is still to come, so the first `prompt`
    /// this task records is the opener's even though the worker records it
    /// without a sender.
    var seeded = false
    /// A message from the opener was taken in this turn.
    var fromOpener = false
    /// The messages from the opener this turn took, by id, oldest first.
    var answered: [UUID] = []
    /// The turn's last complete assistant message, bounded.
    var text = ""
    var truncated = false
    /// A successfully acknowledged stop, bound to this open turn. Optional for
    /// old outboxes; unlike an in-flight RPC, it survives a host restart.
    var confirmedStop: AgentTurnStoppedBy? = nil
}

/// One event of a child's task, as much of it as a turn is read from: what
/// the relay takes out of the worker's payload, and nothing else.
struct AgentReportEvent: Equatable {
    enum Kind: Equatable {
        /// A message was taken into a turn.
        case prompt
        /// The assistant message that ended is complete (`message`).
        case message
        /// The run ended (`finished`).
        case finished
        /// The task's state (`state`).
        case state
        /// Anything a turn is not read from.
        case other
    }

    var seq: UInt64
    /// The app reading a session's history back, which is not a turn
    /// happening now: the worker marks every replayed event `historical`.
    var historical = false
    var kind: Kind = .other
    /// Who sent the message a `prompt` took; nil for the reader.
    var from: String?
    /// The message a `prompt` took, by id.
    var message: UUID?
    /// The assistant message of a `message` event.
    var text: String?
    /// The reason a `finished` event gives.
    var reason: String?
    /// The state a `state` event names.
    var state: String?

    init(
        seq: UInt64,
        historical: Bool = false,
        kind: Kind = .other,
        from: String? = nil,
        message: UUID? = nil,
        text: String? = nil,
        reason: String? = nil,
        state: String? = nil
    ) {
        self.seq = seq
        self.historical = historical
        self.kind = kind
        self.from = from
        self.message = message
        self.text = text
        self.reason = reason
        self.state = state
    }
}

/// The stops on their way to a worker, each bound to the task it was asked
/// for: the closing event of that task takes it, so no clock decides which
/// turn a stop ended.
struct AgentReportStops: Equatable {
    struct Note: Equatable {
        var by: AgentTurnStoppedBy
        var task: String
    }

    private var notes: [String: Note] = [:]

    mutating func note(session: String, by: AgentTurnStoppedBy, task: String) {
        notes[session] = Note(by: by, task: task)
    }

    /// The note for this turn. Spent whatever the turn says: a note never
    /// names a later one.
    mutating func take(session: String, task: String) -> AgentTurnStoppedBy? {
        guard let note = notes.removeValue(forKey: session) else { return nil }
        return note.task == task ? note.by : nil
    }

    mutating func clear(session: String) {
        notes.removeValue(forKey: session)
    }
}

struct AgentReportLedger: Codable, Equatable {
    /// Bumped when an entry's shape changes: a file of another version is not
    /// one this host writes back.
    static let version = 1
    /// How much of one report's answer travels; `truncated` says the rest is
    /// in `conversation_read`.
    static let maximumReportBytes = 4000
    /// The whole message a wave travels as.
    static let maximumMessageBytes = 16 * 1024
    /// The `state` payloads that end a task, as `TaskState` spells them.
    static let terminalStates: Set<String> = ["succeeded", "failed", "cancelled", "interrupted"]

    var version = AgentReportLedger.version
    /// "<child session>|<child task>" -> the last event read of that task.
    var cursors: [String: UInt64] = [:]
    /// "<child session>|<child task>" -> the turn being read.
    var turns: [String: AgentReportTurn] = [:]
    /// Reports not delivered yet, oldest first.
    var pending: [AgentReportEnvelope] = []
    /// The message being delivered, if one is.
    var wave: AgentReportWave?
    var lastStatusKey: String?
    /// A conversation that was deleted: nothing is delivered to it again, and
    /// the file stays as the record of what was owed. Optional so an outbox
    /// written before this field still reads.
    var retired: Bool? = nil
    /// Children whose conversation was deleted. Nothing is reported about one
    /// again, whichever host reads this outbox. Capped, so a long-lived
    /// opener's file stays bounded.
    var retiredChildren: [String]? = nil

    static let maximumRetiredChildren = 64


    static func key(child: String, task: String) -> String {
        "\(child)|\(task)"
    }

    // MARK: Reading a child's events

    /// The opener's opening prompt is on its way to the child: the first turn
    /// of this task is the opener's, whichever way the worker records it.
    mutating func seed(child: String, task: String) -> Bool {
        let key = Self.key(child: child, task: task)
        guard turns[key] == nil else { return false }
        turns[key] = AgentReportTurn(seeded: true, fromOpener: true)
        return true
    }

    /// The open never reached the child: the seeded turn is not one, and
    /// nothing is owed for it.
    mutating func abandon(child: String, task: String) {
        let key = Self.key(child: child, task: task)
        guard let turn = turns[key], turn.seeded, turn.answered.isEmpty else { return }
        turns.removeValue(forKey: key)
    }

    /// Whether `child`'s conversation was deleted: nothing about it is owed.
    func isRetired(child: String) -> Bool {
        retiredChildren?.contains(child) ?? false
    }

    /// The conversation of `child` was deleted. The turn being read is not one
    /// any more, and what waited about it is retired. A wave already frozen
    /// keeps what it named: it was composed before the deletion, and changing
    /// it would make its text and its members disagree.
    mutating func retire(child: String) {
        let prefix = "\(child)|"
        for key in turns.keys where key.hasPrefix(prefix) {
            turns.removeValue(forKey: key)
        }
        let carried = Set(wave?.members ?? [])
        pending.removeAll { $0.report.childSessionID == child && !carried.contains($0.id) }
        var gone = retiredChildren ?? []
        guard !gone.contains(child) else { return }
        gone.append(child)
        if gone.count > Self.maximumRetiredChildren {
            gone.removeFirst(gone.count - Self.maximumRetiredChildren)
        }
        retiredChildren = gone
    }

    /// One of the child's events. A turn is reported only when at least one
    /// message from the opener was taken in it; a replayed event, or one
    /// already read, changes nothing.
    ///
    /// `stopped` is the stop recorded for this task, which only an aborted or
    /// interrupted end may use.
    mutating func apply(
        _ event: AgentReportEvent,
        child: String,
        task: String,
        opener: String,
        title: String?,
        stopped: AgentTurnStoppedBy?
    ) -> AgentTurnReport? {
        guard !event.historical else { return nil }
        // A deleted conversation stays deleted: nothing is read about it again,
        // whichever event of it arrives after the deletion.
        guard !isRetired(child: child) else { return nil }
        let key = Self.key(child: child, task: task)
        switch event.kind {
        case .prompt:
            guard event.seq > cursors[key, default: 0] else { return nil }
            cursors[key] = event.seq
            var turn = turns[key] ?? AgentReportTurn()
            turn.seeded = false
            if event.from == opener {
                turn.fromOpener = true
                if let message = event.message, !turn.answered.contains(message) {
                    turn.answered.append(message)
                }
            }
            turns[key] = turn
            return nil
        case .message:
            guard event.seq > cursors[key, default: 0], var turn = turns[key], let text = event.text else {
                return nil
            }
            cursors[key] = event.seq
            let bounded = Self.bounded(text, bytes: Self.maximumReportBytes)
            turn.text = bounded.text
            turn.truncated = bounded.truncated
            turns[key] = turn
            return nil
        case .finished:
            guard event.seq > cursors[key, default: 0] else { return nil }
            cursors[key] = event.seq
            guard let turn = turns.removeValue(forKey: key) else { return nil }
            let outcome = event.reason.flatMap { AgentTurnOutcome(rawValue: $0) } ?? .failed
            return report(
                child: child,
                task: task,
                closing: event.seq,
                outcome: outcome,
                stoppedBy: outcome == .aborted ? (turn.confirmedStop ?? stopped) : nil,
                title: title,
                turn: turn
            )
        case .state:
            guard let name = event.state, Self.terminalStates.contains(name),
                  event.seq > cursors[key, default: 0]
            else { return nil }
            cursors[key] = event.seq
            guard let turn = turns.removeValue(forKey: key) else { return nil }
            // The task ended without its run saying how: it was cut short,
            // by the host, a close, or a worker that went away.
            return report(
                child: child,
                task: task,
                closing: event.seq,
                outcome: .interrupted,
                stoppedBy: turn.confirmedStop ?? stopped ?? .host,
                title: title,
                turn: turn
            )
        case .other:
            return nil
        }
    }

    /// The task ended without any event of its own to say so — the host
    /// stopped it, or the last host never came back — so the turn being read
    /// ended with it. `closing` is the task's own last event number.
    mutating func interrupted(
        child: String,
        task: String,
        closing: UInt64,
        stoppedBy: AgentTurnStoppedBy?,
        title: String?
    ) -> AgentTurnReport? {
        let key = Self.key(child: child, task: task)
        guard let turn = turns.removeValue(forKey: key) else { return nil }
        cursors[key] = max(cursors[key, default: 0], closing)
        return report(
            child: child,
            task: task,
            closing: closing,
            outcome: .interrupted,
            stoppedBy: turn.confirmedStop ?? stoppedBy ?? .host,
            title: title,
            turn: turn
        )
    }

    private mutating func report(
        child: String,
        task: String,
        closing: UInt64,
        outcome: AgentTurnOutcome,
        stoppedBy: AgentTurnStoppedBy?,
        title: String?,
        turn: AgentReportTurn
    ) -> AgentTurnReport? {
        // A turn no message from the opener was taken in is the reader's own,
        // and what the child answered there stays with it.
        guard turn.fromOpener else { return nil }
        let report = AgentTurnReport(
            childSessionID: child,
            childTaskID: task,
            title: title.map { Self.bounded($0, bytes: 256).text },
            outcome: outcome,
            stoppedBy: stoppedBy,
            closingSeq: closing,
            answered: turn.answered,
            text: turn.text,
            truncated: turn.truncated
        )
        guard !pending.contains(where: { $0.report.key == report.key }) else { return nil }
        pending.append(AgentReportEnvelope(id: UUID(), report: report))
        return report
    }

    // MARK: Delivering

    /// The members of the next message, oldest first: as many pending reports
    /// as one bounded message holds, at least one. What does not fit goes in
    /// the message after it — a budget never drops a report.
    func waveMembers(maxBytes: Int, compose: ([AgentTurnReport]) -> String) -> [UUID] {
        var chosen: [AgentReportEnvelope] = []
        for envelope in pending {
            let candidate = chosen + [envelope]
            if !chosen.isEmpty, compose(candidate.map { $0.report }).utf8.count > maxBytes {
                break
            }
            chosen = candidate
        }
        return chosen.map { $0.id }
    }

    /// The envelopes a wave carries, in its order; one no longer pending is
    /// skipped.
    func envelopes(of wave: AgentReportWave) -> [AgentReportEnvelope] {
        wave.members.compactMap { id in pending.first { $0.id == id } }
    }

    /// The delivery was accepted: the envelopes it carried leave the outbox,
    /// and no other does.
    mutating func acknowledge(_ delivered: AgentReportWave) {
        let members = Set(delivered.members)
        pending.removeAll { members.contains($0.id) }
        if let statusKey = delivered.statusKey { lastStatusKey = statusKey }
        if wave?.id == delivered.id {
            wave = nil
        }
    }

    /// A wave whose reports are no longer all in the outbox is not one the
    /// next delivery can name: it starts again.
    mutating func repairWave() {
        guard let wave else { return }
        if wave.members.isEmpty, wave.finalAccountEventID != nil || wave.statusKey != nil,
           wave.text != nil { return }
        guard !wave.members.isEmpty,
              wave.members.allSatisfy({ member in pending.contains { $0.id == member } })
        else {
            self.wave = nil
            return
        }
    }

    /// `text` cut to `bytes` of UTF-8 without splitting a character, and
    /// whether it was cut.
    static func bounded(_ text: String, bytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        var view = text.utf8.prefix(bytes)
        while !view.isEmpty, String(decoding: view, as: UTF8.self).utf8.count != view.count {
            view = view.dropLast()
        }
        return (String(decoding: view, as: UTF8.self), true)
    }
}

/// One opener's outbox as the host holds it: what its file says, and whether
/// that file may be written back. `commit` writes the whole ledger and moves
/// what the host holds only after the write: a save that fails, or a file that
/// did not read, leaves everything exactly as it was, so nothing unpersisted
/// is ever delivered.
struct AgentReportFile {
    let store: AgentReportStore
    private(set) var ledger: AgentReportLedger
    /// Why the file is not written back; nil when it may be.
    private(set) var refusal: String?
    /// The last write that failed, for the caller to report; nil after one
    /// that worked.
    private(set) var failure: String?

    init(store: AgentReportStore) {
        self.store = store
        switch store.load() {
        case .empty:
            ledger = AgentReportLedger()
            refusal = nil
        case let .ledger(saved):
            ledger = saved
            ledger.repairWave()
            refusal = nil
        case let .unreadable(reason):
            // Never replaced with an empty outbox the next save would make
            // permanent: what it held is kept, and nothing is written over it.
            ledger = AgentReportLedger()
            refusal = reason
        }
    }

    var blocked: Bool {
        refusal != nil
    }

    /// Applies `change` and writes all of it down in one write. Answers
    /// whether what is on disk holds the change.
    @discardableResult
    mutating func commit(_ change: (inout AgentReportLedger) -> Void) -> Bool {
        guard refusal == nil else { return false }
        var draft = ledger
        change(&draft)
        guard draft != ledger else { return true }
        do {
            try store.save(draft)
        } catch {
            failure = "\(error)"
            return false
        }
        ledger = draft
        failure = nil
        return true
    }
}

/// One opener's outbox file, read and written whole. A file that does not read
/// is never written over: it is kept as it is, the error is reported, and the
/// outbox it names stays closed, so what it held can still be looked at.
struct AgentReportStore {
    enum Loaded: Equatable {
        case empty
        case ledger(AgentReportLedger)
        /// The file is there and is not one this host writes back.
        case unreadable(String)
    }

    let file: URL

    func load() -> Loaded {
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            return errno == ENOENT ? .empty : .unreadable("the outbox cannot be inspected")
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .unreadable("the outbox is not a regular file") }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .unreadable("the outbox cannot be opened safely") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_size >= 0, opened.st_size <= 64 * 1024 * 1024 else {
            return .unreadable("the outbox is not a bounded regular file; preserve it and stop")
        }
        let data: Data
        do {
            data = try handle.read(upToCount: Int(opened.st_size) + 1) ?? Data()
            guard data.count == Int(opened.st_size) else { return .unreadable("the outbox changed during its read") }
        } catch {
            return .unreadable("\(error)")
        }
        let ledger: AgentReportLedger
        do {
            ledger = try JSONCoding.decode(AgentReportLedger.self, from: data)
        } catch {
            return .unreadable("\(error)")
        }
        guard ledger.version == AgentReportLedger.version else {
            return .unreadable("version \(ledger.version) is not \(AgentReportLedger.version)")
        }
        return .ledger(ledger)
    }

    /// Written whole, atomically: a write that fails leaves the file that was
    /// there untouched, which is what the caller's memory still says.
    func save(_ ledger: AgentReportLedger) throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONCoding.encode(ledger)
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
