import ApelinCore
import ApelinProtocol
import Foundation

/// Every task the session host owns: its record, its numbered events, and
/// the attaches waiting for the next one. Events are written to
/// `<state>/tasks/` as they come and the record whenever it changes in a
/// way the events do not tell (`append`), so both are on disk before the
/// host reports idle and exits; the next launch reads them back. `load` hands
/// back the tasks that were still running: the host offers each to the
/// resumer registered for its kind (an install follows its irisind
/// transaction again from `resume`; a build or environment task is started
/// again by `TaskResume`), and marks the rest `interrupted`.
actor TaskRegistry {
    struct Record: Codable {
        var id: TaskID
        var kind: TaskKind
        var state: TaskState
        var createdAt: Date
        var updatedAt: Date
        var lastSeq: EventSeq
        /// The last event dropped to keep a terminal's history bounded: what
        /// the log still holds starts at `historyFloor + 1`. Nil when nothing
        /// has been dropped, as it is for every task but a terminal.
        var historyFloor: EventSeq?
        /// What a terminal's log is kept to, so a host that reads the record
        /// back bounds it the same way. Nil for every other kind.
        var historyBudget: HistoryBudget?
        /// The log could not be written back when it outgrew its budget: it is
        /// no longer appended to until one succeeds, so it stays where it is
        /// while the newest events live in memory alone.
        var historyStalled: Bool?
        /// The worker serving it, by role and instance key.
        var owner: WorkerRole?
        var ownerKey: String?
        var cancelRequested: Bool
        /// What the owning domain needs to pick the task up after a restart
        /// (an install's installation ID, a `TaskResume.Plan`). Nil: it
        /// cannot be resumed.
        var resume: JSONValue?
    }

    /// How much of a task's event log is kept. Only a task given a budget (a
    /// terminal, `Session/Terminal`) ever drops an event: every other kind
    /// keeps its log whole, as it always has.
    struct HistoryBudget: Codable, Sendable, Equatable {
        /// The bytes the shell wrote, counted from the base64 each output
        /// event carries.
        var rawBytes: Int
        /// The bytes the host actually holds for them: the base64 and the
        /// text beside it, in memory and on disk.
        var storedBytes: Int
        var events: Int
    }

    /// What a terminal keeps when its record names no budget: a log from a
    /// host that did not bound them, bounded the first time it is read.
    static let terminalHistory = HistoryBudget(
        rawBytes: 2 * 1024 * 1024,
        storedBytes: 6 * 1024 * 1024,
        events: 4096,
    )

    /// How many events go by before a log that could not be rewritten is tried
    /// again.
    static let trimRetryEvents = 1024

    /// What a bounded log has dropped and what it still costs.
    private struct HistoryState {
        /// Events dropped from the front; the first kept event is `base + 1`,
        /// so `lastSeq` and every cursor stay numbered as they were.
        var base: UInt64 = 0
        var raw = 0
        var stored = 0
    }

    static let maximumWaitMilliseconds = 60000
    /// The most events one attach answers with; a longer log takes the next
    /// poll, which the cursor it answered with reaches.
    static let maximumBatchEvents = 1000
    /// What an attach replays first when its cursor is older than what the log
    /// still holds.
    static let trimmedKind = "outputTruncated"

    private let directory: URL
    private var records: [TaskID: Record] = [:]
    private var events: [TaskID: [TaskEvent]] = [:]
    private var histories: [TaskID: HistoryState] = [:]
    private var budgets: [TaskID: HistoryBudget] = [:]
    /// Events left before a log that could not be rewritten is tried again.
    private var trimWaits: [TaskID: Int] = [:]
    /// Tasks whose log cannot be written back: nothing more is appended to it
    /// until a rewrite succeeds, so a folder that cannot be written does not
    /// let one log grow without bound.
    private var stalled: Set<TaskID> = []
    private var waiters: [TaskID: [UUID: CheckedContinuation<Void, Never>]] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// Reads the records left on disk and answers the unfinished ones, which
    /// the caller resumes or marks `interrupted`.
    @discardableResult
    func load() -> [Record] {
        var unfinished: [Record] = []
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        let decoder = JSONCoding.decoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var record = try? decoder.decode(Record.self, from: data)
            else {
                continue
            }
            let read = readEvents(
                record.id,
                allowFloor: record.kind == .terminal,
                floorHint: record.historyFloor?.rawValue ?? 0,
            )
            var replay = read.events
            let trailing = read.skipped
            let floor = read.floor
            // The record is not written again for an ordinary event
            // (`append`), so its time is the last event's that read, and
            // only forward.
            if let last = replay.last, last.time > record.updatedAt {
                record.updatedAt = last.time
            }
            // A record already final whose final `state` line no longer
            // reads would replay with no end: an attach reports it finished
            // with no `state` to take the result from. The lines past the
            // last that read keep their numbers as `unreadable` events, and
            // a closing `state` with the record's state is written after
            // them, so the log is whole again, and the record follows it.
            let closed = record.state.isTerminal && !replay.contains(where: Self.isFinalState)
            if closed {
                replay += closingEvents(record, after: replay, skipped: trailing, floor: floor)
            }
            // The event log is the truth: a record written before the events
            // after it takes the last one's number, and one written ahead of
            // a lost line is pulled back to the last event that survived.
            record.lastSeq = replay.last?.seq ?? .start
            // So is its state: `append` writes the line before the record,
            // and a host that died between the two left a record still
            // running behind a final `state`. Resuming that task would start
            // a finished build over and delete its artifact. The record keeps
            // no result or message of its own; those stay in the event.
            // Only forward: a record already final stays so, since a final
            // `state` line that no longer decodes leaves an earlier
            // `running` as the last one read, and resuming over it would
            // delete the finished build all the same.
            var moved = false
            if !record.state.isTerminal,
               let last = replay.last(where: { $0.kind == TaskEvent.stateKind }),
               let name = last.payload?["state"]?.stringValue,
               let state = TaskState(rawValue: name),
               state != record.state
            {
                record.state = state
                moved = true
            }
            // The log's own start is the truth about how much of it was
            // trimmed, as its numbering is about `lastSeq`.
            let keptFrom: EventSeq? = floor > 0 ? EventSeq(floor) : nil
            if record.historyFloor != keptFrom {
                record.historyFloor = keptFrom
                moved = true
            }
            // A terminal's log is bounded the moment it is read: one an older
            // host left whole, or one a failed rewrite left growing, is brought
            // inside its budget before anyone replays it. The budget goes into
            // the record, so the next host bounds it the same way.
            if record.kind == .terminal {
                let budget = record.historyBudget ?? Self.terminalHistory
                if record.historyBudget == nil {
                    record.historyBudget = budget
                    moved = true
                }
                budgets[record.id] = budget
            }
            if record.historyStalled == true {
                stalled.insert(record.id)
                NSLog("apelind-session: task %@'s log was held at its size", record.id.rawValue)
            }
            records[record.id] = record
            events[record.id] = replay
            // Only a terminal's log is measured, and only its is bounded: for
            // every other kind the state is its floor and its numbering.
            histories[record.id] = record.kind == .terminal
                ? Self.history(of: replay, base: floor)
                : HistoryState(base: floor)
            if closed || moved {
                persist(record.id)
            }
            if let budget = budgets[record.id] {
                trim(record.id, budget: budget)
            }
            if !record.state.isTerminal {
                unfinished.append(record)
            }
        }
        dropSupersededAgentTasks()
        return unfinished.sorted { $0.createdAt < $1.createdAt }
    }

    /// Ends a task the host could not resume, saying why when it knows.
    func interrupt(_ id: TaskID, message: String = "The background service stopped while this task was running. Start the task again.") {
        finish(id, .interrupted, message: message)
    }

    /// Records how to resume the task; written to disk at once.
    func setResume(_ id: TaskID, _ value: JSONValue?) {
        guard var record = records[id], !record.state.isTerminal else { return }
        record.resume = value
        records[id] = record
        persist(id)
    }

    func create(kind: TaskKind, owner: WorkerRole?, ownerKey: String? = nil) -> TaskHandle {
        let now = Date()
        let id = TaskID.make()
        records[id] = Record(
            id: id,
            kind: kind,
            state: .running,
            createdAt: now,
            updatedAt: now,
            lastSeq: .start,
            owner: owner,
            ownerKey: ownerKey,
            cancelRequested: false,
            resume: nil,
        )
        events[id] = []
        histories[id] = HistoryState()
        persist(id)
        if kind == .agent, let ownerKey {
            dropSupersededAgentTasks(of: ownerKey)
        }
        return TaskHandle(taskID: id, kind: kind)
    }

    func record(_ id: TaskID) -> Record? {
        records[id]
    }

    /// Bounds a task's event log: past `rawBytes` of output (or `storedBytes`
    /// as the host holds it, or `events` entries) the oldest whole events are
    /// dropped, from memory and from the log on disk, down to three quarters of
    /// the budget so a rewrite happens once per quarter rather than once per
    /// event. Only a terminal asks for this; every other task keeps its log
    /// whole.
    func setHistoryBudget(_ id: TaskID, rawBytes: Int, storedBytes: Int, events: Int) {
        guard let record = records[id], !record.state.isTerminal else { return }
        let budget = HistoryBudget(
            rawBytes: max(rawBytes, 64 * 1024),
            storedBytes: max(storedBytes, 64 * 1024),
            events: max(events, 16),
        )
        budgets[id] = budget
        var stored = record
        stored.historyBudget = budget
        records[id] = stored
        persist(id)
        trim(id, budget: budget)
    }

    /// Appends an event and numbers it. A `state` event with a `state` field
    /// moves the task; once terminal, nothing more is appended.
    ///
    /// The record is written again only when the event moves the task. Its
    /// number and time are the event's, which `load` reads back from the
    /// log; rewriting it for every event held the registry, which every
    /// request goes through, for as long as a reopened conversation took to
    /// relay its history, tens of thousands of events.
    @discardableResult
    func append(_ id: TaskID, kind: String, payload: JSONValue?) -> TaskEvent? {
        guard var record = records[id], !record.state.isTerminal else { return nil }
        let event = TaskEvent(seq: record.lastSeq.next, kind: kind, payload: payload)
        record.lastSeq = event.seq
        record.updatedAt = event.time
        var moved = false
        if kind == TaskEvent.stateKind,
           let name = payload?["state"]?.stringValue,
           let state = TaskState(rawValue: name),
           state != record.state
        {
            record.state = state
            moved = true
        }
        records[id] = record
        // Encoded once: what is written is what the budget is counted in, so
        // the cap is the file's own bytes and not an estimate of them.
        let line = Self.encoded(event)
        if let budget = budgets[id] {
            let cost = (raw: Self.rawBytes(of: event), stored: line?.count ?? 0, events: 1)
            // Room is made for this event *before* it enters the log, and the
            // room is made for it: the trim knows what is coming, and the
            // rewrite that makes the room cannot already hold the event, which
            // is written exactly once below.
            trim(id, budget: budget, reserve: cost)
            var state = histories[id] ?? HistoryState()
            state.raw += cost.raw
            state.stored += cost.stored
            histories[id] = state
            events[id, default: []].append(event)
            // One event bigger than the whole log never reaches it: no log can
            // hold it, and the budget is a promise about the file's own bytes.
            // The trim after this drops it from memory too, and an attach says
            // the history was trimmed, so the loss is visible rather than
            // silent.
            if let line, !stalled.contains(id), cost.stored <= budget.storedBytes {
                appendEventToDisk(id, line)
            }
            // The wait before a failed rewrite is tried again counts events, so
            // it runs out even while the log is within its budget.
            if let wait = trimWaits[id], wait > 0 {
                trimWaits[id] = wait - 1
            }
            // What still does not fit — an event larger than the whole budget —
            // goes, and a task's last event writes the log back as it stands so
            // a finished task's file ends where the task did.
            trim(id, budget: budget, force: Self.isFinalState(event))
        } else {
            events[id, default: []].append(event)
            if !stalled.contains(id), let line {
                appendEventToDisk(id, line)
            }
        }
        if moved {
            persist(id)
        }
        wake(id)
        return event
    }

    func finish(_ id: TaskID, _ state: TaskState, message: String? = nil) {
        var payload: [String: JSONValue] = ["state": .string(state.rawValue)]
        if let message {
            payload["message"] = .string(message)
        }
        append(id, kind: TaskEvent.stateKind, payload: .object(payload))
    }

    /// The long poll behind every attach.
    func attach(
        _ id: TaskID,
        as operation: AppOperation,
        afterSeq: EventSeq,
        waitMilliseconds: Int,
    ) async throws -> TaskEventBatch {
        guard let record = records[id] else { throw ApelinError(.notFound, "This task could not be found.") }
        guard record.kind.attachOperation == operation else {
            throw ApelinError(.badRequest, "task \(id) is read with \(record.kind.attachOperation.rawValue)")
        }
        if pending(id, afterSeq).isEmpty, !record.state.isTerminal, waitMilliseconds > 0 {
            let wait = min(waitMilliseconds, Self.maximumWaitMilliseconds)
            let token = UUID()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[id, default: [:]][token] = continuation
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                    self.timeOut(id, token)
                }
            }
        }
        let current = records[id] ?? record
        var batch = pending(id, afterSeq)
        // A cursor older than what the log still holds is told so first, at
        // the number its events continue from: what follows is a tail, not the
        // whole screen.
        let floor = histories[id]?.base ?? 0
        if floor > 0, afterSeq.rawValue < floor {
            if batch.count >= Self.maximumBatchEvents {
                batch.removeLast()
            }
            batch.insert(trimmingMarker(id, through: floor, time: current.updatedAt), at: 0)
        }
        let last = batch.last?.seq ?? max(afterSeq, .start)
        return TaskEventBatch(
            taskID: id,
            events: batch,
            state: current.state,
            lastSeq: last,
            finished: current.state.isTerminal && last >= current.lastSeq,
            // A bounded log is a terminal's, whose shell writes on while it is
            // read: the batch names where the history ended when it was taken,
            // so a reader can finish catching up. Every other task is read to
            // its end as it always was.
            snapshotLastSeq: budgets[id] != nil ? current.lastSeq : nil,
        )
    }

    /// The newest event of `kind` whose payload has `field` equal to `value`,
    /// searched over the whole log rather than one attach batch.
    func lastEvent(_ id: TaskID, kind: String, field: String, equals value: String) -> TaskEvent? {
        events[id]?.last { $0.kind == kind && $0.payload?[field]?.stringValue == value }
    }

    /// The newest event of `kind`, searched over the whole log.
    func lastEvent(_ id: TaskID, kind: String) -> TaskEvent? {
        events[id]?.last { $0.kind == kind }
    }

    /// Every task of `kind`, finished or not, in no order.
    func records(kind: TaskKind) -> [Record] {
        records.values.filter { $0.kind == kind }
    }

    /// Marks the cancel; the caller tells the owning worker. A task with no
    /// worker to stop it ends here.
    func requestCancel(_ id: TaskID) throws -> Record {
        guard var record = records[id] else { throw ApelinError(.notFound, "This task could not be found.") }
        guard !record.state.isTerminal else { return record }
        record.cancelRequested = true
        records[id] = record
        persist(id)
        return record
    }

    /// Tasks a worker served when it went away end as failed.
    func ownerExited(role: WorkerRole, key: String?) {
        for record in records.values where record.owner == role && record.ownerKey == key && !record.state.isTerminal {
            finish(record.id, record.cancelRequested ? .cancelled : .failed, message: "The background process for this task stopped.")
        }
    }

    func hasActiveTask(owner role: WorkerRole, key: String?) -> Bool {
        records.values.contains { $0.owner == role && $0.ownerKey == key && !$0.state.isTerminal }
    }

    var activeCount: Int {
        records.values.filter { !$0.state.isTerminal }.count
    }

    /// Active tasks by kind, for the work report.
    var activeByKind: [String: Int] {
        records.values.filter { !$0.state.isTerminal }.reduce(into: [:]) { $0[$1.kind.rawValue, default: 0] += 1 }
    }

    // MARK: Private

    /// Removes, records and logs both, every finished agent task a newer
    /// task of the same session supersedes, of `session` or of every one.
    /// Each reopen of a session starts a task that replays its whole history,
    /// and `load` reads every log back into memory before the host answers
    /// anything: a conversation reopened ten times left ten copies, 69 MB
    /// read at each start. Only a session's newest task is ever read again
    /// (`AgentConversationList`), so it is kept, finished or not, and so is
    /// every task still running.
    private func dropSupersededAgentTasks(of session: String? = nil) {
        var bySession: [String: [Record]] = [:]
        for record in records.values where record.kind == .agent {
            guard let key = record.ownerKey, session == nil || key == session else { continue }
            bySession[key, default: []].append(record)
        }
        for tasks in bySession.values where tasks.count > 1 {
            let order = { (record: Record) in (record.createdAt, record.lastSeq.rawValue, record.id.rawValue) }
            let newest = tasks.max { order($0) < order($1) }
            for record in tasks where record.id != newest?.id && record.state.isTerminal {
                records.removeValue(forKey: record.id)
                events.removeValue(forKey: record.id)
                histories.removeValue(forKey: record.id)
                budgets.removeValue(forKey: record.id)
                trimWaits.removeValue(forKey: record.id)
                stalled.remove(record.id)
                unlink(eventsURL(record.id).path)
                unlink(recordURL(record.id).path)
            }
        }
    }

    private func pending(_ id: TaskID, _ afterSeq: EventSeq) -> [TaskEvent] {
        let all = events[id] ?? []
        let base = histories[id]?.base ?? 0
        // The events kept are numbered base+1 … base+count with no gaps, so
        // index = seq - base - 1. A cursor below the first is read from it.
        let read = afterSeq.rawValue > base ? afterSeq.rawValue - base : 0
        let start = Int(min(UInt64(all.count), read))
        return Array(all[start...].prefix(Self.maximumBatchEvents))
    }

    /// Drops the oldest whole events until the log is inside its budget again.
    /// Memory is bounded first and always — an attach is told where the kept
    /// events start — and the log on disk follows as soon as it can be written:
    /// a rewrite that fails stops the file from being appended to, so a folder
    /// that cannot be written does not let one log grow without bound, and the
    /// rewrite is tried again a thousand events along. The final `state` is
    /// never dropped, so a finished task always replays an end; a `state` line
    /// from earlier in the task's life is history like any other event.
    private func trim(
        _ id: TaskID,
        budget: HistoryBudget,
        reserve: (raw: Int, stored: Int, events: Int) = (0, 0, 0),
        force: Bool = false,
    ) {
        guard var state = histories[id], let log = events[id] else { return }
        // `reserve` is what is about to be added, so a log with room for what it
        // holds but not for the next event makes room now rather than after the
        // file has already taken it.
        let over = state.raw + reserve.raw > budget.rawBytes
            || state.stored + reserve.stored > budget.storedBytes
            || log.count + reserve.events > budget.events
        guard over || force else { return }
        let rawTarget = budget.rawBytes * 3 / 4
        let storedTarget = budget.storedBytes * 3 / 4
        let eventTarget = budget.events * 3 / 4
        // Only a log over its budget is cut back, and then to three quarters of
        // it, so a rewrite happens once per quarter rather than once per event.
        // A write-back at the task's end drops nothing.
        var index = 0
        if over {
            while index < log.count, !Self.isFinalState(log[index]),
                  state.raw + reserve.raw > rawTarget || state.stored + reserve.stored > storedTarget
                  || log.count - index + reserve.events > eventTarget
            {
                let cost = Self.cost(of: log[index])
                state.raw = max(0, state.raw - cost.raw)
                state.stored = max(0, state.stored - cost.stored)
                index += 1
            }
        }
        guard index > 0 || force else { return }
        let kept = Array(log[index...])
        state.base += UInt64(index)
        histories[id] = state
        events[id] = kept

        // The file, next: a rewrite that failed last time waits a thousand
        // events before it is tried again — and meanwhile nothing is appended
        // to it, so it stays at the size it had when the budget was reached. A
        // task's last event does not wait.
        if !force, let wait = trimWaits[id], wait > 0 {
            return
        }
        let rewritten = rewriteEvents(id, kept, budget: budget)
        if rewritten {
            trimWaits[id] = nil
            stalled.remove(id)
        } else {
            NSLog("apelind-session: task %@'s log cannot be written back; it is held at its size", id.rawValue)
            stalled.insert(id)
            trimWaits[id] = Self.trimRetryEvents
        }
        if var record = records[id] {
            // The file's own head is the floor until the file is written back;
            // then the record says which events are gone. A held log's events
            // are only ever in memory, and the next read takes the file's own
            // numbering anyway.
            if rewritten {
                record.historyFloor = EventSeq(state.base)
            }
            record.historyStalled = stalled.contains(id) ? true : nil
            records[id] = record
            persist(id)
        }
    }

    /// The line an event takes in the log: its JSON and a newline.
    static func encoded(_ event: TaskEvent) -> Data? {
        guard var line = try? JSONCoding.encode(event) else { return nil }
        line.append(0x0A)
        return line
    }

    /// The bytes the shell wrote, read back from the base64 an output event
    /// carries. Every other kind wrote none.
    static func rawBytes(of event: TaskEvent) -> Int {
        guard case let .object(fields)? = event.payload,
              let base64 = fields["base64"]?.stringValue?.utf8.count
        else { return 0 }
        return base64 / 4 * 3
    }

    /// What an event costs its task's history, in the log's own bytes: the line
    /// `encoded` writes, escapes and newline included — text full of control
    /// characters costs what it really takes, not what it would as plain UTF-8.
    static func cost(of event: TaskEvent) -> (raw: Int, stored: Int) {
        (rawBytes(of: event), encoded(event)?.count ?? 0)
    }

    /// What a log read back from disk still holds.
    private static func history(of events: [TaskEvent], base: UInt64) -> HistoryState {
        var state = HistoryState(base: base)
        for event in events {
            let cost = cost(of: event)
            state.raw += cost.raw
            state.stored += cost.stored
        }
        return state
    }

    /// The event an attach whose cursor is older than the log replays first.
    /// It is never written to the log: every such attach gets it again, and the
    /// numbers the events continue from do not change.
    private func trimmingMarker(_ id: TaskID, through floor: UInt64, time: Date) -> TaskEvent {
        let held = stalled.contains(id)
        var payload: [String: JSONValue] = [
            "throughSeq": .number(Double(floor)),
            "reason": .string(
                held
                    ? "the terminal's earlier output was trimmed, and its log cannot be written back"
                    : "the terminal's earlier output was trimmed",
            ),
        ]
        if let budget = budgets[id] {
            payload["limit"] = .number(Double(budget.rawBytes))
        }
        if held {
            payload["stalled"] = .bool(true)
        }
        return TaskEvent(seq: EventSeq(floor), kind: Self.trimmedKind, time: time, payload: .object(payload))
    }

    private func wake(_ id: TaskID) {
        let waiting = waiters.removeValue(forKey: id) ?? [:]
        waiting.values.forEach { $0.resume() }
    }

    private func timeOut(_ id: TaskID, _ token: UUID) {
        waiters[id]?.removeValue(forKey: token)?.resume()
    }

    private func recordURL(_ id: TaskID) -> URL {
        directory.appendingPathComponent("\(id.rawValue).json")
    }

    private func eventsURL(_ id: TaskID) -> URL {
        directory.appendingPathComponent("\(id.rawValue).events.jsonl")
    }

    private func persist(_ id: TaskID) {
        guard let record = records[id], let data = try? JSONCoding.encode(record) else { return }
        try? data.write(to: recordURL(id), options: .atomic)
    }

    private func appendEventToDisk(_ id: TaskID, _ line: Data) {
        let url = eventsURL(id)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Writes what the log still holds: trimming drops the head of the file as
    /// it drops the head of the array, so the disk is bounded too. A line that
    /// will not encode is left out, and the next read fills its number with an
    /// `unreadable` event like any other gap.
    /// Writes what the log still holds, answering whether the file now holds
    /// all of it: a line larger than the whole budget is left out — no log can
    /// hold it — and the answer is no, so the file is known to be behind. The
    /// write itself is atomic; a failure of it answers no too.
    private func rewriteEvents(_ id: TaskID, _ log: [TaskEvent], budget: HistoryBudget) -> Bool {
        var data = Data()
        var complete = true
        for event in log {
            guard let line = Self.encoded(event) else {
                complete = false
                continue
            }
            guard line.count <= budget.storedBytes else {
                complete = false
                continue
            }
            data.append(line)
        }
        do {
            try data.write(to: eventsURL(id), options: .atomic)
            return complete
        } catch {
            NSLog("apelind-session: %@: %@", eventsURL(id).lastPathComponent, "\(error)")
            return false
        }
    }

    /// What stands in for a line of the log this build cannot read.
    static let unreadableKind = "unreadable"

    static func isFinalState(_ event: TaskEvent) -> Bool {
        event.kind == TaskEvent.stateKind
            && event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:))?.isTerminal == true
    }

    /// What ends the replay of a finished task whose final `state` line
    /// cannot be read: an `unreadable` event for each whole line skipped
    /// after the last that read, then a `state` with the record's own state,
    /// appended to the log. The skipped lines stay in the file, so the next
    /// load fills the same numbers and reads this `state` after them.
    private func closingEvents(
        _ record: Record,
        after replay: [TaskEvent],
        skipped: UInt64,
        floor: UInt64,
    ) -> [TaskEvent] {
        var closing: [TaskEvent] = []
        var seq = UInt64(replay.count) + floor
        for _ in 0 ..< skipped {
            seq += 1
            closing.append(Self.unreadable(EventSeq(seq), time: record.updatedAt))
        }
        let state = TaskEvent(
            seq: EventSeq(seq + 1),
            kind: TaskEvent.stateKind,
            time: record.updatedAt,
            payload: .object([
                "state": .string(record.state.rawValue),
                "message": .string("The task ended, but its final details could not be read."),
            ]),
        )
        if let line = Self.encoded(state) {
            appendEventToDisk(record.id, line)
        }
        closing.append(state)
        return closing
    }

    private static func unreadable(_ seq: EventSeq, time: Date) -> TaskEvent {
        TaskEvent(
            seq: seq,
            kind: unreadableKind,
            time: time,
            payload: .object(["message": .string("this line of the task's log could not be read")]),
        )
    }

    /// The events in the log, numbered 1…n with no gap, as `pending` and
    /// every attach rely on, and how many whole lines past the last one that
    /// read were skipped.
    ///
    /// Only a torn tail is cut off the file: a last fragment with no newline
    /// (the line a crash stopped writing) that does not decode or is out of
    /// order. Cutting it lets the next event appended start a line of its own
    /// instead of joining the torn one and being lost with it at the next
    /// load; a last event that lost only its newline keeps its place and
    /// gets one.
    ///
    /// A line with its newline was written whole, so one that does not
    /// decode (a corrupted line, or a newer build's event shape met after a
    /// downgrade) stays in the file and reading goes on past it. Stopping
    /// there would drop the final `state` behind it, so the task would be
    /// resumed or interrupted over its real end, and the events appended
    /// after that, past the gap, would never be read back. Instead, when the
    /// next event that reads names a higher number, each number the skipped
    /// lines held is filled with an `unreadable` event: the numbering keeps
    /// no gap and an attach still reaches the final state. A jump larger
    /// than the skipped lines can account for makes that line a bad one too,
    /// and a number already read (appended after a bad last line, once that
    /// line reads again) is passed over.
    private func readEvents(
        _ id: TaskID,
        allowFloor: Bool,
        floorHint: UInt64,
    ) -> (events: [TaskEvent], skipped: UInt64, floor: UInt64) {
        let url = eventsURL(id)
        guard let data = try? Data(contentsOf: url) else { return ([], floorHint, floorHint) }
        let decoder = JSONCoding.decoder()
        var result: [TaskEvent] = []
        var skipped: UInt64 = 0
        // Where the kept events start. The record's floor is the hint, and the
        // log itself is the truth: the first event that reads names its own
        // number, and every whole line skipped before it held one of the
        // numbers in between — so a head that is trimmed, and one that is torn,
        // are both counted, and neither swallows the tail behind it. Only a
        // terminal's log starts past 1, so only there is this read at all.
        var floor: UInt64 = allowFloor ? floorHint : 0
        var derived = false
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 0x0A)
            let line = Data(data[start ..< (newline ?? data.endIndex)])
            let event = try? decoder.decode(TaskEvent.self, from: line)
            if allowFloor, !derived, result.isEmpty, let event, event.seq.rawValue > skipped {
                floor = event.seq.rawValue - skipped - 1
                derived = true
            }
            let expected = UInt64(result.count) + floor + 1
            if let event, event.seq.rawValue >= expected, event.seq.rawValue - expected <= skipped {
                while UInt64(result.count) + floor + 1 < event.seq.rawValue {
                    let number = UInt64(result.count) + floor + 1
                    result.append(Self.unreadable(EventSeq(number), time: event.time))
                }
                result.append(event)
                skipped = 0
                if newline == nil, let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(Data([0x0A]))
                    try? handle.close()
                }
            } else if newline == nil {
                truncate(url.path, off_t(start - data.startIndex))
            } else if (event?.seq.rawValue ?? .max) > expected {
                skipped += 1
            }
            guard let newline else { break }
            start = data.index(after: newline)
        }
        return (result, skipped, floor)
    }
}

/// Worker events, applied one at a time in the order the channel delivered
/// them. A task per event would let a later one overtake an earlier one that
/// awaits something first (a build's `artifact` is recorded before it is
/// appended), and once the final `state` is in, the registry drops whatever
/// arrives after it.
final class TaskEventFeed<Item: Sendable>: Sendable {
    private let continuation: AsyncStream<Item>.Continuation

    init(_ apply: @escaping @Sendable (Item) async -> Void) {
        var continuation: AsyncStream<Item>.Continuation!
        let stream = AsyncStream<Item>(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        Task {
            for await item in stream {
                await apply(item)
            }
        }
    }

    func send(_ item: Item) {
        continuation.yield(item)
    }

    deinit {
        continuation.finish()
    }
}
