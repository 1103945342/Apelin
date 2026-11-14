import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// The app's terminals: one `TerminalSession` per `ptyOpen`, its output
/// numbered into a `terminal` task (so a reattach replays the screen), its
/// I/O handed to the app on `ptyAttach{wantsDescriptor}`. M1 has no root
/// shell: the shell runs as mobile whenever the host is root.
actor TerminalHost {
    static let maximumSessions = 32
    private static let sizeRange = 1 ... 1000
    /// What one terminal keeps of the shell's output in its task's log: the
    /// last 2 MiB the shell wrote, and — since each output event stores its
    /// bytes as base64 and as text — at most 6 MiB of what is actually held,
    /// over at most 4096 events. Past that the oldest whole events are dropped
    /// and the log is rewritten, so a shell that floods bounds itself instead
    /// of the host. Only terminals set a budget; every other task keeps its
    /// log whole (`TaskRegistry.terminalHistory` is the same budget, applied to
    /// a log a host reads back).
    static let outputHistory = TaskRegistry.terminalHistory

    private let installRoot: String
    private let home: String
    private let scopes: FileScopes
    private let registry: TaskRegistry
    private let queue = DispatchQueue(label: "wiki.qaq.apelind.terminal")
    private var sessions: [String: TerminalSession] = [:]
    /// Shells spawned whose task is still being created, so not yet in `sessions`.
    private var opening = 0

    init(installRoot: String, home: String, scopes: FileScopes, registry: TaskRegistry) {
        self.installRoot = installRoot
        self.home = home
        self.scopes = scopes
        self.registry = registry
    }

    var count: Int {
        sessions.count
    }

    /// Where a terminal starts, and the project whose environment it gets.
    struct Start: Equatable {
        var path: String
        var project: String?
        /// The folder was asked for, so the shell must enter it or fail.
        var chosen: Bool
    }

    func open(_ request: PtyOpenRequest) async throws -> PtyOpenResponse {
        guard sessions.count + opening < Self.maximumSessions else {
            throw ApelinError(.unavailable, "too many terminals are open")
        }
        try Self.checkSize(columns: request.columns, rows: request.rows)
        let start = try directory(for: request)
        let launch = try Self.launch(
            installRoot: installRoot,
            home: home,
            directory: start.path,
            project: start.project,
            columns: request.columns,
            rows: request.rows,
            requiresDirectory: start.chosen,
        )
        let session: TerminalSession
        do {
            session = try TerminalSession.spawn(launch, queue: queue)
        } catch {
            throw ApelinError(.unavailable, "the terminal did not start: \(error)")
        }

        // Everything above is synchronous; this await is where other opens can
        // run, so the shell holds its place against the limit across it.
        opening += 1
        let handle = await registry.create(kind: .terminal, owner: nil)
        opening -= 1
        await registry.setHistoryBudget(
            handle.taskID,
            rawBytes: Self.outputHistory.rawBytes,
            storedBytes: Self.outputHistory.storedBytes,
            events: Self.outputHistory.events,
        )
        let id = handle.taskID.rawValue
        sessions[id] = session
        var started: [String: JSONValue] = [
            "pid": .number(Double(session.pid)),
            "shell": .string(launch.shell),
            "cwd": .string(launch.workingDirectory),
        ]
        if let project = start.project {
            started["project"] = .string(project)
        }
        if let credentials = ProcessCredentials(pid: session.pid) {
            started["uid"] = .number(Double(credentials.uid))
            started["gid"] = .number(Double(credentials.gid))
        }
        await registry.append(handle.taskID, kind: "started", payload: .object(started))

        // One consumer, so events are numbered in the order the bytes came.
        let registry = registry
        let taskID = handle.taskID
        let (events, sink) = AsyncStream<OutputPump.Event>.makeStream()
        let pump = OutputPump(
            stream: sink,
            pause: { session.pauseOutput() },
            resume: { session.resumeOutput() },
        )
        Task { [weak self] in
            var crash: Int32?
            for await event in events {
                await registry.append(taskID, kind: event.kind, payload: event.payload)
                pump.settled(event.bytes)
                if event.kind == "exit",
                   let signal = event.payload["signal"]?.doubleValue,
                   Self.crashSignals.contains(Int32(signal))
                {
                    crash = Int32(signal)
                }
            }
            // Closing a terminal ends it with HUP, TERM or KILL, and a shell
            // may exit with any status; a shell that crashed did not succeed.
            if let crash {
                await registry.finish(
                    taskID,
                    .failed,
                    message: "the shell crashed with signal \(crash) (\(String(cString: strsignal(crash))))",
                )
            } else {
                await registry.finish(taskID, .succeeded)
            }
            await self?.forget(id)
        }
        session.start(
            onOutput: { data in
                var payload: [String: JSONValue] = ["base64": .string(data.base64EncodedString())]
                var stored = payload["base64"]?.stringValue?.utf8.count ?? 0
                if let text = String(data: data, encoding: .utf8) {
                    payload["text"] = .string(text)
                    stored += text.utf8.count
                }
                pump.send(.init(kind: "output", payload: .object(payload), bytes: stored))
            },
            onExit: { status in
                var payload: [String: JSONValue] = [:]
                let signal = status & 0x7F
                if signal == 0 {
                    payload["status"] = .number(Double((status >> 8) & 0xFF))
                } else {
                    payload["signal"] = .number(Double(signal))
                }
                pump.send(.init(kind: "exit", payload: .object(payload), bytes: 0))
                sink.finish()
            },
        )
        if let input = request.initialInput, !input.isEmpty {
            // After the shell has had a moment to set the terminal up.
            queue.asyncAfter(deadline: .now() + 0.3) { session.write(Data(input.utf8)) }
        }
        return PtyOpenResponse(sessionID: id, task: handle)
    }

    /// The folder a terminal starts in. The app names one of three things: a
    /// project and optionally a folder inside it, a folder it picked when there
    /// is no project, or nothing at all (mobile's home). Every decision is made
    /// on canonical paths, so neither `..` nor a link can lead out of the
    /// project, and a folder that is not there is an error rather than a quiet
    /// start in home.
    func directory(for request: PtyOpenRequest) throws -> Start {
        if request.projectID != nil, request.workingDirectory != nil {
            throw ApelinError(.badRequest, "a terminal starts in a project or in a chosen folder, not both")
        }
        if request.relativePath != nil, request.projectID == nil {
            throw ApelinError(.badRequest, "relativePath names a folder inside a project, so it needs a projectID")
        }
        if let project = request.projectID {
            guard case let .directory(root) = try scopes.resolve(project, caller: .app) else {
                throw ApelinError(.badRequest, "projectID does not name a project")
            }
            return Start(
                path: try Self.subdirectory(request.relativePath, inside: root),
                project: root,
                chosen: true,
            )
        }
        if let chosen = request.workingDirectory {
            return Start(path: try Self.folder(chosen), project: nil, chosen: true)
        }
        return Start(path: home, project: nil, chosen: false)
    }

    /// `relativePath` inside a project: a plain relative path that stays there
    /// after links are resolved, and a folder rather than a file.
    static func subdirectory(_ relativePath: String?, inside root: String) throws -> String {
        guard let root = CanonicalPath.resolve(root) else {
            throw ApelinError(.notFound, "the project's folder does not exist")
        }
        guard let relative = relativePath, !relative.isEmpty, relative != "." else { return root }
        guard CanonicalPath.isPlainRelative(relative) else {
            throw ApelinError(.badRequest, "\(relative) is not a plain relative path inside the project")
        }
        guard let folder = CanonicalPath.resolve(root + "/" + relative) else {
            throw ApelinError(.notFound, "the project has no folder \(relative)")
        }
        guard CanonicalPath.isCanonical(folder, inside: root) else {
            throw ApelinError(.denied, "\(relative) leads outside the project")
        }
        guard isDirectory(folder) else {
            throw ApelinError(.badRequest, "\(relative) is not a folder inside the project")
        }
        return folder
    }

    /// A folder the app picked, without a project: absolute, there, and a
    /// folder.
    static func folder(_ path: String) throws -> String {
        guard !path.isEmpty, !CanonicalPath.containsNUL(path), path.hasPrefix("/") else {
            throw ApelinError(.badRequest, "a working directory is an absolute path")
        }
        guard let folder = CanonicalPath.resolve(path) else {
            throw ApelinError(.notFound, "there is no folder at \(path)")
        }
        guard isDirectory(folder) else {
            throw ApelinError(.badRequest, "\(path) is not a folder")
        }
        return folder
    }

    private static func isDirectory(_ path: String) -> Bool {
        var metadata = stat()
        return stat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR
    }

    /// A socket to the terminal for the app: its typing, and — unless
    /// `inputOnly` — the shell's output as it comes.
    func descriptor(for taskID: TaskID, inputOnly: Bool = false) throws -> OwnedDescriptor {
        guard let session = sessions[taskID.rawValue] else {
            throw ApelinError(.notFound, "no open terminal \(taskID)")
        }
        do {
            return try OwnedDescriptor(adopting: session.attachPeer(inputOnly: inputOnly))
        } catch {
            throw ApelinError(.internal, "\(error)")
        }
    }

    /// The same socket, or nil once the shell has ended: its task's events —
    /// the last of what it wrote, and why it ended — are still the answer, and
    /// there is no live terminal left to type into.
    func descriptorIfOpen(for taskID: TaskID, inputOnly: Bool = false) -> OwnedDescriptor? {
        guard let session = sessions[taskID.rawValue] else { return nil }
        return try? OwnedDescriptor(adopting: session.attachPeer(inputOnly: inputOnly))
    }

    func resize(_ request: PtyResizeRequest) throws -> Acknowledged {
        guard let session = sessions[request.sessionID] else {
            throw ApelinError(.notFound, "no open terminal \(request.sessionID)")
        }
        try Self.checkSize(columns: request.columns, rows: request.rows)
        session.resize(columns: UInt16(request.columns), rows: UInt16(request.rows))
        return Acknowledged()
    }

    func close(_ request: PtyCloseRequest) throws -> Acknowledged {
        guard let session = sessions[request.sessionID] else {
            throw ApelinError(.notFound, "no open terminal \(request.sessionID)")
        }
        session.terminate()
        return Acknowledged()
    }

    func stopAll() {
        sessions.values.forEach { $0.terminate(grace: 0.5) }
    }

    private static func checkSize(columns: Int, rows: Int) throws {
        guard sizeRange.contains(columns), sizeRange.contains(rows) else {
            throw ApelinError(
                .badRequest,
                "columns and rows must each be \(sizeRange.lowerBound) to \(sizeRange.upperBound)",
            )
        }
    }

    private func forget(_ id: String) {
        sessions[id] = nil
    }

    /// Signals a shell dies of only when it crashed.
    static let crashSignals: Set<Int32> = [
        SIGSEGV,
        SIGBUS,
        SIGILL,
        SIGABRT,
        SIGTRAP,
        SIGFPE,
        SIGSYS,
    ]

    /// The shell, its arguments and the environment `login` would have set,
    /// with the development environment of `project` (a project folder, or
    /// nil for none) on top: its toolchain first on `PATH`, `SDKROOT` and
    /// `IPHONEOS_DEPLOYMENT_TARGET`, as the agent's shell_run gets them. A
    /// login shell's `/etc/profile` replaces `PATH`; the package's profile
    /// snippet puts the toolchain back from `APELIN_TOOLCHAIN_BIN`.
    static func launch(
        installRoot: String,
        home: String,
        directory: String,
        project: String? = nil,
        columns: Int,
        rows: Int,
        requiresDirectory: Bool = false,
    ) throws -> TerminalSession.Launch {
        let root = installRoot == "/" ? "" : installRoot
        let candidates = [
            "\(root)/usr/bin/bash",
            "\(root)/bin/bash",
            "\(root)/usr/bin/zsh",
            "\(root)/bin/zsh",
            "\(root)/bin/sh",
            "/bin/sh",
        ]
        guard let shell = candidates.first(where: { access($0, X_OK) == 0 }) else {
            throw ApelinError(.unavailable, "no shell is installed")
        }
        let name = (shell as NSString).lastPathComponent
        let arguments = name == "sh" ? ["-i"] : ["-il"]
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Apelin",
            // This shell is Apelin's own: the login profile snippet shortens
            // its prompt only when it is set, so a terminal opened anywhere
            // else keeps the prompt its user configured.
            "APELIN_TERMINAL": "1",
            "HOME": home,
            "USER": "mobile",
            "LOGNAME": "mobile",
            "SHELL": shell,
            // iOS ships one locale, UTF-8, in /usr/share/locale; no LANG.
            // Under `LANG=en_US.UTF-8` setlocale fails and readline 8.2
            // dereferences the null it answers: bash crashed before its
            // first prompt and the terminal showed nothing.
            "LC_CTYPE": "UTF-8",
            // The agent's file tools refuse to lay out a bare repository,
            // and the user's git here takes none it finds by walking up
            // either: a pager or hook in one would run as mobile. Config
            // given through the environment is protected, as on the command
            // line, so a repository's own config cannot turn it back off.
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "safe.bareRepository",
            "GIT_CONFIG_VALUE_0": "explicit",
        ]
        let path = [
            "\(root)/usr/local/bin",
            "\(root)/usr/bin",
            "\(root)/bin",
            "\(root)/usr/sbin",
            "\(root)/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let development = DevelopmentEnvironment.prepared(home: home, projectDirectory: project)
        environment.merge(development.variables(basePath: path)) { _, prepared in prepared }
        return TerminalSession.Launch(
            shell: shell,
            arguments: arguments,
            environment: environment,
            identity: geteuid() == 0 ? .mobile : nil,
            workingDirectory: directory,
            fallbackDirectory: home,
            requiresDirectory: requiresDirectory,
            columns: UInt16(columns),
            rows: UInt16(rows),
        )
    }
}

/// The one place a terminal's output waits for the task registry. It is
/// bounded: past the high-water mark the pty stops being read, so the kernel's
/// buffer holds the bytes and then the shell waits on its next write; below
/// the low-water mark it is read again. Nothing is dropped, and a shell that
/// floods has no way to grow the host's memory with output nobody has numbered
/// yet.
final class OutputPump: @unchecked Sendable {
    struct Event: Sendable {
        var kind: String
        var payload: JSONValue
        /// What the event costs the pump: the bytes it holds in memory.
        var bytes: Int
    }

    static let highWaterBytes = 1 << 20
    static let lowWaterBytes = 1 << 18

    private let lock = NSLock()
    private let stream: AsyncStream<Event>.Continuation
    private let pause: @Sendable () -> Void
    private let resume: @Sendable () -> Void
    private var pending = 0
    private var paused = false

    init(
        stream: AsyncStream<Event>.Continuation,
        pause: @escaping @Sendable () -> Void,
        resume: @escaping @Sendable () -> Void,
    ) {
        self.stream = stream
        self.pause = pause
        self.resume = resume
    }

    /// Queues one event, and stops the pty from being read when too much is
    /// waiting.
    func send(_ event: Event) {
        lock.lock()
        pending += event.bytes
        let stop = !paused && pending >= Self.highWaterBytes
        if stop { paused = true }
        lock.unlock()
        if stop { pause() }
        stream.yield(event)
    }

    /// The consumer has numbered an event: room for more.
    func settled(_ bytes: Int) {
        lock.lock()
        pending = max(0, pending - bytes)
        let go = paused && pending <= Self.lowWaterBytes
        if go { paused = false }
        lock.unlock()
        if go { resume() }
    }
}
