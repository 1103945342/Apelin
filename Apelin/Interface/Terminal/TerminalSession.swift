import ApelinCore
import ApelinProtocol
import Foundation
import GhosttyTerminal

/// One shell: the task the host owns, the socket the user types into, and the
/// numbered events that carry everything the shell wrote.
///
/// The session outlives the page that shows it. Closing the page detaches the
/// surface — the poll stops, the keyboard socket closes — and the shell keeps
/// running; opening the terminal again replays the task's own bounded history
/// into a fresh surface, so the screen comes back rather than a blank grid.
///
/// Output reaches the emulator from the event log and from nowhere else. The
/// host also copies live output to the socket, but `inputOnly` turns that off,
/// and even if it did not, feeding it would race the replay; the events are the
/// one ordered account of what the shell wrote. Keys stay closed until the
/// replay has drained — the log can be longer than one answer — because a
/// terminal answering a query out of replayed history must not reach the shell
/// as if the user had typed it.
///
/// A task the host no longer has — after a restart it is `interrupted` — is
/// never offered as something to resume, and never quietly replaced: the page
/// says it ended and leaves the next shell to the reader.
@MainActor
final class TerminalSession {
    enum Phase: Equatable {
        /// Opened for the first time, but not yet asked for a shell.
        case idle
        /// Waiting for `ptyOpen`.
        case opening
        /// A shell this session knows is being reattached to, or the attach is
        /// being retried after a failure that may pass.
        case reconnecting
        case live
        case ended(TerminalEnding)
        case failed(String)
    }

    enum TerminalEnding: Equatable {
        case exited(status: Int32?, signal: Int32?)
        /// Closed by the reader from this app.
        case stopped
        /// The host has no such task any more (restart, expiry).
        case noLongerAvailable
    }

    /// A replay the surface did not take: unparsed output waiting with no
    /// surface to take it, or a parser that stayed behind long enough that the
    /// page is better off with a fresh surface than with more queued bytes.
    private enum TerminalReplayError: Error {
        case surfaceNotParsed
        case backlogStuck
        /// The replay did not reach the end the host named within the page or
        /// time bound: a partial replay is not a screen, and the keys stay
        /// closed rather than answering history as live input.
        case catchUpTimedOut
    }

    /// How many unparsed bytes may queue before the feeder waits for the
    /// parser. `receive` only enqueues, and with a surface attached the queue
    /// has no bound of its own.
    static let backlogHighWater = 256 * 1024

    let id: UUID
    let identity: TerminalIdentity
    let dataRoot: URL

    /// What a record may keep about this place (`TerminalTarget`), and the
    /// folder the shell starts in this run.
    var target: TerminalTarget { identity.target }
    var startDirectory: URL { identity.directory }

    private(set) var taskID: TaskID?
    private(set) var sessionID: String?
    private(set) var phase: Phase = .idle
    private(set) var title: String
    private(set) var startedDirectory: String?
    /// The host dropped older output for this session; what was drawn before
    /// is not the whole screen any more.
    private(set) var historyTrimmed = false

    /// Where the emulator's bytes go, and when they may.
    let input = TerminalInputRouter()
    /// `ptyResize` from the library's resize callback.
    let resize = TerminalResizeRelay()

    /// The page redraws from this.
    var onChange: (() -> Void)?
    /// The surface must be rebuilt: the log no longer holds what it drew.
    var onTruncation: (() -> Void)?
    /// A record to write, or nil to forget this session's.
    var onRecordChange: ((TerminalSessionRecord?) -> Void)?

    private let openedAt: Date
    private var attachment = TerminalAttachment()
    private var openTask: Task<Void, Error>?
    private var attachTask: Task<Void, Never>?
    private var attachToken = 0
    private var emulator: InMemoryTerminalSession?
    private var exitStatus: Int32?
    private var exitSignal: Int32?
    private var ending: TerminalEnding?
    private var failureMessage: String?
    /// A terminal state seen inside a batch, with the attachment generation it
    /// was seen in: acted on only once the batch call has returned, and only if
    /// that generation still owns the session.
    private var pendingTerminalState: (state: TaskState, token: Int)?
    /// Output decoded from the batch being applied, fed to the emulator only
    /// after the whole batch's numbering has been settled — a truncation in the
    /// middle of a batch means the bytes after it never belong to this surface.
    private var pendingFeeds: [Data] = []
    /// Whether this attachment's surface has been seen attached: ghostty
    /// buffers output before then, and drops the oldest past 1 MiB. The latch
    /// records it only for the generation that saw it.
    private var surfaceLatch = TerminalSurfaceLatch()
    /// How many events of one batch are fed before the parser is allowed to
    /// catch up: `receive` only enqueues.
    static let eventsPerSlice = 64

    init(
        identity: TerminalIdentity,
        dataRoot: URL,
        record: TerminalSessionRecord? = nil
    ) {
        id = record?.id ?? UUID()
        self.identity = identity
        self.dataRoot = dataRoot
        taskID = record.map { TaskID(rawValue: $0.taskID) }
        sessionID = record?.sessionID
        title = record?.title ?? identity.displayName
        openedAt = record?.openedAt ?? Date()
        if record != nil {
            // A record says the host had this task when it was written; whether
            // it still does is the attach's to say, so nothing here claims it.
            phase = .reconnecting
        }
    }

    /// What this session would write down now, or nil when nothing about it can
    /// be reopened — a folder outside Apelin's own storage is kept by this run
    /// alone.
    var record: TerminalSessionRecord? {
        guard target.isRestorable, let taskID else { return nil }
        return TerminalSessionRecord(
            id: id,
            target: target,
            taskID: taskID.rawValue,
            sessionID: sessionID,
            title: title,
            openedAt: openedAt
        )
    }

    var isLive: Bool {
        phase == .live
    }

    var isFinished: Bool {
        if case .ended = phase { return true }
        return false
    }

    /// Whether the reader may forget this session from the list: only a
    /// terminal that ended. A session that is running, still connecting or
    /// failed keeps its place — the host may still have a shell for it.
    var isRemovable: Bool {
        isFinished
    }

    /// The list's one-word state, which `TerminalSessionsListController` draws
    /// as the row's subtitle.
    var listStatus: TerminalSessionListEntry.Status {
        switch phase {
        case .live:
            return .running
        case .idle, .opening, .reconnecting:
            return .connecting
        case .ended:
            return .ended
        case .failed:
            return .unavailable
        }
    }

    // MARK: - Attaching

    /// Shows this session on a fresh surface: opens the shell when there is
    /// none, then replays the task's history into `emulator` and follows it.
    func attach(emulator newEmulator: InMemoryTerminalSession, columns: Int, rows: Int) {
        attachToken += 1
        let token = attachToken
        attachTask?.cancel()
        attachTask = nil
        emulator = newEmulator
        attachment.begin(openShell: taskID == nil)
        input.setAccepting(false)
        input.beginReplay()
        refreshPhase()
        onChange?()
        attachTask = Task { [weak self] in
            await self?.start(token: token, columns: columns, rows: rows)
        }
    }

    /// The page went away (closed, or the app left the foreground). The shell
    /// stays: the poll stops and the socket closes, and a later attach replays
    /// the history into a new surface. A shell still being opened is kept and
    /// recorded, not killed.
    func detach() {
        attachment.detach()
        attachToken += 1
        attachTask?.cancel()
        attachTask = nil
        emulator = nil
        input.setAccepting(false)
        input.endReplay()
        input.attach(nil)
        resize.reset()
        refreshPhase()
        onChange?()
    }

    /// Asks the host to end the shell. The session is finished here at once;
    /// the close itself needs no answer. A shell still being opened is closed
    /// the moment it exists rather than left behind.
    func terminate() {
        attachment.terminate()
        attachToken += 1
        attachTask?.cancel()
        attachTask = nil
        let closing = sessionID
        finish(ending: .stopped)
        if let closing {
            Task.detached {
                try? await ApelinService.app.ptyClose(sessionID: closing)
            }
        }
    }

    // MARK: - Attach loop

    /// One attachment, retried while the failures may pass. Each attempt starts
    /// from the cursor the last one reached, so a reattach after a dropped
    /// connection neither repeats nor skips an event.
    private func start(token: Int, columns: Int, rows: Int) async {
        var pause: UInt64 = 1_000_000_000
        while !Task.isCancelled, token == attachToken, !isFinished {
            // Every attempt starts with the keyboard closed and the replay gate
            // down: a reconnect must not leave the router open while the page
            // says Reconnecting.
            TerminalAttemptGate.reopen(input)
            surfaceLatch = TerminalSurfaceLatch()
            do {
                try await attachOnce(token: token, columns: columns, rows: rows)
                return
            } catch {
                guard token == attachToken, !Task.isCancelled else { return }
                if error is CancellationError {
                    return
                }
                // A failure is a reconnect the reader will see: the gate closes
                // here, before the notification and before any backoff sleep,
                // so no keystroke or engine writeback goes out while the page
                // says Reconnecting.
                TerminalAttemptGate.reopen(input)
                if isHostLost(error) {
                    attachment.hostLost()
                    finish(ending: .noLongerAvailable)
                    return
                }
                if error is TerminalReplayError {
                    // Output this surface did not take: whoever is ahead — the
                    // page, or a live connection that failed mid-feed — another
                    // replay into the same surface would either duplicate what
                    // it took or skip what it did not. A fresh surface replays
                    // from the resume point instead, a bounded number of times;
                    // past that the page is told, with the keys still closed.
                    if !attachment.replayRecoveryAllowed() {
                        failureMessage = String(localized: "The terminal could not replay this session.")
                        refreshPhase()
                        releaseSurface()
                        onChange?()
                        return
                    }
                    readyForRebuild()
                    return
                }
                failureMessage = error.readableMessage
                if !attachment.transientFailure() {
                    // Too many failures in a row: the page says so and offers
                    // Try Again, and the shell is left as it is.
                    refreshPhase()
                    releaseSurface()
                    onChange?()
                    return
                }
                refreshPhase()
                onChange?()
                try? await Task.sleep(nanoseconds: pause)
                pause = min(pause * 2, 8_000_000_000)
            }
        }
    }

    private func attachOnce(token: Int, columns: Int, rows: Int) async throws {
        try await ensureOpen(columns: columns, rows: rows)
        guard token == attachToken else { return }
        if isFinished {
            return
        }
        if !attachment.wantsSurface {
            // The page went while the shell was starting. The shell is kept —
            // and its record with it — and nothing is polled until a page asks
            // again.
            releaseSurface()
            return
        }
        guard let taskID else { return }
        // A task that has already finished may refuse a descriptor; its events
        // are still readable, and the exit reason is worth showing. So the
        // read-only attach is a fallback, never a lost batch.
        var batch: TaskEventBatch
        var descriptors: [OwnedDescriptor] = []
        do {
            (batch, descriptors) = try await ApelinService.app.sendReturningDescriptors(
                PtyAttachRequest(
                    taskID: taskID,
                    afterSeq: EventSeq(attachment.cursor),
                    waitMilliseconds: 0,
                    wantsDescriptor: true,
                    inputOnly: true
                )
            )
        } catch {
            guard token == attachToken else { return }
            batch = try await ApelinService.app.ptyAttach(
                taskID: taskID,
                afterSeq: EventSeq(attachment.cursor),
                waitMilliseconds: 0
            )
        }
        guard token == attachToken else {
            descriptors.forEach { $0.close() }
            return
        }
        if let descriptor = descriptors.first {
            let socket = TerminalInputSocket()
            socket.adopt(descriptor.take())
            input.attach { data in socket.write(data) }
        }
        attachment.replaying()
        // The history's end when the host took this batch: a fixed number a
        // shell that keeps writing can still reach.
        attachment.replayEnding(at: batch.snapshotLastSeq?.rawValue)
        refreshPhase()
        let first = try await ingest(batch, token: token)
        guard token == attachToken else { return }
        handle(first, batch: batch, token: token)
        guard token == attachToken else { return }
        if isFinished || attachment.phase == .reconnecting {
            // A rebuild was asked for, or the task is done; either way this
            // surface sees nothing more.
            return
        }
        // The history may be longer than one answer. Drain it before keys are
        // accepted: a query answered out of replayed output must not reach the
        // shell as live input.
        try await drainHistory(token: token, taskID: taskID)
        guard token == attachToken else { return }
        if isFinished || attachment.phase == .reconnecting {
            return
        }
        if !attachment.wantsSurface {
            releaseSurface()
            return
        }
        if let emulator {
            try await waitForParsedReplay(emulator, token: token)
        }
        guard token == attachToken else { return }
        if !attachment.wantsSurface {
            releaseSurface()
            return
        }
        attachment.recovered()
        attachment.caughtUp()
        // The replay window closes before the keys open: without this the
        // router still believes the history is being replayed and drops every
        // keystroke while the page looks live.
        input.endReplay()
        input.setAccepting(true)
        refreshPhase()
        onChange?()
        try await follow(token: token, taskID: taskID)
    }

    /// Zero-wait attaches until the replay has reached the end the host named
    /// in the first batch — or, for a host that names none, until it answers
    /// nothing at all. Only then may the surface take keys: a query answered
    /// out of replayed output must not reach the shell as live input.
    ///
    /// A shell that never stops writing never gives an empty answer, which is
    /// why the fixed end matters; the page and time bounds are the last resort
    /// for a host that cannot name one, and they mark the history trimmed
    /// rather than presenting a partial replay as the whole screen.
    private func drainHistory(token: Int, taskID: TaskID) async throws {
        var pages = 0
        let started = Date()
        while !Task.isCancelled, token == attachToken {
            if attachment.hasReachedReplayEnd {
                return
            }
            pages += 1
            if pages > 512 || Date().timeIntervalSince(started) > 10 {
                // A replay that cannot reach the end the host named is not a
                // screen: unlocking the keys here would answer replayed history
                // as live input. The attempt fails, and the page may rebuild.
                throw TerminalReplayError.catchUpTimedOut
            }
            let more = try await ApelinService.app.ptyAttach(
                taskID: taskID,
                afterSeq: EventSeq(attachment.cursor),
                waitMilliseconds: 0
            )
            guard token == attachToken else { return }
            if more.events.isEmpty {
                if more.finished {
                    finish(ending: ending(for: more.state))
                    return
                }
                guard attachment.catchUpEnd != nil else {
                    // No end was named: nothing waiting is the only boundary
                    // this host offers.
                    return
                }
                // The batch was taken before the host had read up to its own
                // snapshot; give it a turn rather than spinning.
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            let outcome = try await ingest(more, token: token)
            guard token == attachToken else { return }
            handle(outcome, batch: more, token: token)
            if isFinished || attachment.phase == .reconnecting {
                return
            }
        }
    }

    /// The long poll: the numbered events after the last one applied, in order,
    /// until the task is finished or the page moves on. A failure is thrown to
    /// the attach loop, which retries from the same cursor.
    private func follow(token: Int, taskID: TaskID) async throws {
        while !Task.isCancelled, token == attachToken, !isFinished {
            let batch = try await ApelinService.app.ptyAttach(
                taskID: taskID,
                afterSeq: EventSeq(attachment.cursor)
            )
            guard token == attachToken else { return }
            attachment.recovered()
            let outcome = try await ingest(batch, token: token)
            guard token == attachToken else { return }
            handle(outcome, batch: batch, token: token)
            if isFinished || attachment.phase == .reconnecting {
                return
            }
            if let emulator {
                try await relieveBacklog(emulator, token: token)
            }
            if !batch.events.isEmpty {
                onChange?()
            }
        }
    }

    /// The reader asked to try again after a failure: a fresh budget and a
    /// replay from the log's beginning, then a fresh surface. The budget is
    /// never reset by an automatic rebuild, so a surface that will not take a
    /// replay cannot loop for ever.
    func allowRetry() {
        attachment.restart()
        refreshPhase()
        onChange?()
    }

    // MARK: - Events

    /// Feeds one batch into the surface in bounded slices of events and of
    /// bytes, letting the parser catch up between them: `receive` only enqueues,
    /// and before the surface attaches ghostty keeps at most 1 MiB. The
    /// attachment owns the numbering and the truncation; this only decides what
    /// reaches the emulator and when.
    ///
    /// Every await is followed by a generation check: a page that left, or a
    /// rebuild that replaced this attachment, must not have old bytes fed or an
    /// old task's end acted on.
    private func ingest(_ batch: TaskEventBatch, token: Int) async throws -> TerminalAttachment.BatchOutcome {
        let events = batch.events
        let items = batchItems(events)
        let slices = (items.count + Self.eventsPerSlice - 1) / Self.eventsPerSlice
        return try await TerminalIngestLoop.run(
            slices: slices,
            isCurrent: { token == attachToken && !Task.isCancelled },
            applySlice: { slice in
                let start = slice * Self.eventsPerSlice
                let end = min(start + Self.eventsPerSlice, items.count)
                let chunk = Array(items[start ..< end])
                self.pendingFeeds.removeAll(keepingCapacity: true)
                let outcome = self.attachment.runBatch(
                    items: chunk,
                    isCurrent: { token == attachToken },
                    applyAtIndex: { offset in
                        self.apply(events[start + offset], token: token)
                    }
                )
                if outcome != .completed {
                    self.pendingFeeds.removeAll()
                }
                return outcome
            },
            feedSlice: {
                try await self.feedPending(token: token)
            },
            breathe: {
                if let emulator = self.emulator {
                    try await self.relieveBacklog(emulator, token: token)
                }
                // A first batch of a busy shell should not hold the main thread
                // for the whole of it.
                await Task.yield()
            }
        )
    }

    /// Feeds the bytes the slice decoded, one `TerminalFeedPlan` piece at a
    /// time, waiting for the surface first and for room in its queue before
    /// each.
    private func feedPending(token: Int) async throws {
        let feeds = pendingFeeds
        pendingFeeds.removeAll()
        for data in feeds {
            for range in TerminalFeedPlan.chunks(of: data) {
                guard token == attachToken, !Task.isCancelled else { throw CancellationError() }
                try await feed(data.subdata(in: range), token: token)
            }
        }
    }

    /// One chunk into the emulator, once the surface exists and its queue has
    /// room: ghostty buffers before the surface attaches (dropping the oldest
    /// past 1 MiB), and with a surface the queue has no bound of its own.
    private func feed(_ chunk: Data, token: Int) async throws {
        guard token == attachToken, let emulator else { return }
        if !surfaceLatch.ready {
            try await waitForSurface(emulator, token: token)
            // A wait for the surface is a suspension like any other: if another
            // attachment took over while this one slept, the surface that just
            // answered is not this generation's, and marking it ready here
            // would let the next generation skip its own check.
            guard token == attachToken, !Task.isCancelled else { throw CancellationError() }
            guard surfaceLatch.markReady(token: token, current: attachToken) else {
                throw CancellationError()
            }
        }
        var waited = 0
        while emulator.pendingOutputByteCount + chunk.count > Self.backlogHighWater {
            guard token == attachToken, !Task.isCancelled else { throw CancellationError() }
            if waited >= 500 {
                throw TerminalReplayError.backlogStuck
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        guard token == attachToken else { throw CancellationError() }
        emulator.receive(chunk)
    }

    /// The view is added before the attach, but the library builds the surface
    /// on its own turn. Nothing is fed before it exists, because bytes sent
    /// earlier are buffered by ghostty and the oldest are dropped past 1 MiB —
    /// a loss that no later `waitForPendingOutput` can undo.
    private func waitForSurface(_ emulator: InMemoryTerminalSession, token: Int) async throws {
        var waited = 0
        while emulator.readViewportText() == nil {
            guard token == attachToken, !Task.isCancelled else { throw CancellationError() }
            if waited >= 200 {
                throw TerminalReplayError.surfaceNotParsed
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
    }

    private func handle(
        _ outcome: TerminalAttachment.BatchOutcome,
        batch: TaskEventBatch,
        token: Int
    ) {
        guard token == attachToken else { return }
        switch outcome {
        case .rebuildRequested:
            // A rebuild replaces the surface and the cursor; the rest of this
            // batch belongs to a generation that no longer exists, so it is
            // neither fed nor allowed to move the new cursor.
            historyTrimmed = true
            readyForRebuild()
        case .superseded:
            return
        case .completed:
            if let pending = pendingTerminalState, pending.token == token {
                pendingTerminalState = nil
                finish(ending: ending(for: pending.state))
                return
            }
            if batch.finished, !isFinished {
                finish(ending: ending(for: batch.state))
            }
        }
    }

    /// Asks the page for a fresh surface: this one can take nothing more, and
    /// the keys stay closed until a replay has been parsed into its successor.
    private func readyForRebuild() {
        emulator = nil
        pendingFeeds.removeAll()
        input.setAccepting(false)
        refreshPhase()
        onTruncation?()
    }

    private func batchItems(_ events: [TaskEvent]) -> [TerminalAttachment.BatchItem] {
        events.map { event in
            guard event.kind == "outputTruncated" else {
                return TerminalAttachment.BatchItem(seq: event.seq.rawValue)
            }
            var throughSeq: UInt64?
            if case let .outputTruncated(value)? = TerminalWireEvent.actions(
                kind: event.kind,
                payload: event.payload
            ).first {
                throughSeq = value
            }
            return TerminalAttachment.BatchItem(
                seq: event.seq.rawValue,
                truncation: true,
                throughSeq: throughSeq
            )
        }
    }

    /// One event's actions. It feeds the emulator and records what the page
    /// draws; it never touches the attachment, which `runBatch` is modifying
    /// while this runs, and never ends the session directly — a terminal state
    /// is acted on once the batch call has returned.
    private func apply(_ event: TaskEvent, token: Int) {
        for action in TerminalWireEvent.actions(kind: event.kind, payload: event.payload) {
            switch action {
            case let .started(directory, shell):
                if let directory {
                    startedDirectory = directory
                    title = Self.title(for: directory, shell: shell, fallback: identity.displayName)
                    remember()
                }
            case let .output(data):
                // Feeds wait for the whole slice's numbering: a truncation
                // later in the slice means these bytes never reach this surface.
                pendingFeeds.append(data)
            case .outputTruncated:
                // The rebuild decision is the attachment's; this only records
                // that what is on screen is a tail.
                historyTrimmed = true
            case let .exited(status, signal):
                exitStatus = status
                exitSignal = signal
            case let .state(raw):
                guard let state = TaskState(rawValue: raw), state.isTerminal else { continue }
                pendingTerminalState = (state: state, token: token)
            }
        }
    }

    /// The replay is over only when ghostty says it has parsed everything fed
    /// so far — `waitForPendingOutput` true covers the replies that parsing
    /// produced — and the queue behind it has drained. False means the surface
    /// has not attached yet, which is a reason to wait, not to open the keys.
    private func waitForParsedReplay(_ emulator: InMemoryTerminalSession, token: Int) async throws {
        var spins = 0
        while !emulator.waitForPendingOutput() {
            guard token == attachToken, !Task.isCancelled else { throw CancellationError() }
            if spins >= 200 {
                throw TerminalReplayError.surfaceNotParsed
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            spins += 1
        }
        try await relieveBacklog(emulator, token: token)
    }

    /// Lets the parser catch up before more bytes are queued: `receive` only
    /// enqueues, and a queue with no bound is memory the app does not get back.
    private func relieveBacklog(_ emulator: InMemoryTerminalSession, token: Int) async throws {
        var waited = 0
        while emulator.pendingOutputByteCount > Self.backlogHighWater {
            guard token == attachToken, !Task.isCancelled else { throw CancellationError() }
            if waited >= 500 {
                throw TerminalReplayError.backlogStuck
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
    }

    // MARK: - Opening

    private func ensureOpen(columns: Int, rows: Int) async throws {
        if taskID != nil {
            return
        }
        if let openTask {
            // One open, however many attaches ask for it: a second shell would
            // be a shell nobody asked for.
            try await openTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { openTask = nil }
            try await performOpen(columns: columns, rows: rows)
        }
        openTask = task
        try await task.value
    }

    private func performOpen(columns: Int, rows: Int) async throws {
        phase = .opening
        onChange?()
        let opened = try await ApelinService.app.ptyOpen(openRequest(columns: columns, rows: rows))
        sessionID = opened.sessionID
        taskID = opened.task.taskID
        resize.configure(service: .app, sessionID: opened.sessionID)
        if attachment.shellOpened() == .close {
            // The reader ended the terminal while its shell was starting: the
            // shell exists now, so it is closed here rather than left behind.
            try? await ApelinService.app.ptyClose(sessionID: opened.sessionID)
            sessionID = nil
            taskID = nil
            finish(ending: .stopped)
            return
        }
        remember()
        refreshPhase()
        onChange?()
    }

    // MARK: - Ending

    private func isHostLost(_ error: Error) -> Bool {
        guard let apelin = error as? ApelinError else { return false }
        return apelin.code == .notFound
    }

    private func finish(ending: TerminalEnding) {
        self.ending = ending
        switch ending {
        case .noLongerAvailable:
            attachment.hostLost()
        case .exited, .stopped:
            attachment.ended()
        }
        input.setAccepting(false)
        input.endReplay()
        input.attach(nil)
        resize.reset()
        if let emulator {
            let runtime = UInt64(max(0, Date().timeIntervalSince(openedAt)) * 1000)
            emulator.finish(
                exitCode: exitCode(for: ending),
                runtimeMilliseconds: runtime
            )
        }
        emulator = nil
        attachTask = nil
        // A finished task is not something to attach to again, so its record
        // goes; the shell that replaces it writes its own.
        onRecordChange?(nil)
        refreshPhase()
        onChange?()
    }

    /// The surface is let go without touching the shell.
    private func releaseSurface() {
        emulator = nil
        input.setAccepting(false)
        input.endReplay()
        input.attach(nil)
        resize.reset()
        if attachment.phase != .failed, attachment.phase != .ended {
            attachment.detach()
        }
        refreshPhase()
        onChange?()
    }

    private func ending(for state: TaskState) -> TerminalEnding {
        switch state {
        case .interrupted:
            return .noLongerAvailable
        case .cancelled:
            return .stopped
        case .succeeded, .failed:
            return .exited(status: exitStatus, signal: exitSignal)
        case .queued, .running, .waitingForApproval:
            return .stopped
        }
    }

    private func exitCode(for ending: TerminalEnding) -> UInt32 {
        switch ending {
        case let .exited(status, signal):
            if let signal {
                return UInt32(128 + max(0, signal))
            }
            return UInt32(max(0, status ?? 0))
        case .stopped:
            return 129
        case .noLongerAvailable:
            return 0
        }
    }

    // MARK: - Phases

    private func refreshPhase() {
        switch attachment.phase {
        case .idle:
            phase = .idle
        case .opening:
            phase = .opening
        case .reconnecting, .catchingUp:
            phase = .reconnecting
        case .live:
            phase = .live
        case .ended:
            phase = .ended(ending ?? .stopped)
        case .failed:
            phase = .failed(failureMessage ?? String(localized: "The terminal is not available."))
        }
    }

    // MARK: - Helpers

    private func openRequest(columns: Int, rows: Int) -> PtyOpenRequest {
        // A project folder is named by the scope and a relative path; anything
        // else is an absolute folder for this run, which the host resolves.
        var workingDirectory: String?
        if target.projectID == nil {
            workingDirectory = startDirectory.path
        }
        return PtyOpenRequest(
            columns: columns,
            rows: rows,
            projectID: target.projectID,
            initialInput: nil,
            relativePath: target.relativePath,
            workingDirectory: workingDirectory
        )
    }

    private func remember() {
        onRecordChange?(record)
    }

    private static func title(for directory: String, shell: String?, fallback: String) -> String {
        let name = (directory as NSString).lastPathComponent
        let folder = name.isEmpty ? fallback : name
        guard let shell, !shell.isEmpty else { return folder }
        return folder + " · " + (shell as NSString).lastPathComponent
    }
}
