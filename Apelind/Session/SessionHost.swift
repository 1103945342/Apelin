import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// `apelind-session`: apelind started again in session mode, as a child the
/// launchd job's memory limit does not cover. It owns the task registry and
/// the workers; apelind forwards it every request but `hello`, and it
/// reports to apelind whether it has work, so apelind stays up while it does.
final class SessionHost: @unchecked Sendable {
    let installRoot: String
    /// Mobile's home, which every mobile worker gets as HOME.
    let home: String
    /// Root-only state: task records, approvals, installation records.
    let stateDirectory: URL
    let registry: TaskRegistry
    let workers: WorkerSupervisor
    /// `~/Documents/wiki.qaq.apelin`, as mobile's home spells it.
    let dataFolder: DataFolder
    /// Confirm-mode digests and agent session modes (host-private).
    let approvals: ApprovalLedger
    /// Persisted delegation authority, separate from worker-owned session files.
    let delegations: AgentDelegationStore
    let assignments: AgentAssignmentStore
    /// Artifacts as build workers reported them.
    let artifacts: ArtifactRegistry
    let installations: InstallationStore
    let install: InstallBridge
    let scopes: FileScopes
    let editor: ProtectedEditor
    let terminals: TerminalHost
    let toolHosts: ToolHostSessions
    /// Banners for agent sessions, posted as the app.
    let notices: AgentNotices
    /// Settings ▸ Plugins: the WeChat ClawBot channel — its sign-in, its long
    /// poll, and the conversation each WeChat phone talks in
    /// (`Session/Channel/WeChatChannel`). It is made on first use; what it
    /// asks of a conversation goes through the dispatcher as the app's own
    /// caller, since the reader turned it on and signed in to it there.
    lazy var channels: WeChatChannel = {
        let host = self
        return WeChatChannel(folder: dataFolder.weChatChannel, home: host.home, registry: host.registry) { request, descriptors in
            let handled = await Dispatcher.handle(
                HostRequest(request: request, descriptors: descriptors, caller: .app),
                host: host
            )
            return handled.0
        }
    }()
    /// Resumers by task kind: given a task the previous host left running,
    /// answer true once it is handled — kept, or ended with its own reason.
    /// Every other unfinished task is `interrupted`.
    private var resumers: [TaskKind: @Sendable (TaskRegistry.Record) async -> Bool] = [:]
    private let proxy: WorkerChannel
    private var lastReport: WorkReport?
    /// `session.pid` in the state directory: this process's ID while it runs.
    @objc dynamic private var pidFile: URL {
        stateDirectory.appendingPathComponent("session.pid")
    }

    init(installRoot: String, ownPath: String) {
        self.installRoot = installRoot
        // roothide keeps mobile's home inside the jbroot; rootless uses the
        // system's. The app reckons it the same way, off its own bundle.
        home = RoothideRoot.mobileHome(for: ownPath)
        stateDirectory = URL(
            fileURLWithPath: installRoot == "/" ? "/var/lib/apelin" : installRoot + "/var/lib/apelin",
            isDirectory: true
        )
        registry = TaskRegistry(directory: stateDirectory.appendingPathComponent("tasks", isDirectory: true))
        workers = WorkerSupervisor(installRoot: installRoot, home: home)
        dataFolder = DataFolder(home: home)
        approvals = ApprovalLedger(directory: stateDirectory.appendingPathComponent("approvals", isDirectory: true))
        delegations = AgentDelegationStore(directory: stateDirectory.appendingPathComponent("agent-delegations", isDirectory: true))
        assignments = AgentAssignmentStore(directory: stateDirectory.appendingPathComponent("agent-assignments", isDirectory: true))
        artifacts = ArtifactRegistry(file: stateDirectory.appendingPathComponent("artifacts.json"))
        installations = InstallationStore(
            directory: stateDirectory.appendingPathComponent("installations", isDirectory: true)
        )
        install = InstallBridge(
            paths: InstallBridge.Paths(
                installRoot: installRoot,
                dataFolder: dataFolder.root.path,
                staging: stateDirectory.appendingPathComponent("staging", isDirectory: true)
            ),
            service: IrisinInstallService(),
            registry: registry,
            artifacts: artifacts,
            installations: installations,
            packages: DpkgStatusDatabase(installRoot: installRoot),
            fileLists: DpkgFileLists(installRoot: installRoot),
            approvals: approvals
        )
        scopes = FileScopes(installRoot: installRoot, dataFolder: dataFolder)
        editor = ProtectedEditor(installRoot: installRoot, backups: BackupStore(home: home))
        terminals = TerminalHost(installRoot: installRoot, home: home, scopes: scopes, registry: registry)
        toolHosts = ToolHostSessions(
            installRoot: installRoot,
            home: home,
            attachments: stateDirectory.appendingPathComponent("attachments", isDirectory: true)
        )
        notices = AgentNotices(stateDirectory: stateDirectory, sessions: dataFolder.sessions)
        proxy = WorkerChannel(adopting: WorkerMain.channelDescriptor)
        resumers[.install] = { [install] record in await install.resume(record) }
        let restart = TaskResume(
            registry: registry,
            dispatch: { [unowned self] record, request in
                guard let role = record.owner else {
                    throw ApelinError(.internal, "task \(record.id) has no worker")
                }
                // The previous run's package, if it reported one, is not this run's.
                if record.kind == .build {
                    await artifacts.forget(buildID: record.id)
                }
                let worker = try await workers.worker(role, instance: record.ownerKey)
                return try await worker.call(request, descriptors: [], taskID: record.id, resumed: true).0
            },
            recheck: { [unowned self] caller, request in
                // An agent's build, which carries the digest precheck adds,
                // is never resumed (TaskResume.plan).
                var checked = HostRequest(request: request, descriptors: [], caller: caller)
                guard let refusal = await precheck(&checked) else {
                    return nil
                }
                if case let .failure(error) = refusal.0.result {
                    return error
                }
                return ApelinError(.denied, "\(request.operation.rawValue) was refused")
            }
        )
        resumers[.build] = { record in await restart.resume(record) }
        resumers[.environment] = { record in await restart.resume(record) }
    }

    @objc dynamic func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        var metadata = stat()
        guard fstat(WorkerMain.channelDescriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK else {
            NSLog("apelind-session: start this through apelind")
            exit(EX_USAGE)
        }
        try? FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The host's process name is apelind's, as the kernel takes it from
        // the executable, so `killall` cannot tell the two apart; this file
        // names the one to kill when testing a restart (Documents/Console.md).
        try? Data("\(getpid())\n".utf8).write(to: pidFile, options: .atomic)

        // The channel is taken over before the host is ready. A request that
        // arrives meanwhile is waiting on that gate, not held in a socket
        // nobody reads: the proxy has already written it, so a reader that
        // starts only after `pruneLeftoverToolchains`, the task records and
        // `install.reconcile` leaves the app waiting on work it cannot see.
        let gate = ReadyGate()
        proxy.onRequest { [self] request in
            await gate.wait()
            return await Dispatcher.handle(
                HostRequest(request: request.request, descriptors: request.descriptors, caller: .app),
                host: self
            )
        }
        proxy.onControl { [self] frame in
            if frame.header.name == WorkerControl.shutdown {
                shutdown()
            }
        }
        proxy.onClose { [self] in shutdown() }
        proxy.start()

        Task {
            let started = Date()
            // Reports of the conversations an agent opened go back to the
            // conversation that opened them: the relay reads the children's
            // events from the feed below and hands each message to the opener
            // on this host's own path, never through the app's.
            await AgentReportRelay.shared.configure(state: stateDirectory, account: { [self] opener, reports in
                // Reports remain claims. Persist them before freezing the account
                // text; neither a turn nor its prose certifies acceptance.
                let ledger = try await assignments.read(opener: opener)
                for report in reports where ledger?.groups.contains(where: {
                    $0.assignment(report.childSessionID) != nil
                }) == true {
                    _ = try await assignments.recordReport(report, opener: opener)
                }
                return (try await assignments.read(opener: opener))?.groups.map {
                    AgentReportRelay.snapshotText($0.snapshot())
                }.joined(separator: "\n") ?? "\nNo structured assignment ledger exists for this legacy conversation. Its turn is not acceptance.\n"
            }, nextFinal: { [self] opener in
                try await assignments.pendingFinalAccount(opener: opener)
            }, nextStatus: { [self] opener in
                try await assignments.read(opener: opener)?.groups.first?.snapshot()
            }, acknowledgeFinal: { [self] opener, event in
                _ = try await assignments.acknowledgeFinalAccount(opener: opener, eventID: event)
            }) { [weak self] prompt in
                guard let self else { return false }
                return await self.deliverReportPrompt(prompt)
            }
            // A worker's events and its exit, applied in the order they came:
            // a task per event lets a final `state` overtake the `artifact`
            // before it, and an exit overtake the `state` it followed.
            let feed = TaskEventFeed<WorkerNews> { [self] news in
                switch news {
                case let .event(worker, taskID, kind, payload):
                    // A worker writes only to tasks it was given.
                    guard let record = await registry.record(taskID), record.owner == worker.role,
                          record.ownerKey == worker.key else { return }
                    // A build's package, as the build worker itself reported it.
                    if worker.role == .build, kind == "artifact" {
                        await artifacts.record(event: payload, buildID: taskID)
                    }
                    // The title an agent gave its session, which agentList
                    // names it by for the other conversations of its project.
                    if worker.role == .agent, kind == "title", let key = worker.key,
                       let title = AgentConversationRules.title(payload?["text"]?.stringValue)
                    {
                        await AgentSessionTable.shared.setTitle(title, session: key)
                        await AgentReportRelay.shared.retitled(session: key, title: title)
                    }
                    let appended = await registry.append(taskID, kind: kind, payload: payload)
                    // The turn a conversation an agent opened just ended is
                    // written down before anything waits on a worker: the feed
                    // goes on with the next event.
                    if let appended, worker.role == .agent, let session = worker.key {
                        await AgentReportRelay.shared.observed(
                            sessionID: session,
                            taskID: taskID,
                            event: appended
                        )
                    }
                    await notices.relayed(record, kind: kind, payload: payload)
                    // What a conversation wrote, for the WeChat channel
                    // answering the phone that asked for it. Cheap when no
                    // reply is being collected for that session.
                    if worker.role == .agent {
                        await channels.relayed(sessionID: worker.key, taskID: taskID, kind: kind, payload: payload)
                    }
                case let .exit(worker):
                    await registry.ownerExited(role: worker.role, key: worker.key)
                    if worker.role == .agent {
                        await toolHosts.closeAll(ownedBy: .worker(.agent, instance: worker.key))
                        // A turn its worker never ended is interrupted, and
                        // what that conversation owed its opener is delivered
                        // when that conversation can take it.
                        if let session = worker.key {
                            await AgentReportRelay.shared.workerExited(session: session)
                        }
                    }
                }
            }
            await workers.configure(
                onRequest: { [self] worker, request in
                    await Dispatcher.handle(
                        HostRequest(
                            request: request.request,
                            descriptors: request.descriptors,
                            caller: .worker(worker.role, instance: worker.key)
                        ),
                        host: self
                    )
                },
                onEvent: { worker, frame in
                    guard let taskID = frame.header.taskID, let kind = frame.header.name else { return }
                    let payload = frame.body.isEmpty ? nil : try? JSONCoding.decode(JSONValue.self, from: frame.body)
                    feed.send(.event(worker, taskID, kind, payload))
                },
                onExit: { worker in
                    feed.send(.exit(worker))
                },
                isBusy: { [self] role, key in
                    await registry.hasActiveTask(owner: role, key: key)
                }
            )
            // Resume what the previous host left running, before anything
            // new can start (the workers are configured first: a resumed
            // build's events need somewhere to go); a task nobody can resume
            // ends `interrupted`. The folders removed toolchains left go
            // first, while nothing can install into them yet.
            await install.pruneLeftoverToolchains()
            let pruned = Date()
            var interrupted = 0
            for record in await registry.load() {
                if let resumer = resumers[record.kind], await resumer(record) {
                    continue
                }
                await registry.interrupt(record.id)
                interrupted += 1
                // A conversation's task the last host left running is where a
                // turn it never reported ended: the report says interrupted.
                if record.kind == .agent, let session = record.ownerKey,
                   let ended = await registry.record(record.id)
                {
                    await AgentReportRelay.shared.interrupted(
                        session: session,
                        task: record.id,
                        closing: ended.lastSeq.rawValue
                    )
                }
            }
            // What the last host left undelivered is offered once, to the
            // conversations that can take it now.
            await AgentReportRelay.shared.resume()
            let resumed = Date()
            await install.reconcile()
            // A channel that was on when the host last stopped goes back to
            // reading WeChat; one that was signed out stays off.
            await channels.resume()
            let reconciled = Date()
            func elapsed(_ from: Date, _ to: Date) -> Int {
                Int(to.timeIntervalSince(from) * 1000)
            }
            NSLog(
                "apelind-session: start took %d ms (prune %d, tasks %d with %d interrupted, reconcile %d)",
                elapsed(started, reconciled), elapsed(started, pruned), elapsed(pruned, resumed),
                interrupted, elapsed(resumed, reconciled)
            )
            gate.open()
        }

        // Report work to apelind as it changes, and stop idle workers.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "wiki.qaq.apelind.session.report"))
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [self] in
            Task { await reportWork() }
        }
        timer.activate()
        dispatchMain()
    }

    private func reportWork() async {
        await workers.sweep()
        // Every kind of work: builds, environment tasks, terminals, agent
        // sessions and installs are tasks; workers and tool extensions are
        // processes; a WeChat channel that is on and signed in holds the host
        // up too, so the phone is answered while the app is closed. The proxy
        // counts the connected app itself.
        let holding = await channels.isHolding
        let report = await WorkReport(
            activeTasks: registry.activeCount + (holding ? 1 : 0),
            workers: workers.count,
            toolHosts: toolHosts.count,
            tasksByKind: registry.activeByKind
        )
        guard report != lastReport else { return }
        lastReport = report
        try? proxy.sendControl(WorkerControl.work, body: report)
    }

    @objc dynamic private func shutdown() {
        // Every event is on disk as it comes, and every record change the
        // events do not tell (TaskRegistry); nothing is left to flush.
        Task {
            await terminals.stopAll()
            await toolHosts.stopAll()
            await workers.stopAll()
            // The channel tells WeChat it is stopping, so no message is
            // delivered to a client that is gone.
            await channels.stop()
            AgentRunCode.stopAll()
            unlink(pidFile.path)
            exit(0)
        }
    }

    // MARK: Helpers for the domain handlers

    /// Delivers a report wave to the conversation that opened its children,
    /// on the host's own path: the target is the session the child's lineage
    /// names, `fromSessionID` is always the child's, and nothing of the
    /// reader's — mode, model, standing instructions, files — travels with it.
    /// No approval is spent and no conversation but that one is reached: the
    /// line back to a parent is the lineage the creation itself allowed.
    func deliverReportPrompt(_ prompt: AgentPromptRequest) async -> Bool {
        guard let reports = prompt.reports,
              UUID(uuidString: prompt.sessionID) != nil
        else { return false }
        let opener = prompt.sessionID
        if reports.isEmpty {
            // Only the host relay makes this marker. App and worker request
            // entry points strip reports; a final account cannot be forged by
            // supplying an empty array on their prompt path.
            guard prompt.fromSessionID == opener else { return false }
            do {
                guard try await assignments.read(opener: opener) != nil else { return false }
            } catch { return false }
        }
        // Only back to the opener: every report must be a turn of a
        // conversation this one opened.
        for report in reports {
            let parent = AgentSessionLineage.load(session: report.childSessionID, state: stateDirectory)?
                .parentSessionID
            guard parent == opener else {
                NSLog(
                    "apelind-session: the report of %@ is not a child of %@, so it is not delivered",
                    report.childSessionID,
                    opener
                )
                return false
            }
        }
        guard await AgentSessionTable.shared.entry(opener) != nil,
              let worker = await workers.existing(.agent, instance: opener), !worker.channel.isClosed
        else { return false }
        var wire = prompt
        wire.attachments = nil
        wire.approvalMode = nil
        wire.asksBeforeScreen = nil
        wire.runMode = nil
        wire.promptInjection = nil
        wire.provider = nil
        wire.model = nil
        wire.modelDefaults = nil
        wire.reasoningEffort = nil
        wire.serviceTier = nil
        wire.modelParameters = nil
        wire.source = nil
        guard wire.fromSessionID != nil else { return false }
        do {
            let (reply, _) = try await worker.call(try WireRequest(wire), descriptors: [])
            if case .failure = reply.result {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// Forwards the request to the role's worker and returns its answer.
    func forward(_ request: HostRequest, to role: WorkerRole, instance: String? = nil) async -> HostReply {
        do {
            let worker = try await workers.worker(role, instance: instance)
            return try await worker.call(request.request, descriptors: request.descriptors)
        } catch {
            return request.fail((error as? ApelinError) ?? ApelinError(.unavailable, String(describing: error)))
        }
    }

    /// Registers a task, hands the request to the role's worker with the
    /// task's ID, and answers the `TaskHandle`. The worker answers once it
    /// has accepted the task (its payload is ignored), then emits events and
    /// a final `state`. If it refuses, the task fails and the refusal is the
    /// reply. A `resumable` task's request is kept in its record first
    /// (`TaskResume.plan`), so a host that stops while it runs starts it
    /// again on its next launch.
    func startTask(
        _ request: HostRequest,
        kind: TaskKind,
        role: WorkerRole,
        instance: String? = nil,
        resumable: Bool = false
    ) async -> HostReply {
        let handle = await registry.create(kind: kind, owner: role, ownerKey: instance)
        // An agent reads back only the tasks its session started.
        if case let .worker(.agent, session?) = request.caller {
            await AgentSessionTable.shared.recordStarted(handle.taskID, session: session)
        }
        if resumable {
            await registry.setResume(
                handle.taskID,
                TaskResume.plan(request.request, descriptorCount: request.descriptors.count, caller: request.caller)
            )
        }
        do {
            let worker = try await workers.worker(role, instance: instance)
            let (reply, descriptors) = try await worker.call(
                request.request,
                descriptors: request.descriptors,
                taskID: handle.taskID
            )
            if case let .failure(error) = reply.result {
                await registry.finish(handle.taskID, .failed, message: error.description)
                return (reply, descriptors)
            }
            return (.success(request.requestID, handle), [])
        } catch {
            let failure = (error as? ApelinError) ?? ApelinError(.unavailable, String(describing: error))
            await registry.finish(handle.taskID, .failed, message: failure.description)
            return request.fail(failure)
        }
    }

    /// Serves any attach request from the registry.
    func attach<R: TaskAttachRequest>(_ request: HostRequest, _: R.Type) async -> HostReply {
        await request.serve(R.self) { attach in
            try await registry.attach(
                attach.taskID,
                as: R.operation,
                afterSeq: attach.afterSeq,
                waitMilliseconds: attach.waitMilliseconds
            )
        }
    }

    /// Serves any cancel request: marks it, tells the owning worker, and
    /// ends a task no worker is serving.
    func cancel<R: TaskCancelRequest>(_ request: HostRequest, _: R.Type) async -> HostReply {
        await request.serve(R.self) { cancel in
            let record = try await registry.requestCancel(cancel.taskID)
            guard !record.state.isTerminal else { return Acknowledged() }
            if let role = record.owner, let worker = await workers.existing(role, instance: record.ownerKey) {
                try worker.channel.sendControl(WorkerControl.cancel, taskID: cancel.taskID)
            } else {
                await registry.finish(cancel.taskID, .cancelled)
            }
            return Acknowledged()
        }
    }
}

/// What a worker tells the host outside a reply, in arrival order.
enum WorkerNews: Sendable {
    case event(WorkerProcess, TaskID, String, JSONValue?)
    case exit(WorkerProcess)
}

/// Holds a request until the host has finished starting, then lets it go.
///
/// The channel is read from the first moment — the proxy wrote its request
/// to the socket as soon as it had one — so a request that arrives during
/// the start waits here instead of in a socket buffer nothing drains. Its
/// wait is what the app measures as the background service not answering.
final class ReadyGate: @unchecked Sendable {
    private let lock = PthreadLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    /// Returns once the host has finished starting. A request waiting here
    /// is a request the app has already sent, so all of them are freed, and
    /// one arriving after the release does not wait at all.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed: Bool = lock.withLock {
                guard !opened else { return true }
                waiters.append(continuation)
                return false
            }
            // Resumed outside the lock: a continuation resumed while the
            // lock is held runs its task, which may want the gate again.
            if proceed { continuation.resume() }
        }
    }

    /// Releases every request waiting; later ones find the gate open.
    func open() {
        let freed: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        NSLog("apelind-session: ready, %d request(s) waited for the start", freed.count)
        freed.forEach { $0.resume() }
    }
}
