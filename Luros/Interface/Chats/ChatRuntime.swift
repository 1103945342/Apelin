import LurosCore
import LurosProtocol
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Owns chat history, drafts and live sessions independently of the selected page.
@MainActor
final class ChatRuntime {
    /// The window's runtime, which names a conversation's journal in
    /// Settings ▸ Logs however Settings was opened.
    weak static var active: ChatRuntime?

    @objc dynamic var onChange: (() -> Void)?
    /// The saved conversations could not be read.
    @objc dynamic var onError: ((Error) -> Void)?
    /// A conversation could not be written; it goes on in memory and is
    /// written again with the next save that gets through.
    @objc dynamic var onSaveFailure: ((Error) -> Void)?
    /// A save got through after one had failed.
    @objc dynamic var onSaveRecovered: (() -> Void)?
    /// A conversation's draft was put back from outside the composer.
    @objc dynamic var onDraftRestored: ((UUID) -> Void)?
    /// Queued messages a stopped run never took went back to a
    /// conversation's composer, which the reader has yet to be told.
    var onUnsentReturned: ((UUID, DroppedMessages.Returned) -> Void)?
    /// Builds an agent ran completed, counted once each from the events a
    /// conversation had not read before (`CompletedBuilds`).
    @objc dynamic var onBuildsCompleted: ((Int) -> Void)?
    @objc dynamic private(set) var isLoaded = false
    /// The saved conversations have been checked against the host's live
    /// sessions once: what says working is working.
    @objc dynamic private(set) var isReconciled = false
    private(set) var records: [UUID: ChatRecord] = [:]
    private let store = ChatStore(folder: .app)
    @objc dynamic private var revision = 0
    private var readers: [UUID: Task<Void, Never>] = [:]
    private var opening: [UUID: Task<AgentOpenResponse, Error>] = [:]
    /// A newer Stop or Rewind supersedes an earlier Stop's queue continuation.
    @objc dynamic private var stopContinuations: [UUID: UUID] = [:]
    /// A message's attachment, read from its file once and kept while it is
    /// among the most recently asked for. A conversation's pictures are what a
    /// long history's memory was made of, and each is re-readable from its
    /// file, so only so many stay read at once.
    private var attachmentCache: [String: ComposerAttachment] = [:]
    /// The paths in `attachmentCache`, least recently asked for first.
    private var attachmentOrder: [String] = []
    private var attachmentBytes = 0
    /// How many attachment bytes stay read at once.
    private static let attachmentCacheBytes = 48 * 1024 * 1024
    private var transcripts = ChatTranscriptCache()
    /// Conversations whose events are not in memory. A launch reads each
    /// record's head and how many events sit beside it, and the events
    /// themselves are read when the conversation is opened or followed.
    private var unloadedEvents: Set<UUID> = []
    /// How many events each conversation has on disk. That is what a chat's
    /// history is known by while its events are unread, so a chat that has
    /// one is never taken for an empty one (`isUntouched`).
    private var eventCounts: [UUID: Int] = [:]
    /// The events that opened another conversation, as read from the file of a
    /// chat whose history is not in memory. Restoring lineage needs them and
    /// nothing else, so a launch scans the files instead of keeping every
    /// history resident (`scanLineage`).
    private var lineageOpened: [UUID: [TaskEvent]] = [:]
    /// Conversations whose latest state is in memory only.
    @objc dynamic private var unsaved: Set<UUID> = []
    /// Conversations being written, and those changed again meanwhile. A
    /// conversation is written once at a time and then once more with what
    /// it holds by then, so one that streams faster than it can be written
    /// queues no save, nor a copy of its whole history, per batch.
    @objc dynamic private var saving: Set<UUID> = []
    @objc dynamic private var savesPending: Set<UUID> = []
    /// Pending saves that go as soon as the write under way ends: a turn
    /// began or ended, or the reader changed something.
    @objc dynamic private var savesUrgent: Set<UUID> = []
    /// When each conversation's last write ended. A streamed or typed
    /// change waits until `saveInterval` after it, so a long history is
    /// written at most once in that time, and a write that took longer
    /// pushes the next one back as far.
    private var savedAt: [UUID: ContinuousClock.Instant] = [:]
    /// Saves waiting for their interval, by conversation.
    private var savesDeferred: [UUID: Task<Void, Never>] = [:]
    /// Called once no conversation is being written (`saveNow`).
    private var savesDrained: [() -> Void] = []
    private static let saveInterval: Duration = .seconds(3)
    /// Who waits for a conversation's compaction to end, by conversation.
    private var compactions: [UUID: CheckedContinuation<AgentCompactionResult, Error>] = [:]
    /// Messages whose send has not answered yet. One the reader stops
    /// (`stop`) is withdrawn: the host is not handed one it has not got,
    /// and the run of one it had taken is stopped once the send answers.
    private var pendingSends: [PendingSend] = []

    var summaries: [ChatSummary] {
        ChatLineage.projected(records.values.map(\.summary))
    }

    /// Only the presentation changes; each branch keeps its creation-time
    /// title on disk in case its direct parent is later deleted.
    func summary(_ id: UUID) -> ChatSummary? {
        summaries.first { $0.id == id }
    }

    private func restoreLineage(sessions: [AgentSessionSummary] = []) {
        // The scan looks through a conversation's events for the ones that
        // opened another, so it needs the events of the chats that could be a
        // parent — not every chat the app has. With no session from the host
        // to narrow that by, every chat is scanned, from what `scanLineage`
        // read of its file while the chat's history stayed on disk.
        let parents = Set(sessions.compactMap(\.parentSessionID))
        let named = Set(records.values.compactMap(\.summary.parentChatID))
        var opened: [UUID: [TaskEvent]] = [:]
        for record in records.values {
            guard sessions.isEmpty
                || record.sessionID.map(parents.contains) == true
                || named.contains(record.summary.id)
            else { continue }
            if unloadedEvents.contains(record.summary.id) {
                opened[record.summary.id] = lineageOpened[record.summary.id] ?? []
            }
        }
        for id in ChatAdoption.restoreLineage(in: &records, sessions: sessions, opened: opened) {
            persist(id, urgent: true)
        }
    }

    /// Reads from disk, off the main queue, the events that opened another
    /// conversation in every chat whose history is not in memory. A launch
    /// restores the edges between chats from these few events; the histories
    /// themselves stay on disk until a chat is opened (`loadEvents`).
    private func scanLineage() async {
        let ids = unloadedEvents
        guard !ids.isEmpty else { return }
        let folder = DataFolder.app.root.appendingPathComponent("Chats")
        let found = await Task.detached(priority: .utility) { () -> [UUID: [TaskEvent]] in
            var opened: [UUID: [TaskEvent]] = [:]
            for id in ids {
                guard let events = try? ChatEventsFile.scan(AgentConversations.openedEventKind, for: id, in: folder),
                      !events.isEmpty
                else { continue }
                opened[id] = events
            }
            return opened
        }.value
        lineageOpened.merge(found) { _, new in new }
    }

    /// The conversation the reader is looking at, nil while they look at
    /// none (`RootInterfaceController.syncViewedChat`). A reply that comes
    /// while another is looked at, or none, leaves it unread; looking at
    /// one reads it (`ChatUnread`).
    @objc dynamic var viewedChat: UUID? {
        didSet {
            guard let viewedChat, viewedChat != oldValue, records[viewedChat]?.summary.markRead() == true else { return }
            changed(viewedChat)
        }
    }

    /// Reads every saved conversation. An untouched one left by an earlier
    /// launch is dropped, unless it is `selected`, the one to show again.
    /// A folder that cannot be read leaves no saved conversation, says
    /// so, and still lets the reader start one: the list is loaded, empty
    /// (issue #33).
    func load(keeping selected: UUID?) async {
        do {
            // A launch reads each conversation's head and how many events sit
            // beside it, never the events themselves: their megabytes are what
            // this costs. A conversation's events are read when it is opened,
            // followed or paged through (`loadEvents`).
            let loaded = try await store.load(readingEvents: false)
            for (name, error) in loaded.unreadable {
                ConversationJournal.unreadable(name, error)
            }
            for record in loaded.records {
                let id = record.summary.id
                eventCounts[id] = loaded.eventCounts[id] ?? record.events.count
                unloadedEvents.insert(id)
                records[id] = record
                if record.sending != nil {
                    // Whether the host took a message is read from the events
                    // that echo it, so this one conversation is read now.
                    loadEvents(id)
                    records[id]?.reclaimUnsent()
                    persist(id, urgent: true)
                }
            }
        } catch {
            onError?(error)
        }
        for record in records.values where isUntouched(record) && record.summary.id != selected {
            try? await removeRecord(record.summary.id)
            if record.summary.projectName == nil {
                // the folder the menu's Open Terminal or Browse Files made,
                // if it was left empty; rmdir takes nothing else
                rmdir(DataFolder.app.root.appendingPathComponent("Temporary/" + record.summary.id.uuidString).path)
            }
        }
        // a project deleted while the app was away
        await forget(DeletedProjects.gone(from: summaries, in: .app))
        restoreLineage()
        isLoaded = true
        onChange?()
        // The events that opened another conversation are read from the files
        // on a background pass, not here: the list comes up from the heads
        // alone, and an edge a record lost is restored a moment later.
        Task { [weak self] in
            guard let self else { return }
            await self.scanLineage()
            self.restoreLineage()
        }
        // A host that does not answer yet is not an error, and runs nothing
        // this app could follow: every saved row stops working.
        //
        // A saved row's `isWorking` and `run` are what the last launch saw, not
        // what is running now: the app was quit, so a turn it showed went with
        // the process. They wait here, cleared, rather than claiming a turn is
        // going — a chat shown working with no way to stop it is worse than one
        // that takes a moment to come back. The host's answer puts a live one
        // back (`reconcile`), and the row's own events supply the rest.
        for id in records.keys {
            if records[id]?.run != nil { records[id]?.run = nil }
            if records[id]?.summary.isWorking == true { records[id]?.summary.isWorking = false }
        }
        let live = await (try? LurosService.app.agentList().sessions) ?? []
        reconcile(with: live)
        // What agents opened while the app was not following their openers.
        // Resolve parents before children without relying on the host's order.
        var remaining = live
        while !remaining.isEmpty {
            let count = records.count
            remaining.removeAll { session in
                // A chat an agent opened, or one a phone holds: neither is
                // the app's, and both are listed here.
                guard let record = ChatAdoption.record(session: session, records: Array(records.values))
                    ?? ChatAdoption.record(channel: session, records: Array(records.values))
                else { return false }
                adopt(record)
                return true
            }
            if records.count == count { break }
        }
        restoreLineage(sessions: live)
        isReconciled = true
        onChange?()
    }

    /// Puts every saved row in step with what the host reports now: a run it
    /// serves is followed, and one nothing is left to follow ends — a task
    /// that ended while the app was away, a session the host no longer has.
    /// Run whenever the app comes back in front, so a row that lost its run
    /// stops saying it is without a relaunch.
    func reconcileRuns() async {
        reconcile(with: await (try? LurosService.app.agentList().sessions) ?? [])
    }

    private func reconcile(with live: [AgentSessionSummary]) {
        for record in records.values {
            if let session = live.first(where: { $0.sessionID == record.sessionID }) {
                // Only a task the host names that this row is not on is a
                // reopened session; asking again about the same task settles
                // nothing and must not redraw the page.
                if record.task != session.task {
                    records[record.summary.id]?.reopen(as: session.task)
                }
                // A task the host reports ended is read to its end too: the
                // reply, and the run's own end, are in the events after this
                // row's cursor when the app was killed in the middle of the
                // turn, and a conversation left saying it is working — with
                // nothing left to stop — is what not reading them leaves.
                follow(record.summary.id, task: session.task)
                if session.state.isTerminal {
                    if records[record.summary.id]?.run != .ended
                        || records[record.summary.id]?.summary.isWorking == true
                    {
                        records[record.summary.id]?.summary.isWorking = false
                        records[record.summary.id]?.run = .ended
                        changed(record.summary.id)
                    }
                } else if record.task != session.task {
                    // A task the host names that this row is not on: a report
                    // it delivered while the app was away started another run,
                    // so the row stops saying it finished.
                    //
                    // The same task the row already knows is not a run: a
                    // session a page once opened keeps its worker waiting for a
                    // prompt, and the host calls that task running without a
                    // turn going. Taking its existence for a run is what made
                    // every visited chat look busy, with nothing to stop.
                    records[record.summary.id]?.run = .running
                    records[record.summary.id]?.summary.isWorking = true
                    changed(record.summary.id)
                }
            } else if record.summary.isWorking || record.run == .running || record.run == .stopping {
                // The host has no such session: whatever turn this row shows
                // as going ended with the process that ran it.
                records[record.summary.id]?.summary.isWorking = false
                records[record.summary.id]?.run = .ended
                changed(record.summary.id)
            }
        }
    }

    /// Lists and follows a conversation an agent opened, leaving the
    /// selection where it is.
    private func adopt(_ record: ChatRecord?) {
        guard let record, let task = record.task else { return }
        records[record.summary.id] = record
        // A delegated chat starts on the model Settings ▸ Default Models
        // gives it, the one its opener's session was opened with; the
        // composer must show the model that turn ran on.
        if record.summary.relationship == .derived {
            ComposerModelSelection.seedDelegated(for: record.summary.id)
        }
        restoreLineage()
        changed(record.summary.id)
        follow(record.summary.id, task: task)
    }

    /// Lists and follows a session an `lurosdev://` link named that had no
    /// row (`ChatLinkTarget`), and returns its row.
    func adoptLinked(_ record: ChatRecord) -> ChatSummary? {
        guard !records.values.contains(where: { $0.sessionID == record.sessionID }) else { return nil }
        adopt(record)
        return records[record.summary.id]?.summary
    }

    /// A conversation to start in `project`: its untouched one, `current`
    /// first, brought to now, or else a new one.
    func newChat(project: String?, preferring current: UUID?) -> ChatSummary {
        let untouched = records.values.filter { $0.summary.projectName == project && isUntouched($0) }
        let reused = untouched.first { $0.summary.id == current }
            ?? untouched.max { $0.summary.lastInteraction < $1.summary.lastInteraction }
        let summary = reused?.summary ?? ChatSummary.untitled(lastInteraction: Date(), projectName: project)
        // A row that was shown and left empty starts as a new chat again: on
        // the model the reader last picked, not the one it was shown with.
        if let reused {
            ComposerModelSelection.forget(reused.summary.id)
        }
        if reused == nil {
            records[summary.id] = ChatRecord(summary: summary)
        }
        records[summary.id]?.summary.lastInteraction = Date()
        changed(summary.id)
        return records[summary.id]?.summary ?? summary
    }

    /// Whether any conversation is working right now: a turn running, a
    /// message sending, a session opening. What removes the sessions a turn
    /// depends on asks first.
    var hasWorkingConversations: Bool {
        if records.values.contains(where: { $0.summary.isWorking || $0.sending != nil }) {
            return true
        }
        return !opening.isEmpty
    }

    /// Nothing sent, typed or attached, no session opening, not pinned and
    /// not named: a row that holds nothing but its place.
    private func isUntouched(_ record: ChatRecord) -> Bool {
        // A chat with a history is never untouched, whether that history is in
        // memory or still on disk: the count knows before the events are read.
        (eventCounts[record.summary.id] ?? record.events.count) == 0
            && record.sessionID == nil && record.task == nil && opening[record.summary.id] == nil
            && record.sending == nil && record.draft.text.isEmpty && record.draft.attachments.isEmpty
            && !record.summary.isPinned && record.summary.isNamedByReader != true
    }

    func saveDraft(_ draft: ComposerDraft, for id: UUID) {
        records[id]?.draft = draft
        persist(id)
    }

    @objc dynamic func togglePin(_ id: UUID) {
        records[id]?.summary.isPinned.toggle()
        changed(id)
    }

    /// `name` as the conversation's title from now on: the agent's titles
    /// no longer replace it (`ChatSummary.rename(to:)`).
    @objc dynamic func rename(_ id: UUID, to name: String) {
        if let chat = records[id]?.summary, chat.relationship == .branch,
           let parentID = chat.parentChatID, let parent = records[parentID]?.summary,
           parent.projectName == chat.projectName { return }
        guard records[id]?.summary.rename(to: name) == true else { return }
        changed(id)
    }

    func delete(_ id: UUID) async throws {
        let session = records[id]?.sessionID
        try await closeSession(id)
        let isTemporary = records[id].map { $0.summary.projectName == nil } ?? false
        try await removeRecord(id)
        onChange?()
        // its banners would open a conversation that is no longer there
        ConversationNotices.shared.withdraw(session: session)
        // a temporary conversation's working folder, its files with it, once
        // the row is gone: a file it cannot remove leaves the folder behind,
        // never a row Delete can no longer take away
        if isTemporary {
            let folder = DataFolder.app
            try? await Task.detached { try folder.removeTemporaryFolder(of: id) }.value
        }
    }

    func deleteProject(_ name: String) async throws {
        let ids = records.values.filter { $0.summary.projectName == name }.map(\.summary.id)
        for id in ids {
            ConversationNotices.shared.withdraw(session: records[id]?.sessionID)
            try await closeSession(id)
        }
        let folder = DataFolder.app
        try await Task.detached { try folder.removeProject(named: name) }.value
        defer { onChange?() }
        for id in ids {
            try await removeRecord(id)
        }
    }

    /// Takes away the conversations of every project whose folder has gone
    /// from `Projects/` (`DeletedProjects`), as `deleteProject` takes them
    /// once it has removed the folder itself. Answers the projects gone.
    @discardableResult
    func forgetDeletedProjects() async -> Set<String> {
        guard isLoaded else { return [] }
        let gone = DeletedProjects.gone(from: summaries, in: .app)
        guard !gone.conversations.isEmpty else { return [] }
        await forget(gone)
        onChange?()
        return gone.projects
    }

    /// Their banners withdrawn, any session the host left open closed —
    /// an agent's deletion closed its own, so nothing waits on the host
    /// here —, and their histories removed; a history that cannot be
    /// removed is tried again with the next change.
    private func forget(_ gone: DeletedProjects.Gone) async {
        for id in gone.conversations {
            let session = records[id]?.sessionID
            ConversationNotices.shared.withdraw(session: session)
            if let session {
                Task { try? await LurosService.app.agentClose(sessionID: session, deleted: true) }
            }
            try? await removeRecord(id)
        }
    }

    private func closeSession(_ id: UUID) async throws {
        stopContinuations[id] = nil
        // A send may still be opening the session when Delete is tapped.
        var sessionID = records[id]?.sessionID
        if let pending = opening[id], let opened = try? await pending.value {
            sessionID = opened.sessionID
        }
        guard let sessionID else { return }
        do { try await LurosService.app.agentClose(sessionID: sessionID, deleted: true) }
        catch let error as LurosError where error.code == .notFound {
            // A finished session or one lost with the host is already closed.
        }
    }

    private func removeRecord(_ id: UUID) async throws {
        // Keep the in-memory row on disk failure, so Delete can be retried.
        try await store.remove(id)
        // its agent's journal goes with its history, as its banners do
        if let session = records[id]?.sessionID {
            let journals = AppJournal.agentDirectory
            Task.detached { JournalFiles.removeConversation(session, in: journals) }
        }
        readers.removeValue(forKey: id)?.cancel()
        savesDeferred.removeValue(forKey: id)?.cancel()
        savedAt[id] = nil
        records.removeValue(forKey: id)
        transcripts.remove(id)
        historyTurns[id] = nil
        promptCache[id] = nil
    }

    /// The conversation's events, read from disk the first time something needs
    /// them: opening it, following it, or paging through its history. A chat
    /// whose events cannot be read stays unloaded and keeps the count its head
    /// gave, so nothing takes it for a chat with no history.
    @discardableResult
    func loadEvents(_ id: UUID) -> [TaskEvent] {
        guard unloadedEvents.contains(id) else { return records[id]?.events ?? [] }
        let folder = DataFolder.app.root.appendingPathComponent("Chats")
        guard let events = try? ChatEventsFile.read(id, in: folder) else {
            return records[id]?.events ?? []
        }
        records[id]?.events = events
        eventCounts[id] = events.count
        unloadedEvents.remove(id)
        return events
    }

    /// The conversation's rows, brought up to date only when its events, the
    /// messages it is sending, a sender's title or the turn's quiet changed
    /// (`ChatTranscriptCache`).
    func transcript(_ id: UUID) -> ChatTranscript {
        guard records[id] != nil else {
            return ChatTranscript(events: []) { _ in nil }
        }
        loadEvents(id)
        let record = records[id]!
        return transcripts.transcript(
            of: record,
            from: historyStart(of: id),
            now: Date(),
            isFollowed: { readers[$0] != nil },
            conversationTitle: { title(ofSession: $0) },
        ) { [self] item in attachment(item, in: id) }
    }

    /// How many turns of each conversation are folded when it is opened:
    /// its last ones, and another page each time the reader asks.
    private var historyTurns: [UUID: Int] = [:]

    /// The event a conversation's fold starts at.
    private func historyStart(of id: UUID) -> Int {
        guard records[id] != nil else { return 0 }
        loadEvents(id)
        return ChatHistory.start(of: records[id]?.events ?? [], keeping: historyTurns[id] ?? ChatHistory.turns)
    }

    /// Whether `id` holds events before the ones it is showing.
    func hasEarlierHistory(_ id: UUID) -> Bool {
        historyStart(of: id) > 0
    }

    /// Folds another page of `id`'s earlier turns in, and answers whether
    /// there was one to fold: the page shows when its transcript is asked for
    /// again.
    @discardableResult
    func loadEarlierHistory(_ id: UUID) -> Bool {
        guard hasEarlierHistory(id) else { return false }
        historyTurns[id] = (historyTurns[id] ?? ChatHistory.turns) + ChatHistory.step
        return true
    }

    /// Each of the conversation's prompts, in order, as the rail lists them:
    /// read from the record, so the rail covers turns the page has not folded
    /// in. Only the events that arrived since are read again — a stream asks
    /// for this on every one of them.
    func promptRows(of id: UUID) -> [ChatMessageRuler.Entry] {
        loadEvents(id)
        guard let record = records[id] else { return [] }
        let cached = promptCache[id].flatMap { $0.events <= record.events.count ? $0 : nil }
        let from = cached?.events ?? 0
        var entries = cached?.entries ?? []
        if from < record.events.count {
            for index in from ..< record.events.count where record.events[index].kind == "prompt" {
                let event = record.events[index]
                entries.append(ChatMessageRuler.Entry(
                    id: ChatTranscript.userMessageID(of: event) ?? ChatTranscript.rowID(forEventAt: index),
                    text: event.payload?["text"]?.stringValue ?? "",
                    sentAt: event.time,
                ))
            }
        }
        promptCache[id] = (record.events.count, entries)
        return entries
    }

    /// Folds `conversationID` back to the turn the row `rowID` belongs to, in
    /// one fold rather than a page at a time — the rail can pick a message far
    /// outside what the page was showing — and answers whether it had to.
    @discardableResult
    func showHistory(_ conversationID: UUID, from rowID: UUID) -> Bool {
        loadEvents(conversationID)
        guard let record = records[conversationID] else { return false }
        var prompts: [UUID] = []
        for (index, event) in record.events.enumerated() where event.kind == "prompt" {
            prompts.append(ChatTranscript.userMessageID(of: event) ?? ChatTranscript.rowID(forEventAt: index))
        }
        guard let position = prompts.firstIndex(of: rowID) else { return false }
        let needed = prompts.count - position
        guard needed > (historyTurns[conversationID] ?? ChatHistory.turns) else { return false }
        historyTurns[conversationID] = needed
        return true
    }

    /// The prompts a rail was last built from, by conversation, and how many
    /// events they were read from.
    private var promptCache: [UUID: (events: Int, entries: [ChatMessageRuler.Entry])] = [:]

    /// The title of the conversation `sessionID` is, which names a message
    /// its agent sent, and its journal in Settings ▸ Logs.
    @objc dynamic func title(ofSession sessionID: String) -> String? {
        guard let id = records.values.first(where: { $0.sessionID == sessionID })?.summary.id else { return nil }
        return summary(id)?.displayTitle
    }

    /// A message's attachment, read from its file once and kept. One that
    /// cannot be read is tried again with the conversation's next change.
    private func attachment(_ item: AgentAttachment, in id: UUID) -> ComposerAttachment? {
        guard let path = attachmentPath(item, in: id) else { return nil }
        if let cached = attachmentCache[path] {
            touchAttachment(path)
            return cached
        }
        guard let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 32 * 1024 * 1024, let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        let isText = item.mimeType.hasPrefix("text/")
            || UTType(mimeType: item.mimeType)?.conforms(to: .text) == true
        let file = ComposerAttachment(
            name: item.name,
            data: data,
            text: isText ? String(decoding: data.prefix(8192), as: UTF8.self) : nil,
            isImage: item.mimeType.hasPrefix("image/"),
        )
        return keepAttachment(file, at: path)
    }

    /// Keeps `file` as the attachment at `path`, the most recently asked for,
    /// letting the oldest ones go once their bytes pass the cap. The one just
    /// asked for stays even if it alone is over it.
    private func keepAttachment(_ file: ComposerAttachment, at path: String) -> ComposerAttachment {
        let previous = attachmentCache.updateValue(file, forKey: path)
        attachmentBytes += file.data.count - (previous?.data.count ?? 0)
        touchAttachment(path)
        while attachmentBytes > Self.attachmentCacheBytes, attachmentOrder.count > 1 {
            let oldest = attachmentOrder.removeFirst()
            if let dropped = attachmentCache.removeValue(forKey: oldest) {
                attachmentBytes -= dropped.data.count
            }
        }
        return file
    }

    private func touchAttachment(_ path: String) {
        guard attachmentOrder.last != path else { return }
        attachmentOrder.removeAll { $0 == path }
        attachmentOrder.append(path)
    }

    /// Where a message's attachment is: by its canonical path, inside the
    /// conversation's project or temporary folder.
    private func attachmentPath(_ item: AgentAttachment, in id: UUID) -> String? {
        let root: URL = if let name = records[id]?.summary.projectName,
                           let project = DataFolder.app.project(named: name)
        {
            project
        } else {
            DataFolder.app.root.appendingPathComponent("Temporary/" + id.uuidString)
        }
        let url = root.appendingPathComponent(item.path)
        guard let rootPath = CanonicalPath.resolve(root.path),
              let path = CanonicalPath.resolve(url.path), CanonicalPath.isCanonical(path, inside: rootPath)
        else { return nil }
        return path
    }

    /// Shows `draft` at once as `id`'s next message, under the draft's id,
    /// which the host's `prompt` or `queued` event echoes; that event's row
    /// takes its place. The conversation works from here on: a message on
    /// its way and a turn running are one state, with the turn's summary
    /// under the message already (`ChatTranscript`) and Stop to take it
    /// back (`stop`), however long the host takes to open the session. The
    /// returned task waits for the send: when it fails, the message is
    /// taken out again and the draft put back in an empty composer before
    /// the task throws; stopped, it throws `CancellationError` at once.
    func submit(_ draft: ComposerDraft, to id: UUID) -> Task<Void, Error> {
        guard records[id] != nil else { return Task {} }
        records[id]?.submit(draft)
        records[id]?.summary.isWorking = true
        let pending = PendingSend(chat: id, draft: draft.id)
        pendingSends.append(pending)
        changed(id)
        // The send runs to its own end, whoever still waits for it.
        Task {
            do {
                try await send(draft, to: id, as: pending)
                pending.end(.success(()))
            } catch {
                // one the reader stopped was taken back then
                if !pending.isWithdrawn {
                    takeBack(draft, from: id)
                }
                pending.end(.failure(error))
            }
            pendingSends.removeAll { $0 === pending }
        }
        return Task { try await pending.value() }
    }

    /// A send that failed or was stopped: its row goes, and its draft
    /// returns to an empty composer (`ChatRecord.takeBack`). The
    /// conversation works on only if something else keeps it working.
    private func takeBack(_ draft: ComposerDraft, from id: UUID) {
        guard let restored = records[id]?.takeBack(draft) else { return }
        let stillWorks = works(id)
        records[id]?.summary.isWorking = stillWorks
        changed(id)
        if restored {
            onDraftRestored?(id)
        }
    }

    /// Whether `id` works: a message is on its way to the host, or the
    /// session being followed runs a turn or a compaction.
    @objc dynamic private func works(_ id: UUID) -> Bool {
        guard let record = records[id] else { return false }
        if record.isSending {
            return true
        }
        guard readers[id] != nil else { return false }
        let current = transcript(id)
        return current.isWorking || current.isCompacting
    }

    /// Whether the session of `id` runs a turn or a compaction now, which
    /// an approval waits in: a message still on its way makes the
    /// conversation work before any turn does, and a request a stopped
    /// session left can no longer be answered.
    @objc dynamic func runsTurn(_ id: UUID) -> Bool {
        guard records[id]?.summary.isWorking == true else { return false }
        let current = transcript(id)
        return current.isWorking || current.isCompacting
    }

    private func send(_ draft: ComposerDraft, to id: UUID, as pending: PendingSend) async throws {
        guard records[id] != nil else { return }
        let selection = ComposerModelSelection.selection(for: id)
        let opened = try await open(id, selection: selection)
        guard records[id] != nil else { return }
        // stopped while the session opened: the host never hears of it
        guard !pending.isWithdrawn else { throw CancellationError() }
        var descriptors: [OwnedDescriptor] = []
        var inputs: [AgentInputAttachment] = []
        // only attachments need the disk: text still goes out when it is full
        let staging = DataFolder.app.root.appendingPathComponent("Chats/Uploads/" + UUID().uuidString)
        if !draft.attachments.isEmpty {
            try DataFolder.app.makeLevels(to: staging)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        for file in draft.attachments {
            guard descriptors.count < 8, file.data.count <= 32 * 1024 * 1024 else {
                throw LurosError(.badRequest, String(localized: "Send up to 8 files, each no larger than 32 MB."))
            }
            let url = staging.appendingPathComponent(file.id.uuidString)
            try file.data.write(to: url, options: .atomic)
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            inputs.append(AgentInputAttachment(
                descriptor: DescriptorSlot(index: descriptors.count),
                name: file.name,
                mimeType: file.isImage
                    ? imageMIME(file.data)
                    : (UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType
                        ?? "application/octet-stream"),
            ))
            descriptors.append(OwnedDescriptor(adopting: fd))
        }
        let selected = selection ?? ComposerModelSelection.selection(for: id)
        _ = try await LurosService.app.send(
            AgentPromptRequest(
                sessionID: opened.sessionID,
                text: draft.text,
                messageID: draft.id,
                attachments: inputs,
                provider: selected?.provider,
                model: selected?.model,
                modelDefaults: Preferences.DefaultModels.wire,
                reasoningEffort: selected?.effort,
                serviceTier: selected?.tier,
                approvalMode: AgentPermissions.mode,
                asksBeforeScreen: AgentPermissions.asksBeforeScreen,
                runMode: ComposerModeStore.mode(for: id).runMode,
                promptInjection: Preferences.PromptInjection.forPrompt,
                modelParameters: ModelParameters.values(for: selected?.provider, model: selected?.model).wire,
            ),
            descriptors: descriptors,
        )
        if pending.isWithdrawn {
            // Stopped while the host was taking it. The host has it now,
            // and its run has started by the time the send answers: an
            // earlier stop found no run to stop.
            try? await LurosService.app.agentAbort(sessionID: opened.sessionID)
            throw CancellationError()
        }
        records[id]?.summary.nameAfterFirstMessage(text: draft.text, attachmentName: draft.attachments.first?.name)
        changed(id)
    }

    func manageQueue(in id: UUID, action: AgentQueueAction, messageID: UUID? = nil,
                     text: String? = nil, order: [UUID]? = nil) async throws {
        let opened = try await open(id)
        _ = try await LurosService.app.agentQueue(AgentQueueRequest(
            sessionID: opened.sessionID, action: action, messageID: messageID, text: text, order: order
        ))
    }

    /// `ownerVerified`: the reader passed the device owner's check for this
    /// decision, which the host requires to approve a command as root.
    /// `answer`: the reader's answer, with approve, to a question.
    func approve(
        _ messageID: UUID,
        in id: UUID,
        decision: ApprovalDecision,
        ownerVerified: Bool? = nil,
        answer: AgentQuestionAnswer? = nil,
        note: String? = nil,
    ) async throws {
        guard let sessionID = records[id]?.sessionID,
              let approvalID = transcript(id).approvalIDs[messageID]
        else { return }
        try await LurosService.app.agentApprove(
            sessionID: sessionID,
            approvalID: approvalID,
            decision: decision,
            ownerVerified: ownerVerified,
            answer: answer,
            note: note,
        )
    }

    /// Stops what `id` is doing. A message whose send has not answered is
    /// withdrawn, back to the composer as a failed send's is, and whoever
    /// waits for the send stops waiting: the host is not handed one it has
    /// not got, and the run of one it has is stopped when the send answers
    /// (`send`). Then the session's run, if it has one.
    func stop(_ id: UUID, continueQueue: Bool = true) async throws {
        for pending in pendingSends where pending.chat == id && !pending.isWithdrawn {
            if let draft = records[id]?.sending?.first(where: { $0.id == pending.draft }) {
                takeBack(draft, from: id)
            }
            pending.withdraw()
        }
        guard let sessionID = records[id]?.sessionID else { return }
        let continuation = UUID()
        stopContinuations[id] = continuation
        defer {
            if stopContinuations[id] == continuation { stopContinuations[id] = nil }
        }
        do {
            try await LurosService.app.agentAbort(sessionID: sessionID)
            guard stopContinuations[id] == continuation,
                  records[id]?.sessionID == sessionID else { return }
            // The host has now cancelled the old run's shell calls. Only
            // then request FIFO continuation; the session waits for cleanup.
            if records[id]?.summary.isWorking == true {
                records[id]?.run = .stopping
                changed(id)
            }
            if continueQueue {
                _ = try await LurosService.app.agentQueue(AgentQueueRequest(sessionID: sessionID, action: .resume))
            }
        } catch let error as LurosError where error.code == .notFound {
            guard stopContinuations[id] == continuation else { return }
            // The session ended with the process that ran it (the app was
            // quit, or the host restarted): there is no run left to stop, and
            // the row must not keep saying it is. Waiting on a host that has
            // nothing to stop is what made Stop look broken.
            records[id]?.summary.isWorking = works(id)
            records[id]?.run = .ended
            changed(id, urgent: true)
            return
        } catch {
            guard stopContinuations[id] == continuation else { return }
            // A current request's failure stays visible. A superseded Stop
            // must not report a conflict over the Rewind that replaced it.
            throw error
        }
    }

    // MARK: The history's changes (Checkpoint & Rewind, a message's menu)

    /// Takes message `messageID` back: the run going stops first, and with
    /// `truncate` the message and everything after it leave the
    /// conversation. The session is opened again for it when it has ended.
    func rewind(_ messageID: UUID, in id: UUID, truncate: Bool) async throws {
        stopContinuations[id] = nil
        let opened = try await open(id)
        try await LurosService.app.agentRewind(sessionID: opened.sessionID, messageID: messageID, truncate: truncate)
    }

    /// Puts the project's code back as it was before message `messageID`'s
    /// run. A run going is stopped first; the conversation stays.
    func restoreCode(before messageID: UUID, in id: UUID) async throws -> GitCheckpointRestoreResponse {
        guard let project = records[id]?.summary.projectName else {
            throw LurosError(.notFound, String(localized: "No code was saved before this message."))
        }
        if records[id]?.summary.isWorking == true {
            try await rewind(messageID, in: id, truncate: false)
        }
        return try await LurosService.app.gitCheckpointRestore(projectID: project, messageID: messageID)
    }

    /// Gives message `messageID`, or with `reply` the reply that ends its
    /// turn, the text `text`; `expected` is the reply's text as shown.
    func edit(_ messageID: UUID, in id: UUID, reply: Bool, text: String, expected: String?) async throws {
        let opened = try await open(id)
        try await LurosService.app.agentEditMessage(
            sessionID: opened.sessionID,
            messageID: messageID,
            reply: reply,
            text: text,
            expected: expected,
        )
    }

    /// Deletes the reply that ends message `messageID`'s turn.
    func deleteReply(of messageID: UUID, in id: UUID, expected: String?) async throws {
        let opened = try await open(id)
        try await LurosService.app.agentDeleteReply(sessionID: opened.sessionID, messageID: messageID, expected: expected)
    }

    /// A project's conversation can be forked; a temporary one, whose
    /// folder is its own, cannot.
    func canFork(_ id: UUID) -> Bool {
        records[id]?.summary.projectName != nil
    }

    /// A new conversation holding `id`'s model history through the turn of
    /// message `messageID`, named after it and listed first. Its new session
    /// is opened when its page is selected; a failed open leaves the same row to retry.
    func fork(_ id: UUID, through messageID: UUID) async throws -> ChatSummary? {
        guard records[id] != nil, canFork(id) else { return nil }
        // The session log is the source of truth for a fork. Its worker
        // replays the sealed model snapshot and marks those events historical;
        // the UI must not copy the source's possibly edited event list.
        let opened = try await open(id)
        guard let number = try await reserveBranchNumber(id), records[id] != nil else { return nil }
        let newSessionID = UUID().uuidString.lowercased()
        try await LurosService.app.agentFork(sessionID: opened.sessionID, newSessionID: newSessionID, messageID: messageID)
        guard let current = summary(id) else { return nil }
        var summary = ChatSummary.untitled(lastInteraction: Date(), projectName: current.projectName)
        summary.title = current.title
        summary.parentChatID = id
        summary.relationship = .branch
        summary.branchNumber = number
        let newID = summary.id
        records[newID] = ChatRecord(summary: summary, sessionID: newSessionID)
        // A branch goes on with the parent's model, effort and speed: the
        // reader picked them for this conversation, and a branch of it is
        // the same conversation continued, not a new chat with the defaults.
        ComposerModelSelection.inherit(from: id, into: newID)
        // Opening the page starts (or retries) its replay. No model prompt is
        // sent, and failure stays visible instead of leaving a silent blank.
        changed(newID)
        return self.summary(newID)
    }

    /// Durably reserve on the parent before asking the host to fork. A
    /// best-effort child save must not let a deleted branch's number be reused
    /// after a restart. Store revisions prevent an older queued save from
    /// replacing this snapshot; concurrent forks reserve on the main actor
    /// before either suspends. Failed reservations/forks never roll it back.
    private func reserveBranchNumber(_ id: UUID) async throws -> Int? {
        guard var record = records[id],
              let number = ChatLineage.reserveBranchNumber(in: &record.summary, summaries: records.values.map(\.summary))
        else { return nil }
        records[id]?.summary.lastBranchNumber = number
        revision += 1
        let reservationRevision = revision
        do {
            try await store.save(
                record,
                revision: reservationRevision,
                writesEvents: !unloadedEvents.contains(id),
                eventCount: eventCounts[id],
            )
            saved(id)
        } catch {
            unsaved.insert(id)
            onSaveFailure?(error)
            throw error
        }
        guard records[id] != nil else { throw CancellationError() }
        return number
    }

    /// Between runs only: a session to compact, nothing running, waiting
    /// for an approval or on its way to the host.
    @objc dynamic func canCompact(_ id: UUID) -> Bool {
        guard let record = records[id] else { return false }
        return record.sessionID != nil && !record.summary.isWorking && !record.isSending
            && opening[id] == nil && compactions[id] == nil
    }

    /// Compacts the conversation, and returns how it went once the session
    /// says so. Cancelled, it stops the compaction.
    func compact(_ id: UUID) async throws -> AgentCompactionResult {
        let opened = try await open(id)
        // what the reader takes from here on, which may answer before the request does
        let seen = records[id]?.events.count ?? 0
        try await LurosService.app.agentCompact(
            sessionID: opened.sessionID,
            modelDefaults: Preferences.DefaultModels.wire,
        )
        if let event = records[id]?.events.dropFirst(seen).last(where: { $0.kind == "compactionFinished" }) {
            return Self.compactionResult(event)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                compactions[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.endCompaction(id, with: .failure(CancellationError()))
                try? await LurosService.app.agentAbort(sessionID: opened.sessionID)
            }
        }
    }

    private func endCompaction(_ id: UUID, with result: Result<AgentCompactionResult, Error>) {
        compactions.removeValue(forKey: id)?.resume(with: result)
    }

    private static func compactionResult(_ event: TaskEvent) -> AgentCompactionResult {
        (try? event.payload?.decode(AgentCompactionResult.self)) ?? AgentCompactionResult(outcome: .failed)
    }

    /// Tells the open session which model the next message will use, so the
    /// total the ring draws is that model's before anything is sent. Answers
    /// the figure the session measured, or nil when there is no session to
    /// tell or a run was going — the next prompt carries the choice then.
    @discardableResult
    func configureModel(
        _ id: UUID,
        selection: ComposerModelSelection,
    ) async -> (tokens: Int, window: Int)? {
        guard let sessionID = records[id]?.sessionID else { return nil }
        do {
            let answer = try await LurosService.app.agentConfigure(AgentConfigureRequest(
                sessionID: sessionID,
                provider: selection.provider,
                model: selection.model,
                reasoningEffort: selection.effort,
                serviceTier: selection.tier,
                modelParameters: ModelParameters.values(for: selection.provider, model: selection.model).wire,
            ))
            guard answer.applied, let tokens = answer.tokens, let window = answer.window else { return nil }
            return (tokens: tokens, window: window)
        } catch {
            return nil
        }
    }

    /// Follow a saved session when the reader opens its page, without sending
    /// a prompt. In particular an empty fork must retry a failed first open.
    func loadHistory(_ id: UUID) async throws {
        guard let record = records[id],
              ChatFork.needsHistoryLoad(
                  record,
                  isFollowed: readers[id] != nil,
                  eventCount: eventCounts[id] ?? record.events.count
              )
        else { return }
        _ = try await open(id)
    }

    private func open(_ id: UUID, selection: ComposerModelSelection? = nil) async throws -> AgentOpenResponse {
        if let pending = opening[id] {
            return try await pending.value
        }
        guard let record = records[id] else { throw CancellationError() }
        if let sessionID = record.sessionID, let task = record.task, readers[id] != nil {
            return AgentOpenResponse(sessionID: sessionID, task: task)
        }
        let selected = selection ?? ComposerModelSelection.selection(for: id)
        let mode = AgentPermissions.mode
        let request = AgentOpenRequest(
            projectName: record.summary.projectName,
            temporaryID: record.summary.projectName == nil ? id.uuidString : nil,
            sessionID: record.sessionID,
            provider: selected?.provider,
            model: selected?.model,
            modelDefaults: Preferences.DefaultModels.wire,
            approvalMode: mode,
            asksBeforeScreen: AgentPermissions.asksBeforeScreen,
            reasoningEffort: selected?.effort,
            serviceTier: selected?.tier,
            modelParameters: ModelParameters.values(for: selected?.provider, model: selected?.model).wire,
            promptInjection: Preferences.PromptInjection.wire,
        )
        if request.temporaryID != nil {
            try DataFolder.app.makeLevels(to: DataFolder.app.root.appendingPathComponent("Temporary/" + id.uuidString))
        }
        let pending = Task { try await LurosService.app.agentOpen(request) }
        opening[id] = pending
        defer { opening[id] = nil }
        let result = try await pending.value
        guard records[id] != nil else {
            try? await LurosService.app.agentClose(sessionID: result.sessionID, deleted: true)
            throw CancellationError()
        }
        records[id]?.sessionID = result.sessionID
        records[id]?.reopen(as: result.task)
        changed(id)
        follow(id, task: result.task)
        return result
    }

    private func follow(_ id: UUID, task: TaskHandle) {
        guard readers[id] == nil else { return }
        // Following appends the events it takes, so the conversation's history
        // has to be in memory first.
        loadEvents(id)
        readers[id] = Task { [weak self] in
            defer {
                self?.readers[id] = nil
                self?.endCompaction(id, with: .failure(LurosError(
                    .notFound,
                    String(localized: "This chat is no longer running."),
                )))
            }
            while !Task.isCancelled {
                // Only the cursor: a copy of the record held over the wait
                // would make the next batch copy every event to add to them.
                guard let self, records[id]?.task == task, let cursor = records[id]?.cursor else { return }
                do {
                    let batch = try await LurosService.app.attach(task, afterSeq: cursor)
                    guard !Task.isCancelled, records[id]?.task == task else { return }
                    let fresh = records[id]?.take(batch.events) ?? []
                    if !fresh.isEmpty { eventCounts[id] = records[id]?.events.count ?? 0 }
                    let realtime = fresh.filter { !ChatFork.isHistorical($0) }
                    // Historical replay belongs in the transcript and cursor,
                    // but must not replay reader-visible side effects.
                    records[id]?.summary.noteReplies(in: realtime, isViewed: id == viewedChat)
                    ConversationJournal.note(realtime, session: records[id]?.sessionID)
                    let echoed = settleSending(in: id, against: realtime)
                    let builds = CompletedBuilds.count(in: realtime)
                    if builds > 0 {
                        onBuildsCompleted?(builds)
                    }
                    for event in realtime where event.kind == AgentConversations.openedEventKind {
                        if let parent = records[id] {
                            adopt(ChatAdoption.record(
                                opened: event.payload,
                                parent: parent,
                                records: Array(records.values),
                            ))
                        }
                    }
                    if realtime.contains(where: { $0.kind == AgentConversations.openedEventKind }) {
                        // The child may already have been adopted from a link
                        // or agentList, so a duplicate open still supplies an edge.
                        restoreLineage()
                    }
                    let dropped = realtime.filter { $0.kind == "queueDropped" }
                        // persisted-read: one event's field, nothing written back from it
                        .flatMap { (try? $0.payload?["ids"]?.decode([UUID].self)) ?? [] }
                    if !dropped.isEmpty {
                        restoreDropped(Set(dropped), in: id)
                    }
                    if let title = realtime.last(where: { $0.kind == "title" })?.payload?["text"]?.stringValue {
                        records[id]?.summary.suggestTitle(title)
                    }
                    if let proposed = realtime
                        .last(where: { $0.kind == "projectNameSuggested" })?.payload?["name"]?.stringValue,
                       let project = records[id]?.summary.projectName,
                       let name = ProjectDisplayName.candidate(proposed)
                    {
                        Task {
                            if let response = try? await LurosService.app.projectRename(
                                .init(projectID: project, displayName: name, onlyIfAutomatic: true),
                            ), response.changed {
                                NotificationCenter.default.post(name: .lurosProjectsChanged, object: nil)
                            }
                        }
                    }
                    if let finished = realtime.last(where: { $0.kind == "compactionFinished" }) {
                        endCompaction(id, with: .success(Self.compactionResult(finished)))
                    }
                    let wasWorking = records[id]?.summary.isWorking
                    let current = transcript(id)
                    let runsTurn = current.isWorking || current.isCompacting
                    // A message still on its way works too (`submit`).
                    let isWorking = runsTurn || records[id]?.isSending == true
                    // The row's state, never its place in the sidebar: only
                    // the reader's New Chat and messages move that
                    // (`lastInteraction`), however much the agent writes.
                    records[id]?.summary.isWorking = isWorking
                    // A wait that ran out with nothing, as an idle session's
                    // does every 20 s, has nothing to write or show. A turn's
                    // start and end are written at once, what streams between
                    // them at most every `saveInterval`. The start is the
                    // host's echo of the message: the conversation has
                    // worked since the reader's Send.
                    let turnMoved = isWorking != wasWorking || echoed
                    if !batch.events.isEmpty || turnMoved {
                        changed(id, urgent: turnMoved || batch.finished)
                    }
                    if batch.finished {
                        if let end = records[id]?.missedEnd(of: batch, isWorking: runsTurn) {
                            await takeMissedEnd(at: end, of: task, from: batch, in: id)
                        }
                        // The task is over: nothing more comes for this turn,
                        // so it stops looking as if it were going.
                        records[id]?.run = .ended
                        records[id]?.summary.isWorking = false
                        records[id]?.dropReplay()
                        changed(id)
                        return
                    }
                } catch let error as LurosError where error.code == .notFound {
                    // only a message on its way to a new session still works
                    let isSending = records[id]?.isSending == true
                    records[id]?.summary.isWorking = isSending
                    records[id]?.run = .ended
                    changed(id)
                    return
                } catch is CancellationError { return }
                catch {
                    // A lost connection does not discard the cursor or stop a remote turn.
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    /// The end of `task` the conversation read past (`ChatRecord.missedEnd`),
    /// read again from just before it unless `batch` carries it, and taken.
    private func takeMissedEnd(at end: EventSeq, of task: TaskHandle, from batch: TaskEventBatch, in id: UUID) async {
        var event = batch.events.last { $0.seq == end }
        if event == nil {
            event = try? await LurosService.app.attach(task, afterSeq: EventSeq(end.rawValue - 1), waitMilliseconds: 0)
                .events.first
        }
        guard records[id]?.task == task else { return }
        records[id]?.takeMissedEnd(event, at: end)
        if records[id]?.isSending == true {
            // the task has ended; a message on its way opens the next
            records[id]?.summary.isWorking = true
        }
        changed(id)
    }

    /// Sent messages whose echo arrived leave `sending`, in the same
    /// update that adds the event, so the row never blinks out or doubles.
    /// Each echoed attachment is cached as the very one the local row
    /// showed, so its preview does not fade in again. Answers whether any
    /// was echoed.
    @discardableResult
    private func settleSending(in id: UUID, against events: [TaskEvent]) -> Bool {
        guard let draftID = records[id]?.draft.id,
              let echoed = records[id]?.takeEchoed(by: events) else { return false }
        for (draft, event) in echoed {
            // persisted-read: one event's field, nothing written back from it
            let saved = (try? event.payload?["attachments"]?.decode([AgentAttachment].self)) ?? []
            guard saved.count == draft.attachments.count else { continue }
            for (item, local) in zip(saved, draft.attachments) {
                if let path = attachmentPath(item, in: id) {
                    _ = keepAttachment(local, at: path)
                }
            }
        }
        if records[id]?.draft.id != draftID {
            onDraftRestored?(id)
        }
        return !echoed.isEmpty
    }

    /// What a stopped run never took goes back to the composer, ahead of
    /// what was typed since (`DroppedMessages`).
    @objc dynamic private func restoreDropped(_ messages: Set<UUID>, in id: UUID) {
        loadEvents(id)
        guard let events = records[id]?.events, let draft = records[id]?.draft,
              let returned = DroppedMessages.returning(messages, from: events, to: draft, attachment: {
                  attachment($0, in: id)
              })
        else { return }
        records[id]?.draft = returned.draft
        onDraftRestored?(id)
        onUnsentReturned?(id, returned)
    }

    /// `urgent`: written at once rather than after the interval; see `persist`.
    @objc dynamic private func changed(_ id: UUID, urgent: Bool = true) {
        persist(id, urgent: urgent); onChange?()
    }

    /// Writes `id`, atomically and off the main thread (`ChatStore`). An
    /// `urgent` save goes now, or as soon as the write under way ends; any
    /// other waits until `saveInterval` after the last write ended.
    @objc dynamic private func persist(_ id: UUID, urgent: Bool = false) {
        guard records[id] != nil else {
            unsaved.remove(id)
            savesDeferred.removeValue(forKey: id)?.cancel()
            return
        }
        if saving.contains(id) {
            savesPending.insert(id)
            if urgent {
                savesUrgent.insert(id)
            }
            return
        }
        let due = savedAt[id].map { $0 + Self.saveInterval } ?? .now
        if urgent || due <= .now {
            savesDeferred.removeValue(forKey: id)?.cancel()
            write(id)
        } else if savesDeferred[id] == nil {
            savesDeferred[id] = Task { [weak self] in
                try? await Task.sleep(until: due)
                guard !Task.isCancelled, let self else { return }
                savesDeferred[id] = nil
                write(id)
            }
        }
    }

    /// Writes every conversation whose save is waiting for its interval,
    /// before the app is suspended; `drained` is called once none is being
    /// written.
    @objc dynamic func saveNow(drained: @escaping () -> Void) {
        for id in Set(savesDeferred.keys).union(savesPending) {
            persist(id, urgent: true)
        }
        savesDrained.append(drained)
        drainSaves()
    }

    @objc dynamic private func drainSaves() {
        guard saving.isEmpty else { return }
        let drained = savesDrained
        savesDrained = []
        drained.forEach { $0() }
    }

    @objc dynamic private func write(_ id: UUID) {
        guard let record = records[id] else {
            unsaved.remove(id)
            return
        }
        saving.insert(id)
        revision += 1
        let revision = revision
        // A conversation whose events were never read is saved as its head
        // alone, with the count its file holds: writing an empty event list
        // would be writing the history away.
        let writesEvents = !unloadedEvents.contains(id)
        if writesEvents { eventCounts[id] = record.events.count }
        let eventCount = eventCounts[id]
        Task { [store, weak self] in
            do {
                try await store.save(
                    record,
                    revision: revision,
                    writesEvents: writesEvents,
                    eventCount: eventCount,
                )
                self?.saved(id)
            } catch {
                self?.unsaved.insert(id)
                self?.onSaveFailure?(error)
            }
            self?.saveEnded(id)
        }
    }

    /// Writes what changed while `id` was being written.
    @objc dynamic private func saveEnded(_ id: UUID) {
        saving.remove(id)
        savedAt[id] = .now
        if savesPending.remove(id) != nil {
            persist(id, urgent: savesUrgent.remove(id) != nil)
        }
        drainSaves()
    }

    /// Writes again every conversation a failed save left in memory only.
    @objc dynamic func retryUnsaved() {
        for id in unsaved {
            persist(id, urgent: true)
        }
    }

    @objc dynamic private func saved(_ id: UUID) {
        guard unsaved.remove(id) != nil else { return }
        onSaveRecovered?()
        retryUnsaved()
    }

    private func imageMIME(_ data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }
}

private extension DataFolder {
    /// Removes a temporary conversation's one real directory directly inside
    /// `Temporary/`, as `removeProject` does a project's: links inside it are
    /// removed, never followed.
    func removeTemporaryFolder(of id: UUID) throws {
        let folder = root.appendingPathComponent("Temporary/" + id.uuidString)
        var metadata = stat()
        if lstat(folder.path, &metadata) != 0 {
            if errno == ENOENT {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              let rootPath = CanonicalPath.resolve(root.path),
              CanonicalPath.resolve(folder.path) == rootPath + "/Temporary/" + id.uuidString
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: folder)
    }
}
