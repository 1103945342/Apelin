import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// The session host's half of every channel: what the app configured, whether
/// a worker is live, when to bring one back, and the four answers its worker
/// may ask for. Nothing here opens a socket.
///
/// The worker is one process per channel, spawned as mobile with the channel
/// ID as its instance key, so `Caller.worker(.channel, instance:)` is the only
/// thing that says which channel a request came from. A channel never outlives
/// its switch on its own: with `enabled` false, or the conversation gone, or
/// the saved configuration unreadable, it stands down and stays down until the
/// user starts it again.
actor ChannelHost {
    struct Entry {
        var record: ChannelRecord
        var state: ChannelState
        var running = false
        var taskID: TaskID?
        var lastError: ChannelError?
        /// Consecutive failed starts; reset by any state the worker reports.
        var failures = 0
        /// Set while the host itself is stopping the worker, so its exit is
        /// not read as a crash to bring back.
        var stopping = false
        /// A configuration or credential file that would not read: nothing is
        /// retried until the user starts the channel again.
        var needsUser = false
    }

    private var entries: [String: Entry] = [:]
    private let registry: ChannelRegistry
    private let home: String
    private let dataFolder: DataFolder

    /// How long to wait before starting a channel again after its worker
    /// exited: doubling, from one second to a minute, for at most eight tries.
    static let backoffSteps: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60, 60]
    static let maximumFailures = 8

    init(stateDirectory: URL, home: String) {
        registry = ChannelRegistry(directory: stateDirectory.appendingPathComponent("channels", isDirectory: true))
        self.home = home
        dataFolder = DataFolder(home: home)
        load()
    }

    // MARK: - Reading

    /// Every channel on disk. A record that does not read is shown paused with
    /// its reason rather than dropped: the user must see that it is not running.
    private func load() {
        for id in registry.ids() {
            do {
                entries[id] = Entry(record: try registry.load(id), state: .stopped)
            } catch ChannelRegistryError.corrupt {
                entries[id] = Entry(
                    record: ChannelRecord(
                        id: id,
                        kind: .weChatClawBot,
                        enabled: false,
                        projectID: nil,
                        sessionID: nil,
                        allowlist: [],
                        approvalMode: .confirm,
                        openedBy: nil,
                        updatedAt: Date()
                    ),
                    state: .paused,
                    lastError: ChannelError(
                        code: .configurationUnreadable,
                        message: "This channel's settings could not be read. Configure it again."
                    ),
                    needsUser: true
                )
            } catch {
                continue
            }
        }
    }

    func summaries() -> [ChannelSummary] {
        entries.keys.sorted().compactMap { summary($0) }
    }

    func summary(_ id: String) -> ChannelSummary? {
        guard let entry = entries[id] else { return nil }
        return ChannelSummary(
            id: entry.record.id,
            kind: entry.record.kind,
            enabled: entry.record.enabled,
            running: entry.running,
            state: entry.state,
            projectID: entry.record.projectID,
            sessionID: entry.record.sessionID,
            allowlist: ChannelRules.normalizeAllowlist(entry.record.allowlist),
            approvalMode: entry.record.approvalMode,
            hasCredential: entry.record.loggedIn,
            taskID: entry.taskID,
            lastError: entry.lastError,
            updatedAt: entry.record.updatedAt
        )
    }

    func record(_ id: String) -> ChannelRecord? {
        entries[id]?.record
    }

    func accepts(_ id: String) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.record.enabled && !entry.needsUser
    }

    // MARK: - The app's changes

    func configure(
        _ request: ChannelConfigureRequest,
        app: ApprovalMode,
        host: SessionHost
    ) async throws -> ChannelSummary {
        guard ChannelRules.isValidChannelID(request.channelID) else {
            throw ApelinError(.badRequest, "a channel ID is letters, digits, '-' and '_' only")
        }
        var entry = entries[request.channelID] ?? Entry(
            record: ChannelRecord(
                id: request.channelID,
                kind: request.kind ?? .weChatClawBot,
                enabled: false,
                projectID: nil,
                sessionID: nil,
                allowlist: [],
                approvalMode: .confirm,
                openedBy: nil,
                updatedAt: Date()
            ),
            state: .stopped
        )
        if entry.needsUser {
            // The user is configuring it again: what was unreadable is set
            // aside, so saving these settings starts over.
            entry.needsUser = false
            entry.state = .stopped
            entry.lastError = nil
        }
        if let kind = request.kind {
            entry.record.kind = kind
        }
        if let mode = request.approvalMode {
            guard mode != .full else {
                throw ApelinError(.denied, "A channel never runs a conversation in Full mode. Choose Strict or Relaxed.")
            }
            entry.record.approvalMode = mode
        }
        if let allowlist = request.allowlist {
            entry.record.allowlist = ChannelRules.normalizeAllowlist(allowlist)
        }
        if let binding = request.binding {
            switch binding {
            case .unchanged:
                break
            case .clear:
                entry.record.sessionID = nil
                entry.record.openedBy = nil
            case .project(let id):
                if let id, !id.isEmpty {
                    // A project that is not there is refused now rather than
                    // discovered when the first message arrives.
                    _ = try AgentProjects.resolve(home: home, projectID: id, projectName: nil)
                    entry.record.projectID = id
                } else {
                    entry.record.projectID = nil
                }
                entry.record.sessionID = nil
                entry.record.openedBy = nil
            }
        }
        if let enabled = request.enabled, enabled {
            try checkStartable(entry)
            entry.record.enabled = true
        } else if let enabled = request.enabled {
            entry.record.enabled = false
        }

        entry.record.updatedAt = Date()
        try registry.save(entry.record)
        entries[request.channelID] = entry

        if entry.record.enabled {
            try await activate(request.channelID, host: host)
        } else if entry.running {
            await stop(request.channelID, reason: "The channel was turned off.", host: host)
        }
        return summary(request.channelID) ?? ChannelSummary(id: request.channelID)
    }

    func start(_ id: String, host: SessionHost) async throws -> ChannelSummary {
        guard var entry = entries[id] else {
            throw ApelinError(.notFound, "This channel was not configured.")
        }
        try checkStartable(entry)
        entry.record.enabled = true
        entry.record.updatedAt = Date()
        entry.needsUser = false
        entry.failures = 0
        entry.lastError = nil
        try registry.save(entry.record)
        entries[id] = entry
        try await activate(id, host: host)
        return summary(id) ?? ChannelSummary(id: id)
    }

    /// The switch goes off and the worker closes; the login is kept, so the
    /// next start needs no code.
    func stop(_ id: String, reason: String, host: SessionHost) async -> ChannelSummary? {
        guard var entry = entries[id] else { return nil }
        entry.record.enabled = false
        entry.record.updatedAt = Date()
        entry.stopping = true
        entry.running = false
        entry.state = .stopped
        try? registry.save(entry.record)
        entries[id] = entry
        await close(id, host: host)
        if let taskID = entry.taskID {
            await host.registry.finish(taskID, .cancelled, message: reason)
        }
        entry.taskID = nil
        entries[id] = entry
        return summary(id)
    }

    /// Nobody is signed in any more: the worker closes and the login state it
    /// kept on this device is removed. The conversation and the configuration
    /// — project, binding, allowlist — are kept; signing in again resumes the
    /// same chat.
    func logout(_ id: String, host: SessionHost) async throws -> ChannelSummary {
        guard entries[id] != nil else {
            throw ApelinError(.notFound, "This channel was not configured.")
        }
        _ = await stop(id, reason: "The channel was signed out.", host: host)
        if var entry = entries[id] {
            removeLoginState(id)
            entry.record.loggedIn = false
            entry.record.updatedAt = Date()
            entry.state = .stopped
            entry.lastError = nil
            entry.needsUser = false
            try? registry.save(entry.record)
            entries[id] = entry
        }
        return summary(id) ?? ChannelSummary(id: id)
    }

    // MARK: - The worker

    /// What the worker may reach. Called after every start and restart; the
    /// allowlist it gets is the one the host itself checked.
    func binding(instance: String?, host: SessionHost) throws -> ChannelWorkerBinding {
        guard let id = instance, let entry = entries[id] else {
            throw ApelinError(.denied, "This process is not a channel.")
        }
        guard entry.record.enabled, !entry.needsUser else {
            throw ApelinError(.denied, "This channel is not running.")
        }
        guard let taskID = entry.taskID else {
            throw ApelinError(.unavailable, "The channel is still starting.")
        }
        return ChannelWorkerBinding(
            channelID: id,
            taskID: taskID,
            projectID: entry.record.projectID,
            sessionID: entry.record.sessionID,
            allowlist: entry.record.allowlist,
            approvalMode: effectiveMode(entry.record.approvalMode, app: host.appApprovalMode),
            state: entry.state
        )
    }

    /// One inbound message ID, accepted once. The ledger is on disk before the
    /// message goes anywhere, so a crash between the two loses one message
    /// rather than delivering it twice.
    func acceptInbox(channel id: String, messageID: String) throws -> Bool {
        var inbox = try registry.inbox(id)
        guard inbox.accept(messageID) else { return false }
        try registry.saveInbox(inbox, channel: id)
        return true
    }

    /// The conversation the host opened for this channel, recorded on the
    /// channel so a restart finds it instead of opening another.
    func recordSession(_ sessionID: String, channel id: String, taskID: TaskID?) {
        guard var entry = entries[id] else { return }
        entry.record.sessionID = sessionID
        entry.record.openedBy = "channel:\(id)"
        entry.record.updatedAt = Date()
        if let taskID {
            entry.taskID = taskID
        }
        try? registry.save(entry.record)
        entries[id] = entry
    }

    func clearSession(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.record.sessionID = nil
        entry.record.openedBy = nil
        entry.record.updatedAt = Date()
        try? registry.save(entry.record)
        entries[id] = entry
    }

    /// A conversation the channel drives is gone: it stands down instead of
    /// opening another one behind the user's back.
    func sessionGone(_ id: String, host: SessionHost) async {
        guard var entry = entries[id] else { return }
        entry.state = .paused
        entry.lastError = ChannelError(
            code: .sessionGone,
            message: "The conversation this channel drove is gone. Start the channel again after choosing a project."
        )
        entry.needsUser = true
        entry.record.enabled = false
        entry.record.sessionID = nil
        entry.record.openedBy = nil
        entry.record.updatedAt = Date()
        try? registry.save(entry.record)
        entries[id] = entry
        await close(id, host: host)
    }

    /// A project was deleted: every channel bound to it stands down.
    func projectDeleted(_ projectID: String, host: SessionHost) async {
        for id in entries.keys {
            guard entries[id]?.record.projectID == projectID else { continue }
            if var entry = entries[id] {
                entry.state = .paused
                entry.lastError = ChannelError(
                    code: .sessionGone,
                    message: "The project this channel used was deleted."
                )
                entry.needsUser = true
                entry.record.enabled = false
                entry.record.sessionID = nil
                entry.record.openedBy = nil
                entry.record.updatedAt = Date()
                try? registry.save(entry.record)
                entries[id] = entry
            }
            await close(id, host: host)
        }
    }

    // MARK: - Lifecycle

    /// Starts every channel the last run left enabled. Called once, after the
    /// previous run's tasks have been dealt with.
    func restore(host: SessionHost) async {
        for id in entries.keys.sorted() {
            guard var entry = entries[id], entry.record.enabled, !entry.needsUser else { continue }
            do {
                try await activate(id, host: host)
            } catch {
                entry.state = .failed
                entry.lastError = ChannelError(code: .network, message: "The channel could not start.")
                entries[id] = entry
            }
        }
    }

    /// A channel task the previous host left running: brought back under the
    /// same task ID, not marked interrupted.
    func resume(_ record: TaskRegistry.Record, host: SessionHost) async -> Bool {
        guard let id = record.ownerKey, var entry = entries[id], entry.record.enabled, !entry.needsUser else {
            if record.ownerKey != nil {
                await host.registry.finish(record.id, .cancelled, message: "The channel is off.")
            }
            return true
        }
        entry.taskID = record.id
        entries[id] = entry
        do {
            try await activate(id, host: host)
        } catch {
            if var entry = entries[id] {
                entry.state = .failed
                entry.lastError = ChannelError(code: .network, message: "The channel could not start.")
                entries[id] = entry
            }
        }
        return true
    }

    /// The worker went away. A channel that is still switched on is brought
    /// back with a doubling delay, up to eight tries; after that it is failed
    /// and waits for the user.
    func workerExited(channel id: String, host: SessionHost) async {
        guard var entry = entries[id] else { return }
        entry.running = false
        let wasStopping = entry.stopping
        entry.stopping = false
        guard entry.record.enabled, !wasStopping, !entry.needsUser else {
            entry.state = entry.record.enabled ? entry.state : .stopped
            entries[id] = entry
            return
        }
        guard entry.failures < Self.maximumFailures else {
            entry.state = .failed
            entry.lastError = ChannelError(
                code: .network,
                message: "The channel stopped working. Start it again when you are ready."
            )
            entries[id] = entry
            return
        }
        let step = Self.backoffSteps[min(entry.failures, Self.backoffSteps.count - 1)]
        entry.failures += 1
        entry.state = .starting
        entries[id] = entry
        let channelID = id
        let delay = UInt64(step * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            await self.restart(channelID, host: host)
        }
    }

    /// What the worker reports about itself — login state, errors — kept as
    /// the channel's state and passed on to the app through its task events.
    /// A `paused` report is the worker saying only the user can clear it, so
    /// the host switches the channel off and closes the worker instead of
    /// starting it again.
    func observedState(_ payload: JSONValue?, channel id: String, host: SessionHost) async {
        guard var entry = entries[id], let payload else { return }
        let reported = payload["state"]?.stringValue.flatMap(ChannelState.init(rawValue:))
        if let error = payload["error"], let code = error["code"]?.stringValue,
           let code = ChannelErrorCode(rawValue: code)
        {
            entry.lastError = ChannelError(code: code, message: error["message"]?.stringValue ?? "")
        }
        if let reported {
            entry.state = reported
            if reported != .failed, reported != .paused {
                entry.failures = 0
            }
        }
        // A channel that got signed in is one the user wants: the switch says
        // so from then on, and a restart brings it back by itself.
        if reported == .online, !entry.record.enabled {
            entry.record.enabled = true
            entry.record.updatedAt = Date()
            try? registry.save(entry.record)
        }
        if reported == .paused {
            entry.needsUser = true
            entry.record.enabled = false
            entry.record.updatedAt = Date()
            try? registry.save(entry.record)
            entries[id] = entry
            await close(id, host: host)
            if let taskID = entry.taskID {
                await host.registry.finish(
                    taskID,
                    .cancelled,
                    message: entry.lastError?.message ?? "The channel stood down."
                )
            }
            return
        }
        entries[id] = entry
    }

    // MARK: - Private

    private func restart(_ id: String, host: SessionHost) async {
        guard let entry = entries[id], entry.record.enabled, !entry.needsUser, !entry.running else { return }
        do {
            try await activate(id, host: host)
        } catch {
            await workerExited(channel: id, host: host)
        }
    }

    private func activate(_ id: String, host: SessionHost) async throws {
        guard var entry = entries[id] else {
            throw ApelinError(.notFound, "This channel was not configured.")
        }
        guard entry.record.enabled else {
            throw ApelinError(.denied, "This channel is off.")
        }
        guard !entry.needsUser else {
            throw ApelinError(.denied, "This channel needs to be configured again.")
        }
        if let existing = await host.workers.existing(.channel, instance: id), !existing.channel.isClosed {
            entry.running = true
            entries[id] = entry
            return
        }
        let taskID: TaskID
        if let existing = entry.taskID,
           let record = await host.registry.record(existing),
           !record.state.isTerminal
        {
            taskID = existing
        } else {
            taskID = await host.registry.create(kind: .channel, owner: .channel, ownerKey: id).taskID
        }
        entry.taskID = taskID
        entry.state = .starting
        entry.lastError = nil
        entry.stopping = false
        entries[id] = entry
        do {
            let worker = try await host.workers.worker(.channel, instance: id)
            entry.running = !worker.channel.isClosed
            entries[id] = entry
        } catch {
            entry.running = false
            entry.state = .failed
            entry.lastError = ChannelError(code: .network, message: "The channel could not start.")
            entries[id] = entry
            await host.registry.finish(taskID, .failed, message: "The channel could not start.")
            entry.taskID = nil
            entries[id] = entry
            throw ApelinError(.unavailable, "The channel could not start.")
        }
    }

    private func close(_ id: String, host: SessionHost) async {
        if let worker = await host.workers.existing(.channel, instance: id) {
            worker.channel.close()
        }
    }

    private func checkStartable(_ entry: Entry) throws {
        let mode = ChannelApprovalMode(rawValue: entry.record.approvalMode.rawValue) ?? .confirm
        if let problem = ChannelRules.startProblem(allowlist: entry.record.allowlist, mode: mode) {
            switch problem {
            case .emptyAllowlist:
                throw ApelinError(.denied, "A channel with nobody allowed would answer anyone. Add at least one person first.")
            case .tooManyEntries:
                throw ApelinError(.denied, "This channel allows at most \(ChannelRules.maximumAllowlistEntries) people.")
            case .entryTooLong:
                throw ApelinError(.denied, "One of the allowed IDs is too long.")
            default:
                throw ApelinError(.denied, "This channel's allowlist is not usable.")
            }
        }
        guard entry.record.approvalMode != .full else {
            throw ApelinError(.denied, "A channel never runs a conversation in Full mode. Choose Strict or Relaxed.")
        }
        if let projectID = entry.record.projectID {
            _ = try AgentProjects.resolve(home: home, projectID: projectID, projectName: nil)
        }
    }

    /// The mode a channel's conversation opens with: its own, never looser
    /// than the app's. Full on the app's side does not loosen a channel's.
    private func effectiveMode(_ configured: ApprovalMode, app: ApprovalMode) -> ApprovalMode {
        let appMode: ChannelApprovalMode
        switch app {
        case .confirm:
            appMode = .confirm
        case .relaxed, .full:
            appMode = .relaxed
        }
        let channelMode = ChannelApprovalMode(rawValue: configured.rawValue) ?? .confirm
        let mode = ChannelApprovalMode.effectiveMode(configured: channelMode, app: appMode)
        return mode == .confirm ? .confirm : .relaxed
    }

    /// Deletes `<data>/WeChatChannel/<id>` without following a link out of it.
    private func removeLoginState(_ id: String) {
        guard ChannelRules.isValidChannelID(id) else { return }
        let url = dataFolder.weChatChannel.appendingPathComponent(id, isDirectory: true)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return }
        if metadata.st_mode & S_IFMT == S_IFLNK {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
