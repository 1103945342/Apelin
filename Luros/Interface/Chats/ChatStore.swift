import ApelinCore
import ApelinProtocol
import Foundation

struct ChatRecord: Codable, Sendable {
    var summary: ChatSummary
    var draft = ComposerDraft()
    var sessionID: String?
    var task: TaskHandle?
    /// What the app knows about the run its last turn belongs to. The events
    /// alone cannot say whether more is coming: a task that ended — or a
    /// session the host no longer has — leaves a turn that looks as if it
    /// were still going, with nothing left to stop, unless this says so.
    var run: ChatRunState?
    /// Only ever appended to (`take`): the runtime's transcript of them reads
    /// on from the ones it has read (`ChatTranscriptCache`).
    var events: [TaskEvent] = []
    /// Messages sent and not yet echoed by the host, oldest first: shown at
    /// once, and kept on disk until their `prompt` or `queued` event comes
    /// back, so a kill mid-send loses none. Absent from older files.
    var sending: [ComposerDraft]?
    /// Set while the task of a reopened session replays the history
    /// `events` already hold (`reopen(as:)`). Absent from older files.
    var replay: SessionReplay?
}

/// What the app knows about the run a conversation's last turn belongs to.
/// Missing from older records, which read it from their events.
enum ChatRunState: String, Codable, Sendable {
    /// The host serves a run for this conversation.
    case running
    /// Stop was taken; the host has not said the run is over yet.
    case stopping
    /// Nothing more is coming for that turn.
    case ended
}

/// The replay a reopened session's task starts with: every event of the
/// session again, renumbered and newly timed, before anything new. It ends
/// at the first user message or compaction the conversation has not seen:
/// Compact… reopens a stopped session too, with no message after it. It
/// also ends where the task does, when the task stops before getting that
/// far: its worker died, the host stopped, or a second open of the session
/// failed.
///
/// One thing in it is new: the resolution of each approval an earlier task
/// left waiting, which the reopened worker writes (deny, "the session
/// restarted") before anything new. That task has ended, so the approval
/// can never be answered; read past, its card stood in for the composer on
/// every later turn, and neither Approve nor Deny could take it away
/// (issue #38). `take` keeps it and goes on reading past the rest.
struct SessionReplay: Codable, Sendable {
    private static let userMessageKinds: Set<String> = ["prompt", "steer"]
    private static let compactionKind = "compactionStarted"
    /// The reader's changes to the history (`agentRewind` and the rest),
    /// which a stopped session reopened for them records with no message
    /// after it, as Compact… does.
    private static let historyKinds: Set<String> = ["historyRewound", "messageEdited", "replyEdited", "replyDeleted"]

    /// How far the task has been read.
    var cursor = EventSeq.start
    /// The user messages still to come again: those with an id, and how many
    /// without one (a steer, or a message another conversation sent).
    private var messageIDs: Set<UUID> = []
    private var unnamedMessages = 0
    /// The compactions still to come again. Absent from older files, which
    /// have none.
    private var compactions: Int?
    /// The history's changes still to come again, by kind. Absent from
    /// older files, which have none.
    private var historyChanges: [String: Int]?
    /// The approvals the history asked and never saw resolved. Absent from
    /// older files, which take none.
    private var waitingApprovals: Set<String>?
    /// Queue snapshots already shown by the app. A recovery or a queue-only
    /// edit can be the first new event after reopening, with no prompt.
    private var pendingSnapshots: Int?

    /// The replay of a session whose history is `events`.
    init(of events: [TaskEvent]) {
        var waiting: Set<String> = []
        for event in events {
            if Self.userMessageKinds.contains(event.kind) {
                if let id = ChatTranscript.userMessageID(of: event) {
                    messageIDs.insert(id)
                } else {
                    unnamedMessages += 1
                }
            } else if let approval = Self.approvalID(event, kind: "approvalRequested") {
                waiting.insert(approval)
            } else if let approval = Self.approvalID(event, kind: "approvalResolved") {
                waiting.remove(approval)
            }
        }
        compactions = events.count { $0.kind == Self.compactionKind }
        var changes: [String: Int] = [:]
        for event in events where Self.historyKinds.contains(event.kind) {
            changes[event.kind, default: 0] += 1
        }
        historyChanges = changes
        waitingApprovals = waiting
        pendingSnapshots = events.count { $0.kind == "pendingQueue" }
    }

    /// Whether `event` resolves an approval the history left waiting, which
    /// the conversation has not seen: once for each.
    mutating func resolvesWaitingApproval(_ event: TaskEvent) -> Bool {
        guard let approval = Self.approvalID(event, kind: "approvalResolved") else { return false }
        return waitingApprovals?.remove(approval) != nil
    }

    private static func approvalID(_ event: TaskEvent, kind: String) -> String? {
        event.kind == kind ? event.payload?["approvalID"]?.stringValue : nil
    }

    /// Whether `event` is still part of the replay, counting off the user
    /// message it repeats. The `state` a task ends with never is: the
    /// worker replays only the states an approval sets, so one that ends
    /// the task is this task's own end, and the turn ends on it as in a
    /// first task.
    mutating func replays(_ event: TaskEvent) -> Bool {
        if ChatTranscript.endsTask(event) {
            return false
        }
        if event.kind == "pendingQueue" {
            guard let remaining = pendingSnapshots, remaining > 0 else { return false }
            pendingSnapshots = remaining - 1
            return true
        }
        if event.kind == Self.compactionKind {
            guard let remaining = compactions, remaining > 0 else { return false }
            compactions = remaining - 1
            return true
        }
        if Self.historyKinds.contains(event.kind) {
            guard let remaining = historyChanges?[event.kind], remaining > 0 else { return false }
            historyChanges?[event.kind] = remaining - 1
            return true
        }
        guard Self.userMessageKinds.contains(event.kind) else { return true }
        if let id = ChatTranscript.userMessageID(of: event) {
            return messageIDs.remove(id) != nil
        }
        guard unnamedMessages > 0 else { return false }
        unnamedMessages -= 1
        return true
    }
}

extension ChatRecord {
    /// Whether a message is still on its way to the host.
    var isSending: Bool {
        !(sending ?? []).isEmpty
    }

    /// `message` sent by the reader, shown at once from `sending` until the
    /// host echoes it, the composer emptied if it held that draft. Writing
    /// in a conversation is what moves it up the sidebar (`lastInteraction`),
    /// and a conversation the reader writes in is read.
    mutating func submit(_ message: ComposerDraft, at now: Date = Date()) {
        sending = (sending ?? []) + [message]
        if draft.id == message.id {
            draft = ComposerDraft()
        }
        summary.lastInteraction = now
        summary.markRead()
    }

    /// Takes out of `sending` each message `events` echo, and returns it
    /// with the event that echoed it. A draft put back by
    /// `reclaimUnsent` that the host did take is emptied too, unless its
    /// text was changed since.
    mutating func takeEchoed(by events: [TaskEvent]) -> [(draft: ComposerDraft, event: TaskEvent)] {
        var echoed: [(draft: ComposerDraft, event: TaskEvent)] = []
        let acknowledgements = events.flatMap(ChatTranscript.acceptedMessages)
        for event in acknowledgements {
            guard let id = ChatTranscript.userMessageID(of: event) else { continue }
            if let index = sending?.firstIndex(where: { $0.id == id }), let draft = sending?.remove(at: index) {
                echoed.append((draft, event))
            }
            if draft.id == id, draft.text == event.payload?["text"]?.stringValue ?? "" {
                draft = ComposerDraft()
            }
        }
        if sending?.isEmpty == true {
            sending = nil
        }
        return echoed
    }

    /// A send that failed: the message leaves `sending`, and its draft
    /// returns if nothing was typed since and the host did not record it
    /// before failing (its event shows it then). Returns whether it did.
    mutating func takeBack(_ message: ComposerDraft) -> Bool {
        sending?.removeAll { $0.id == message.id }
        if sending?.isEmpty == true {
            sending = nil
        }
        let recorded = events.contains { event in
            ChatTranscript.acceptedMessages(in: event).contains { ChatTranscript.userMessageID(of: $0) == message.id }
        }
        guard !recorded, draft.text.isEmpty, draft.attachments.isEmpty else { return false }
        draft = message
        return true
    }

    /// The session is now `task`. One that is not the task `events` came
    /// from belongs to a reopened session, and starts by replaying the whole
    /// history under its own numbering; `events` already hold it, so `take`
    /// reads past that replay instead of showing it again. With no history
    /// there is nothing to read past: a first task's events are all new,
    /// an error before its first prompt included.
    mutating func reopen(as task: TaskHandle) {
        // A task is followed again, so whatever turn it is in is going until
        // the host or its events say otherwise.
        run = .running
        guard self.task != task else { return }
        self.task = task
        replay = events.isEmpty ? nil : SessionReplay(of: events)
    }

    /// The task this replay belongs to has ended, so the rest of the history
    /// it was reading past is never coming: what arrives next is new.
    mutating func dropReplay() {
        replay = nil
    }

    /// Where reading the session's task goes on from.
    var cursor: EventSeq {
        replay?.cursor ?? events.last?.seq ?? .start
    }

    /// Adds the events of `batch` past the cursor, less a reopened task's
    /// replay, and returns them. Of the replay, only the resolutions of
    /// approvals the history left waiting are added (`SessionReplay`).
    mutating func take(_ batch: [TaskEvent]) -> [TaskEvent] {
        let fresh = batch.filter { $0.seq > cursor }
        guard var replay else {
            events += fresh
            return fresh
        }
        var resolved: [TaskEvent] = []
        for (index, event) in fresh.enumerated() {
            if replay.resolvesWaitingApproval(event) {
                resolved.append(event)
            } else if !replay.replays(event) {
                self.replay = nil
                let taken = resolved + fresh[index...]
                events += taken
                return taken
            }
            replay.cursor = event.seq
        }
        self.replay = replay
        events += resolved
        return resolved
    }

    /// Where the end of the finished task `batch` answered for is, when this
    /// conversation read past it: the cursor is there, and its transcript
    /// still runs a turn (`isWorking`) though the task has ended. An earlier
    /// version read the `state` a reopened session's task ended with during
    /// its replay as part of the replay, and moved the cursor past it,
    /// where no attach brings it again. The host appends nothing after that
    /// `state`, so it is the task's last event, at `batch.lastSeq`. Nil
    /// when nothing is missing.
    func missedEnd(of batch: TaskEventBatch, isWorking: Bool) -> EventSeq? {
        guard isWorking, batch.finished, batch.lastSeq > .start, cursor >= batch.lastSeq else { return nil }
        return batch.lastSeq
    }

    /// Takes `end`, read again from the task, as the end `missedEnd` found
    /// at `seq`: that one event, once, which ends a replay still waiting.
    /// Nil, or anything but a `state` that ends the task at `seq`, is left
    /// out. Either way the row stops working, since the task has ended.
    /// Returns whether it took the event.
    @discardableResult
    mutating func takeMissedEnd(_ end: TaskEvent?, at seq: EventSeq) -> Bool {
        summary.isWorking = false
        guard let end, end.seq == seq, ChatTranscript.endsTask(end), events.last != end else { return false }
        replay = nil
        events.append(end)
        return true
    }

    /// After a relaunch, what is still in `sending` may never have reached
    /// the host, so it goes back to the draft, before anything typed after
    /// it. A lone message keeps its id: if the host did take it, sending it
    /// again is not a second message, and its echo empties the draft.
    mutating func reclaimUnsent() {
        _ = takeEchoed(by: events)
        guard let unsent = sending else { return }
        sending = nil
        let parts = (unsent + [draft]).filter { !$0.text.isEmpty || !$0.attachments.isEmpty }
        if parts.count == 1, let only = parts.first {
            draft = only
        } else {
            draft = ComposerDraft(text: parts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                  attachments: parts.flatMap(\.attachments))
        }
    }
}

/// Serial disk writes keep a slow earlier save from replacing a newer transcript.
actor ChatStore {
    private let folder: DataFolder
    private var revisions: [UUID: Int] = [:]

    init(folder: DataFolder) {
        self.folder = folder
    }

    /// What `load` read, and the files that did not decode: each one moved
    /// into `Chats/Unreadable/` with why, so one file that does not decode — cut
    /// short, or written by another version — never takes every other
    /// conversation with it on each launch (issue #33), and is kept rather
    /// than overwritten.
    struct Loaded {
        var records: [ChatRecord] = []
        /// How many events each conversation's file holds. A launch takes
        /// this and reads no events, so the sidebar and the pruning rules
        /// know a chat has a history without its megabytes.
        var eventCounts: [UUID: Int] = [:]
        var unreadable: [(name: String, error: any Error)] = []
    }

    /// A conversation as it is kept on disk now: everything but its events,
    /// which live beside it in `ChatEventsFile` — how many there are, so the
    /// count the app prunes and pages by costs no read of them.
    private struct Head: Codable {
        var version = 2
        var summary: ChatSummary
        var draft = ComposerDraft()
        var sessionID: String?
        var task: TaskHandle?
        var run: ChatRunState?
        var sending: [ComposerDraft]?
        var replay: SessionReplay?
        var eventCount = 0

        init(_ record: ChatRecord) {
            summary = record.summary
            draft = record.draft
            sessionID = record.sessionID
            task = record.task
            run = record.run
            sending = record.sending
            replay = record.replay
            eventCount = record.events.count
        }

        func record(events: [TaskEvent]) -> ChatRecord {
            ChatRecord(
                summary: summary,
                draft: draft,
                sessionID: sessionID,
                task: task,
                run: run,
                events: events,
                sending: sending,
                replay: replay,
            )
        }

        func counting(_ count: Int) -> Head {
            var head = self
            head.eventCount = count
            return head
        }
    }

    /// How many events of each conversation are on disk, as `save` left them.
    private var written: [UUID: Int] = [:]

    /// `readingEvents` false is what launching does: it reads each record's
    /// head and how many events sit beside it, and no event at all. The
    /// conversation's events are read later, when it is opened or followed,
    /// with `events(_:in:)`.
    func load(readingEvents: Bool = true) throws -> Loaded {
        let directory = folder.root.appendingPathComponent("Chats")
        try folder.makeLevels(to: directory)
        guard let directoryPath = CanonicalPath.resolve(directory.path) else { throw CocoaError(.fileReadNoSuchFile) }
        restoreReadable(in: directory)
        var loaded = Loaded()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json"
        {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let path = CanonicalPath.resolve(url.path),
                  CanonicalPath.isCanonical(path, inside: directoryPath)
            else { continue }
            // A file that cannot be opened now (before the first unlock, say)
            // is only skipped: it is read again next launch, never moved.
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            do {
                let (record, count) = try read(id: id, data: data, in: directory, readingEvents: readingEvents)
                loaded.records.append(record)
                loaded.eventCounts[id] = count
            } catch {
                loaded.unreadable.append((url.lastPathComponent, error))
                setAside(url, in: directory)
            }
        }
        return loaded
    }

    /// One conversation: its head and the events beside it, and how many
    /// there are. A record written before the split still carries them
    /// inline, and is moved out here, once. With `readingEvents` false the
    /// events stay on disk and only the count comes back.
    private func read(
        id: UUID,
        data: Data,
        in directory: URL,
        readingEvents: Bool,
    ) throws -> (record: ChatRecord, count: Int) {
        let decoder = JSONDecoder()
        if let head = try? decoder.decode(Head.self, from: data) {
            if !readingEvents {
                written[id] = head.eventCount
                return (head.record(events: []), head.eventCount)
            }
            // The event file is the truth about how many there are: a save that
            // appended them and was cut off before it wrote the head leaves
            // more than the head says, and none of them is lost.
            let events = try ChatEventsFile.read(id, in: directory)
            written[id] = events.count
            if events.count != head.eventCount {
                try write(head.counting(events.count), into: directory)
            }
            return (head.record(events: events), events.count)
        }
        // No `version`: a record from before the split, events included.
        let record = try decoder.decode(ChatRecord.self, from: data)
        try migrate(record, into: directory)
        written[id] = record.events.count
        guard readingEvents else {
            return (Head(record).record(events: []), record.events.count)
        }
        return (record, record.events.count)
    }

    /// Writes a legacy record's events to their own file and then the record
    /// without them. The order is what makes it safe: a launch cut off between
    /// the two finds the old record still whole and migrates again.
    private func migrate(_ record: ChatRecord, into directory: URL) throws {
        try ChatEventsFile.write(record.events, for: record.summary.id, in: directory)
        try write(Head(record), into: directory)
    }

    /// Puts back a conversation set aside earlier that decodes now — one a
    /// newer version wrote, back after an upgrade — unless its place has
    /// been taken since.
    private func restoreReadable(in directory: URL) {
        let aside = directory.appendingPathComponent("Unreadable", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: aside.path) else { return }
        for name in names where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.prefix(36))) else { continue }
            let source = aside.appendingPathComponent(name)
            let destination = directory.appendingPathComponent(id.uuidString + ".json")
            guard !FileManager.default.fileExists(atPath: destination.path),
                  let data = try? Data(contentsOf: source)
            else { continue }
            // A record without its events would open the conversation with no
            // history: that one stays where it is.
            let readable: Bool
            if let head = try? JSONDecoder().decode(Head.self, from: data) {
                readable = head.eventCount == 0
                    || FileManager.default.fileExists(atPath: ChatEventsFile.url(for: id, in: directory).path)
            } else {
                readable = (try? JSONDecoder().decode(ChatRecord.self, from: data)) != nil
            }
            guard readable else { continue }
            rename(source.path, destination.path)
        }
    }

    /// Moves an unreadable conversation out of the way, under a name no
    /// other file there has. When that fails it stays, and is read past
    /// again next time.
    private func setAside(_ url: URL, in directory: URL) {
        let aside = directory.appendingPathComponent("Unreadable", isDirectory: true)
        guard (try? folder.makeLevels(to: aside)) != nil else { return }
        let stem = url.deletingPathExtension().lastPathComponent + "-\(Int(Date().timeIntervalSince1970))"
        var destination = aside.appendingPathComponent(stem + ".json")
        var attempt = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            attempt += 1
            destination = aside.appendingPathComponent("\(stem)-\(attempt).json")
        }
        rename(url.path, destination.path)
    }

    /// `writesEvents` false is a conversation whose events were not read: only
    /// its head is written, and `eventCount` — how many its file holds — keeps
    /// the count the next launch prunes and pages by, so a chat whose events
    /// are merely unread is never mistaken for an empty one.
    func save(
        _ record: ChatRecord,
        revision: Int,
        writesEvents: Bool = true,
        eventCount: Int? = nil,
    ) throws {
        let id = record.summary.id
        guard revision > (revisions[id] ?? -1) else { return }
        let directory = folder.root.appendingPathComponent("Chats")
        try folder.makeLevels(to: directory)
        // The events first and the head after, so a launch cut off between the
        // two reads more events than the head names and keeps them (`read`).
        // A conversation that went backwards — a compaction, a rewind, an edit
        // — is written out whole; anything else only appends what it gained,
        // which is what a streamed turn costs now.
        if writesEvents {
            let onDisk = written[id] ?? 0
            if record.events.count < onDisk {
                try ChatEventsFile.write(record.events, for: id, in: directory)
            } else if record.events.count > onDisk {
                try ChatEventsFile.append(Array(record.events[onDisk...]), for: id, in: directory)
            }
        }
        let head = Head(record)
        try write(eventCount.map(head.counting) ?? head, into: directory)
        if writesEvents { written[id] = record.events.count }
        revisions[id] = revision
    }

    /// What a read of a conversation's events found on disk, after a launch
    /// that only counted them.
    func note(eventsOnDisk id: UUID, count: Int) {
        written[id] = count
    }

    /// The conversation's record without its events, replaced atomically.
    private func write(_ head: Head, into directory: URL) throws {
        try JSONEncoder().encode(head).write(
            to: directory.appendingPathComponent(head.summary.id.uuidString + ".json"),
            options: .atomic,
        )
    }

    func remove(_ id: UUID) throws {
        let directory = folder.root.appendingPathComponent("Chats")
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Deleting before the first queued save is also a successful delete.
        }
        ChatEventsFile.remove(id, in: directory)
        written[id] = 0
        revisions[id] = Int.max
    }
}
