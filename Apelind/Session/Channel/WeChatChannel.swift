import ApelinCore
import ApelinProtocol
import Foundation

/// The WeChat ClawBot channel, held by the session host: the sign-in whose
/// code the app draws, the long poll that reads messages, and the
/// conversation each WeChat peer talks in.
///
/// It is an actor because three things reach it at once — the app's page
/// (status, sign in, the typed number), the poll loops, and the session
/// host's own event feed. Every network call is awaited inside it, which
/// releases the actor while it runs, so a status read never waits behind a
/// 45-second long poll.
///
/// What it asks of a conversation goes through `route`, which the host fills
/// with the dispatcher and the app's own caller: the reader turned the
/// channel on and signed in to it in Settings, so its messages are the
/// reader's messages. An approval is answered here as it is in the app —
/// a word for yes and one for no — except one that runs as root, which takes
/// the device owner's check in Apelin. The asks are kept on disk as well as
/// in memory, so a reply is still read as one after the host restarts.
///
/// The credential lives in `<data>/WeChatChannel/channel.json`, written
/// mobile's own; nothing returns it, logs it or puts it in an error.
actor WeChatChannel {
    /// What one WeChat peer's message asks of the host: a request, answered
    /// through the dispatcher as the app's.
    typealias Route = @Sendable (WireRequest, [OwnedDescriptor]) async -> WireReply

    /// What a conversation this channel opens is marked with, so the app
    /// lists it too (`AgentOpenRequest.origin`).
    static let origin = ChatChannel.weChat

    /// How long one status poll waits before asking again.
    static let pollInterval: UInt64 = 1_000_000_000
    /// How long the listener waits after a failed poll.
    static let retryInterval: UInt64 = 3_000_000_000

    /// What the channel keeps: its configuration and its credential.
    struct Record: Codable, Sendable, Equatable {
        var enabled = false
        var botToken: String?
        var baseURL: String?
        var botID: String?
        var userID: String?
        var projectName: String?
        var approvalMode: ApprovalMode = .confirm
        /// What Settings ▸ Models has enabled, by provider id, as the app last
        /// told the host: `/model` offers these and nothing else.
        var enabledModels: [String: [String]]?
        /// The language the app's interface is in, as the app reported it:
        /// what every reply is written in. Nil until the app says.
        var language: String?
        var syncBuffer: String?
        var signedInAt: Date?

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            botToken = try container.decodeIfPresent(String.self, forKey: .botToken)
            baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
            botID = try container.decodeIfPresent(String.self, forKey: .botID)
            userID = try container.decodeIfPresent(String.self, forKey: .userID)
            projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
            approvalMode = try container.decodeIfPresent(ApprovalMode.self, forKey: .approvalMode) ?? .confirm
            enabledModels = try container.decodeIfPresent([String: [String]].self, forKey: .enabledModels)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            syncBuffer = try container.decodeIfPresent(String.self, forKey: .syncBuffer)
            signedInAt = try container.decodeIfPresent(Date.self, forKey: .signedInAt)
        }
    }

    /// One WeChat account and the conversation it talks in, kept so the same
    /// phone returns to the same history.
    struct Peer: Codable, Sendable, Equatable {
        var userID: String
        var sessionID: String
        /// The UUID of the conversation's workspace under `Temporary/`, for a
        /// peer the channel holds no project for: the same one every time,
        /// or reopening it would find another folder.
        var temporaryID: String?
        /// The project this phone's conversations are opened in
        /// (`/workspace`); nil is General Chat.
        var projectName: String?
        /// What `/model` and `/effort` chose here. Nil leaves the
        /// conversation's own model alone, which is what a conversation the
        /// phone did not open keeps.
        var provider: AgentProvider?
        var model: String?
        var effort: AgentReasoningEffort?
        var tier: AgentServiceTier?
        var title: String?
        var updatedAt: Date

        init(
            userID: String,
            sessionID: String,
            temporaryID: String?,
            projectName: String? = nil,
            title: String?,
            updatedAt: Date = Date()
        ) {
            self.userID = userID
            self.sessionID = sessionID
            self.temporaryID = temporaryID
            self.projectName = projectName
            self.title = title
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case userID
            case sessionID
            case temporaryID
            case projectName
            case provider
            case model
            case effort
            case tier
            case title
            case updatedAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userID = try container.decode(String.self, forKey: .userID)
            sessionID = try container.decode(String.self, forKey: .sessionID)
            temporaryID = try container.decodeIfPresent(String.self, forKey: .temporaryID)
            projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
            provider = try container.decodeIfPresent(AgentProvider.self, forKey: .provider)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            effort = try container.decodeIfPresent(AgentReasoningEffort.self, forKey: .effort)
            tier = try container.decodeIfPresent(AgentServiceTier.self, forKey: .tier)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        }
    }

    private struct Login: Sendable {
        var qrcode: String
        var content: String
        var baseURL: URL
        var pendingCode: String?
    }

    /// A reply being written: the turn's text as its events arrive.
    private struct Reply: Sendable {
        var userID: String
        var contextToken: String?
        var text: String
        /// Messages the conversation took and has not answered yet. The
        /// agent queues a message that arrives during a run, and answers it
        /// in a turn of its own.
        var turns: Int
    }

    /// An approval or a question pushed to a phone, waiting for the reply.
    private struct PendingAsk: Sendable {
        var ask: ChannelAsk
        var contextToken: String?
        /// The phone it was sent to, which the file keeps too.
        var userID: String
    }

    /// A message as the conversation takes it: what was written, the notes
    /// about what came with it, and the files themselves.
    private struct Incoming: Sendable {
        var text: String
        var notes: [String] = []
        var attachments: [AgentInputAttachment] = []
        var descriptors: [OwnedDescriptor] = []
    }

    private let folder: URL
    /// Mobile's home, and the host's task registry: what `/sessions` lists.
    private let home: String
    private let registry: TaskRegistry
    private let route: Route
    private var record: Record
    private var peers: PreservedList<Peer>
    private var login: Login?
    private var loginTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var replies: [String: Reply] = [:]
    private var phase: ChannelPhase = .off
    private var message: String?
    private var listening = false
    private var lastMessageAt: Date?
    /// The approvals and questions a phone has been asked, by the
    /// conversation each belongs to: what waits is the run's, and the phone
    /// that talks in that conversation is the one answering — whatever id
    /// its messages arrive under.
    private var pendingAsks: [String: PendingAsk] = [:]
    /// The thread a phone's messages came in on, so an ask that arrives
    /// later still answers in the same one.
    private var lastContextTokens: [String: String] = [:]
    private var clientCache: (base: String, token: String, client: IlinkClient)?
    /// The list a phone was shown by `/sessions`, and when: its numbers are
    /// what `/use` takes, so they must not move between two messages.
    private var sessionList: (taken: Date, briefs: [ChannelDirectory.SessionBrief])?
    /// The models a phone was shown by `/model`, kept the same way.
    private var modelList: (taken: Date, models: [ChannelModel])?

    init(folder: URL, home: String, registry: TaskRegistry, route: @escaping Route) {
        self.folder = folder
        self.home = home
        self.registry = registry
        self.route = route
        record = Self.loadRecord(folder)
        peers = Self.loadPeers(folder)
        pendingAsks = Self.loadAsks(folder)
        if !pendingAsks.isEmpty {
            Self.trace("\(pendingAsks.count) ask(s) kept from the last run", folder: folder)
        }
    }

    /// What every reply is written in: the language the app's own interface
    /// is in, as the app reported it, else the phone's own. The host's
    /// locale is never it — a daemon reads the system's, not the app's.
    private var replyLanguage: String {
        record.language.map(ChannelReplies.canonical) ?? ChannelReplies.language
    }

    // MARK: What the app reads

    func state() -> ChannelState {
        ChannelState(
            phase: phase,
            enabled: record.enabled,
            qrContent: qrContent(),
            account: record.botID,
            projectName: record.projectName,
            approvalMode: record.approvalMode,
            message: message,
            listening: listening,
            signedInAt: record.signedInAt,
            lastMessageAt: lastMessageAt
        )
    }

    /// Whether the channel is holding the host up: turned on and signed in.
    var isHolding: Bool {
        record.enabled && record.botToken != nil
    }

    private func qrContent() -> String? {
        switch phase {
        case .starting, .waitingForScan, .scanned, .needsCode:
            login?.content
        case .off, .signedIn, .failed:
            nil
        }
    }

    // MARK: What the app asks for

    func signIn() async -> ChannelState {
        record.enabled = true
        saveRecord()
        await startSignIn()
        return state()
    }

    func verify(_ code: String) -> ChannelState {
        guard var login else { return state() }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return state() }
        login.pendingCode = trimmed
        self.login = login
        message = nil
        return state()
    }

    func configure(
        enabled: Bool?,
        projectName: String?,
        approvalMode: ApprovalMode?,
        enabledModels: [String: [String]]? = nil,
        language: String? = nil,
        clearsProject: Bool,
    ) async -> ChannelState {
        if let enabled {
            record.enabled = enabled
        }
        if let approvalMode {
            record.approvalMode = approvalMode
        }
        if let enabledModels {
            record.enabledModels = enabledModels
            // What `/model` last listed was asked under the previous list.
            modelList = nil
        }
        if let language, !language.isEmpty {
            // Every reply changes with it, so nothing is kept.
            record.language = language
            modelList = nil
            sessionList = nil
        }
        if clearsProject {
            record.projectName = nil
        } else if let projectName {
            record.projectName = projectName
        }
        saveRecord()
        if record.enabled {
            if record.botToken != nil {
                startListening()
            } else if loginTask == nil {
                await startSignIn()
            }
        } else {
            await stopListening()
            message = nil
        }
        return state()
    }

    func signOut() async -> ChannelState {
        await stopListening()
        loginTask?.cancel()
        loginTask = nil
        login = nil
        if record.botToken != nil, let client = signedClient() {
            try? await client.notifyStop()
        }
        record.botToken = nil
        record.botID = nil
        record.userID = nil
        record.baseURL = nil
        record.syncBuffer = nil
        record.signedInAt = nil
        record.enabled = false
        saveRecord()
        // A new sign-in talks under other ids, so nothing kept here can be
        // answered any more.
        pendingAsks.removeAll()
        saveAsks()
        phase = .off
        message = nil
        return state()
    }

    /// Called once the host has started: a channel that was on when the host
    /// stopped goes back to reading, without asking for a new code.
    func resume() async {
        guard record.enabled else {
            phase = .off
            return
        }
        if record.botToken != nil {
            startListening()
        } else {
            phase = .off
            message = "Sign in to turn this channel on."
        }
    }

    /// The host is going away: tell WeChat, and stop the loops.
    func stop() async {
        await stopListening()
        loginTask?.cancel()
        loginTask = nil
    }

    // MARK: Signing in

    private func startSignIn() async {
        loginTask?.cancel()
        loginTask = nil
        login = nil
        phase = .starting
        message = nil
        let client = IlinkClient()
        do {
            let code = try await client.requestQRCode(localTokens: [record.botToken].compactMap { $0 })
            let login = Login(qrcode: code.qrcode, content: code.content, baseURL: client.baseURL, pendingCode: nil)
            self.login = login
            phase = .waitingForScan
            loginTask = Task { [weak self] in
                await self?.pollStatus(login)
            }
        } catch {
            fail(error)
        }
    }

    /// Polls the code's state until the reader's phone answers, the code
    /// expires, or the channel is told to stop.
    private func pollStatus(_ code: Login) async {
        var current = code
        while !Task.isCancelled {
            do {
                let poll = try await IlinkClient(baseURL: current.baseURL).loginStatus(
                    current.qrcode,
                    verifyCode: current.pendingCode
                )
                switch poll.status {
                case .wait:
                    phase = .waitingForScan
                case .scaned:
                    phase = .scanned
                    // A number the server accepted is not sent again.
                    current.pendingCode = nil
                    login = current
                case .needVerifyCode:
                    phase = .needsCode
                    message = "Enter the number WeChat shows on the phone."
                case .scanedButRedirect:
                    if let host = poll.redirectHost, let url = URL(string: "https://" + host) {
                        current.baseURL = url
                        login = current
                    }
                case .expired:
                    // One more code, then it is the reader's to start again.
                    phase = .failed
                    message = "The code expired. Start again to show a new one."
                    login = nil
                    loginTask = nil
                    return
                case .verifyCodeBlocked:
                    phase = .failed
                    message = "WeChat refused too many numbers. Wait a while, then start again."
                    login = nil
                    loginTask = nil
                    return
                case .bindedRedirect:
                    phase = .failed
                    message = "This WeChat account is already connected to an Apelin. Sign out there first, then start again."
                    login = nil
                    loginTask = nil
                    return
                case .confirmed:
                    await finishSignIn(poll)
                    return
                }
            } catch {
                phase = .failed
                message = (error as? IlinkFailure)?.message ?? String(describing: error)
                login = nil
                loginTask = nil
                return
            }
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    private func finishSignIn(_ poll: IlinkLoginPoll) async {
        guard let token = poll.botToken, !token.isEmpty else {
            phase = .failed
            message = "WeChat confirmed the sign-in but sent no credential. Try again."
            return
        }
        record.botToken = token
        record.botID = poll.botID
        record.userID = poll.userID
        record.baseURL = poll.baseURL
        record.syncBuffer = nil
        record.signedInAt = Date()
        record.enabled = true
        saveRecord()
        login = nil
        loginTask = nil
        phase = .signedIn
        message = nil
        startListening()
    }

    // MARK: Reading messages

    private func startListening() {
        guard listenTask == nil, record.botToken != nil else { return }
        phase = .signedIn
        listening = true
        listenTask = Task { [weak self] in
            await self?.listen()
        }
    }

    private func stopListening() async {
        listenTask?.cancel()
        listenTask = nil
        listening = false
    }

    /// The long poll: everything WeChat has for this bot, one request at a
    /// time, with the buffer that keeps a restart from reading a message
    /// twice.
    private func listen() async {
        guard let client = signedClient() else {
            listening = false
            return
        }
        try? await client.notifyStart()
        var buffer = record.syncBuffer ?? ""
        while !Task.isCancelled {
            do {
                let updates = try await client.updates(buffer: buffer)
                if let next = updates.buffer, !next.isEmpty {
                    buffer = next
                    record.syncBuffer = next
                    saveRecord()
                }
                for incoming in updates.messages {
                    await handle(incoming)
                }
            } catch {
                message = (error as? IlinkFailure)?.message ?? String(describing: error)
                try? await Task.sleep(nanoseconds: Self.retryInterval)
            }
        }
        listening = false
    }

    /// One message: a text (or a transcribed voice) from a phone becomes a
    /// user message in that phone's conversation, and the turn behind it is
    /// what gets answered.
    private func handle(_ incoming: IlinkMessage) async {
        guard incoming.messageType == .user,
              let from = incoming.fromUserID, !from.isEmpty,
              from != record.botID
        else { return }
        lastMessageAt = Date()
        message = nil
        let read = await read(incoming)
        guard !read.text.isEmpty || !read.attachments.isEmpty else { return }
        let text = read.text
        if let token = incoming.contextToken {
            lastContextTokens[from] = token
        }
        // A slash command is the channel's own: it changes where the next
        // message goes, so it is answered here and never reaches the agent.
        if let command = ChannelCommands.parse(text) {
            await run(command, from: from)
            return
        }
        let peer = peers.items.first(where: { $0.userID == from })
        // The ask belongs to the conversation the phone talks in, so the
        // reply is read against that — whatever id its messages arrive
        // under. The phone id is only a fallback, for an ask kept before the
        // conversation was bound again.
        var waiting = peer.flatMap { pendingAsks[$0.sessionID] }
        if waiting == nil {
            waiting = pendingAsks.values.first { $0.userID == from }
        }
        var acknowledged = false
        if let pending = waiting {
            switch ChannelReplies.read(text, ask: pending.ask) {
            case let .answer(answer):
                pendingAsks.removeValue(forKey: pending.ask.sessionID)
                saveAsks()
                let failure = await settle(pending.ask, answer: answer)
                if let failure {
                    if failure.code == .notFound {
                        // The run ended, or the decision was taken in Apelin,
                        // while this ask was kept: nothing waits for it now.
                        trace("answer to \(pending.ask.approvalID) found nothing waiting")
                        await send(
                            ChannelReplies.noLongerWaiting(language: replyLanguage),
                            to: from,
                            contextToken: lastContextTokens[from]
                        )
                    } else {
                        // Refused or out of reach: the ask stays, so it can be
                        // answered again here or in Apelin — and the phone is
                        // told why, rather than left waiting for nothing.
                        pendingAsks[pending.ask.sessionID] = pending
                        saveAsks()
                        let reason = failure.message.isEmpty
                            ? t("未知原因", "未知原因", "unknown reason") : failure.message
                        await send(
                            t("这次答复没能交给 Apelin：\(reason)", "這次答覆沒能交給 Apelin：\(reason)", "Apelin did not take that answer: \(reason)"),
                            to: from,
                            contextToken: pending.contextToken
                        )
                    }
                } else {
                    trace("answer to \(pending.ask.approvalID) taken")
                    await send(
                        ChannelReplies.acknowledged(
                            answer,
                            wasQuestion: pending.ask.question != nil,
                            language: replyLanguage
                        ),
                        to: from,
                        contextToken: pending.contextToken
                    )
                }
                return
            case .needsApp:
                await send(
                    ChannelReplies.onlyInApp(language: replyLanguage),
                    to: from,
                    contextToken: pending.contextToken
                )
                return
            case .unclear:
                // A sentence rather than an answer, which becomes a turn of
                // its own: the ask goes on waiting, and the phone is told, so
                // a reply the channel did not understand never looks approved.
                trace("message taken as a new turn while \(pending.ask.approvalID) waits")
                acknowledged = true
                await send(
                    ChannelReplies.received(waitingFor: pending.ask, language: replyLanguage),
                    to: from,
                    contextToken: lastContextTokens[from]
                )
            }
        }
        if !acknowledged {
            // A word that only answers an approval, with none waiting, is
            // said back: queued it would wait behind the very run it means
            // to settle, and answer nothing.
            if ChannelReplies.isApprovalWord(text) {
                trace("approval word with no ask waiting")
                await send(ChannelReplies.nothingWaiting(language: replyLanguage), to: from, contextToken: lastContextTokens[from])
                return
            }
            // Heard, whatever comes of it: an answer to an ask is answered
            // above, and a command already by its own reply.
            await send(
                ChannelReplies.received(language: replyLanguage),
                to: from,
                contextToken: lastContextTokens[from]
            )
        }
        if let peer {
            await ask(peer, incoming: read)
        } else {
            await openConversation(with: from, incoming: read)
        }
    }

    /// Sends a message to the conversation the phone already talks in, with
    /// whatever files came with it. The worker that served it may have ended
    /// while the phone was away: the session host says so (`notFound`), and
    /// the same conversation is opened again and the message sent there.
    private func ask(_ peer: Peer, incoming: Incoming) async {
        let target = await resolved(peer)
        let reply = Reply(
            userID: target.userID,
            contextToken: lastContextTokens[target.userID],
            text: "",
            turns: 0
        )
        replies[target.sessionID] = collect(reply, into: replies[target.sessionID])
        do {
            var request = Self.prompt(for: target, text: Self.promptText(incoming))
            request.attachments = incoming.attachments.isEmpty ? nil : incoming.attachments
            try await deliver(WireRequest(request), descriptors: incoming.descriptors)
        } catch let error as ApelinError where error.code == .notFound {
            replies[target.sessionID] = nil
            await openConversation(with: target.userID, incoming: incoming, reopening: target)
        } catch {
            replies[target.sessionID] = nil
            failed(error, to: reply)
        }
    }

    /// Opens the conversation a phone talks in — its project, or a temporary
    /// chat tied to a UUID it keeps — and sends the message there.
    private func openConversation(
        with userID: String,
        incoming: Incoming,
        reopening peer: Peer? = nil
    ) async {
        var owner = await resolved(peer ?? Peer(
            userID: userID,
            sessionID: UUID().uuidString.lowercased(),
            temporaryID: UUID().uuidString.lowercased(),
            projectName: record.projectName,
            title: AgentConversationRules.title(incoming.text)
        ))
        owner.title = owner.title ?? AgentConversationRules.title(incoming.text)
        guard await open(owner, prompt: nil, origin: Self.origin) else {
            await send(
                t("会话打不开：\(message ?? "未知原因")", "會話打不開：\(message ?? "未知原因")", "The conversation could not be opened: \(message ?? "unknown reason")"),
                to: userID,
                contextToken: lastContextTokens[userID]
            )
            return
        }
        owner.updatedAt = Date()
        bind(owner)
        await ask(owner, incoming: incoming)
    }

    /// What the conversation is told: what came with the message, then the
    /// message itself.
    private static func promptText(_ incoming: Incoming) -> String {
        let body = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.notes.isEmpty else { return body }
        let notes = incoming.notes.joined(separator: "\n")
        return body.isEmpty ? notes : notes + "\n\n" + body
    }


    // MARK: Files from WeChat

    /// A message read into what a conversation takes: the words, a note per
    /// file, and the files themselves as descriptors — the same way the app
    /// hands an attachment to a session.
    ///
    /// One file that cannot be fetched costs that file alone: the message
    /// still reaches the conversation, with a note saying what was missing.
    private func read(_ message: IlinkMessage) async -> Incoming {
        var incoming = Incoming(text: message.readableText ?? "")
        guard let client = signedClient() else { return incoming }
        for item in message.items {
            guard let media = item.media, let type = item.type else { continue }
            let name: String
            switch type {
            case .image:
                name = "wechat-\(Self.stampToken()).jpg"
            case .video:
                name = "wechat-\(Self.stampToken()).mp4"
            case .file:
                name = item.file?.fileName?.isEmpty == false ? item.file!.fileName! : "wechat-\(Self.stampToken()).bin"
            default:
                continue
            }
            do {
                let data = try await client.download(media, key: item.mediaKey)
                guard let path = saveMedia(data, name: name) else {
                    incoming.notes.append("[WeChat \(type): \(name) could not be saved]")
                    continue
                }
                let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else {
                    incoming.notes.append("[WeChat \(type): \(name) could not be opened]")
                    continue
                }
                incoming.attachments.append(AgentInputAttachment(
                    descriptor: DescriptorSlot(index: incoming.descriptors.count),
                    name: name,
                    mimeType: Self.mime(name)
                ))
                incoming.descriptors.append(OwnedDescriptor(adopting: descriptor))
                incoming.notes.append("[WeChat \(type): \(name), \(data.count) bytes]")
            } catch {
                let reason = (error as? IlinkFailure)?.message ?? "download failed"
                incoming.notes.append("[WeChat \(type): \(name) was not received — \(reason)]")
            }
        }
        return incoming
    }

    /// Writes a received file beside the channel's own state, where it stays
    /// for the conversation to read.
    private func saveMedia(_ data: Data, name: String) -> String? {
        let attachments = folder.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let safe = String(name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .prefix(120))
        let url = attachments.appendingPathComponent("\(Self.stampToken())-\(safe)")
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    private static func stampToken() -> String {
        "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
    }

    private static func mime(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "pdf": "application/pdf"
        case "txt", "md", "log": "text/plain"
        case "json": "application/json"
        case "zip": "application/zip"
        case "mp4", "mov": "video/mp4"
        case "mp3", "m4a": "audio/mpeg"
        default: "application/octet-stream"
        }
    }

    /// The folder a conversation works in: its project, or General Chat's
    /// own workspace under `Temporary/`.
    private func workspace(of peer: Peer) -> URL? {
        let data = DataFolder(home: home)
        if let project = peer.projectName, let url = data.project(named: project) {
            return url
        }
        if let temporary = peer.temporaryID {
            return data.root.appendingPathComponent("Temporary/" + temporary, isDirectory: true)
        }
        return nil
    }

    // MARK: Files to WeChat

    /// `/send`: one file of the conversation's workspace, or a path inside
    /// it, uploaded and delivered to the phone.
    private func sendFile(_ path: String, from userID: String) async -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return t("用法：/send <路径>（会话项目里的文件，或项目内的完整路径）。", "用法：/send <路徑>（會話專案裡的檔案，或專案內的完整路徑）。", "Usage: /send <path> — a file inside the conversation's project.")
        }
        guard let peer = peers.items.first(where: { $0.userID == userID }) else {
            return t("还没有绑定会话。先发一条消息或用 /use 选一个。", "還沒有綁定會話。先發一則訊息或用 /use 選一個。", "This phone has no conversation yet. Send a message or /use one.")
        }
        guard let root = workspace(of: peer) else {
            return t("这个会话没有可读的工作目录。", "這個會話沒有可讀的工作目錄。", "This conversation has no workspace to read.")
        }
        let url = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : root.appendingPathComponent(trimmed)
        guard CanonicalPath.isCanonical(url.path, inside: root.path) else {
            return t("只能发会话项目里的文件：\(root.lastPathComponent)。", "只能發會話專案裡的檔案：\(root.lastPathComponent)。", "Only files inside \(root.lastPathComponent) can be sent.")
        }
        guard let data = try? Data(contentsOf: url) else {
            return t("读不到这个文件：\(trimmed)", "讀不到這個檔案：\(trimmed)", "That file could not be read: \(trimmed)")
        }
        guard data.count <= 25 * 1024 * 1024 else {
            return t("文件太大（上限 25MB）。", "檔案太大（上限 25MB）。", "That file is over 25 MB.")
        }
        if let failure = await deliverFile(data, name: url.lastPathComponent, to: peer) {
            return failure
        }
        return t("已发送 \(url.lastPathComponent)（\(data.count) 字节）。", "已傳送 \(url.lastPathComponent)（\(data.count) 位元組）。", "Sent \(url.lastPathComponent) (\(data.count) bytes).")
    }

    /// The files a turn produced (`toolResult` attachments): each is taken
    /// from the conversation's workspace and sent to the phone. A file that
    /// cannot go is said so, in one message: the reader asked for it and is
    /// otherwise left with a reply that speaks of a file they never got.
    private func relay(_ files: [AgentAttachment], peer: Peer) async {
        guard let root = workspace(of: peer) else { return }
        var failures: [String] = []
        for file in files.prefix(8) {
            let url = root.appendingPathComponent(file.path)
            guard CanonicalPath.isCanonical(url.path, inside: root.path) else {
                failures.append(t("\(file.name) 不在会话项目里，没有发出。", "\(file.name) 不在會話專案裡，沒有發出。", "\(file.name) is outside the conversation's project, so it was not sent."))
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                failures.append(t("读不到 \(file.name)。", "讀不到 \(file.name)。", "\(file.name) could not be read."))
                continue
            }
            guard data.count <= 25 * 1024 * 1024 else {
                failures.append(t("\(file.name) 超过 25MB，没有发出。", "\(file.name) 超過 25MB，沒有發出。", "\(file.name) is over 25 MB, so it was not sent."))
                continue
            }
            if let failure = await deliverFile(data, name: file.name, to: peer) {
                failures.append(failure)
            }
        }
        guard !failures.isEmpty else { return }
        await send(failures.joined(separator: "\n"), to: peer.userID, contextToken: lastContextTokens[peer.userID])
    }

    /// Uploads and sends one file, answering what went wrong — nil when it
    /// went.
    ///
    /// The image and video channels take only what WeChat's own client writes
    /// and answer 500 to anything else (a heic screenshot, a bmp): the same
    /// bytes then go down the file channel, which the phone receives and can
    /// open, rather than the phone being told the file could not be sent.
    private func deliverFile(_ data: Data, name: String, to peer: Peer) async -> String? {
        guard let client = signedClient() else {
            return t("通道没有登录，发不了文件。", "通道沒有登入，發不了檔案。", "The channel is not signed in, so nothing can be sent.")
        }
        let first = IlinkMediaType.of(name: name)
        do {
            try await uploadAndSend(data, name: name, type: first, client: client, to: peer)
            return nil
        } catch {
            guard first != .file else { return failure(error, name: name) }
            do {
                try await uploadAndSend(data, name: name, type: .file, client: client, to: peer)
                return nil
            } catch let second {
                return failure(second, name: name)
            }
        }
    }

    private func uploadAndSend(
        _ data: Data,
        name: String,
        type: IlinkMediaType,
        client: IlinkClient,
        to peer: Peer
    ) async throws {
        let upload = try await client.upload(data, name: name, to: peer.userID, mediaType: type)
        try await client.sendMedia(
            upload,
            name: name,
            mediaType: type,
            to: peer.userID,
            contextToken: lastContextTokens[peer.userID]
        )
    }

    private func failure(_ error: any Error, name: String) -> String {
        let reason = (error as? IlinkFailure)?.message ?? String(describing: error)
        return t("没发出去 \(name)：\(reason)", "沒發出去 \(name)：\(reason)", "\(name) was not sent: \(reason)")
    }

    // MARK: Commands

    /// Answers one command in the phone's own words.
    private func run(_ command: ChannelCommand, from userID: String) async {
        let token = lastContextTokens[userID]
        func reply(_ text: String) async {
            await send(text, to: userID, contextToken: token)
        }
        switch command {
        case .help:
            await reply(Self.helpText(replyLanguage))
        case .sessions:
            let briefs = await ChannelDirectory.sessions(home: home, registry: registry)
            sessionList = (Date(), briefs)
            await reply(sessionsText(briefs, for: userID))
        case .current:
            await reply(currentText(userID))
        case let .use(argument):
            await reply(await use(argument, from: userID))
        case let .workspace(argument):
            if let argument {
                await reply(workspace(argument, from: userID))
            } else {
                await reply(workspaceListText(for: userID))
            }
        case let .model(argument, effort):
            await reply(await model(argument: argument, effort: effort, from: userID))
        case let .effort(argument):
            await reply(effortArgument(argument, from: userID))
        case let .send(path):
            await reply(await sendFile(path, from: userID))
        }
    }

    /// The conversations, numbered, with the one this phone talks in marked.
    private func sessionsText(_ briefs: [ChannelDirectory.SessionBrief], for userID: String) -> String {
        guard !briefs.isEmpty else {
            return t("还没有任何会话。直接发消息会自动新建一个。", "還沒有任何會話。直接發訊息會自動新建一個。", "No conversations yet. Send a message and one opens.")
        }
        let mine = peers.items.first(where: { $0.userID == userID })?.sessionID
        var lines = [t("全部会话（共 \(briefs.count) 个，按最近活动排序）：", "全部會話（共 \(briefs.count) 個，依最近活動排序）：", "Conversations (\(briefs.count), most recent first):"), ""]
        for (index, brief) in briefs.enumerated() {
            var line = "\(index + 1). \(brief.title) · \(brief.projectName ?? t("通用", "通用", "General")) · \(Self.stamp(brief.updatedAt))"
            if brief.id == mine {
                line += t("（目前）", "（目前）", " (current)")
            } else if brief.running {
                line += t("（進行中）", "（進行中）", " (running)")
            }
            lines.append(line)
        }
        lines.append("")
        lines.append(t("发 /use <序号> 切换，/use 新 新建。", "發 /use <序號> 切換，/use 新 新建。", "Send /use <number> to switch, /use new to start one."))
        return lines.joined(separator: "\n")
    }

    private func currentText(_ userID: String) -> String {
        guard let peer = peers.items.first(where: { $0.userID == userID }) else {
            return t("还没有绑定会话。直接发消息会自动新建一个；或发 /sessions 选。", "還沒有綁定會話。直接發訊息會自動新建一個；或發 /sessions 選。", "This phone has no conversation yet. Send a message, or /sessions.")
        }
        let project = peer.projectName ?? t("通用", "通用", "General")
        let model = peer.model.map { "\(peer.provider?.rawValue ?? "")·\($0)" } ?? t("会话自己的", "會話自己的", "the conversation’s own")
        let effort = peer.effort.map(ChannelCommands.effortName) ?? t("默认", "預設", "default")
        return t(
            "当前会话：\(peer.title ?? String(peer.sessionID.prefix(8))) · \(project)\n模型：\(model) · 强度：\(effort)",
            "目前會話：\(peer.title ?? String(peer.sessionID.prefix(8))) · \(project)\n模型：\(model) · 強度：\(effort)",
            "Conversation: \(peer.title ?? String(peer.sessionID.prefix(8))) · \(project)\nModel: \(model) · effort: \(effort)"
        )
    }

    /// `/use`: by number, by id, or a new conversation in the phone's project.
    private func use(_ argument: String, from userID: String) async -> String {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return t("用法：/use <序号>，或 /use 新 新建。先发 /sessions 看序号。", "用法：/use <序號>，或 /use 新 新建。先發 /sessions 看序號。", "Usage: /use <number>, or /use new. Send /sessions for the numbers.")
        }
        let existing = peers.items.first(where: { $0.userID == userID })
        if trimmed == "新" || trimmed.lowercased() == "new" {
            let project = existing?.projectName ?? record.projectName
            let temporary = UUID().uuidString.lowercased()
            let sessionID = UUID().uuidString.lowercased()
            var owner = await resolved(existing ?? Peer(
                userID: userID,
                sessionID: sessionID,
                temporaryID: temporary,
                title: nil
            ))
            owner.sessionID = sessionID
            owner.projectName = project
            owner.temporaryID = project == nil ? temporary : nil
            owner.title = nil
            guard await open(owner, prompt: nil, origin: Self.origin) else {
                return t("新建会话失败：\(message ?? "未知原因")", "新建會話失敗：\(message ?? "未知原因")", "The conversation could not be opened: \(message ?? "unknown reason")")
            }
            var stored = owner
            stored.updatedAt = Date()
            bind(stored)
            return t(
                "已新建会话 \(String(sessionID.prefix(8))) · \(project ?? "通用")。之后的消息都进这个会话。",
                "已新建會話 \(String(sessionID.prefix(8))) · \(project ?? "通用")。之後的訊息都進這個會話。",
                "Started conversation \(String(sessionID.prefix(8))) · \(project ?? "General")."
            )
        }
        var briefs = sessionList?.briefs ?? []
        if briefs.isEmpty || Date().timeIntervalSince(sessionList?.taken ?? .distantPast) > 60 {
            briefs = await ChannelDirectory.sessions(home: home, registry: registry)
            sessionList = (Date(), briefs)
        }
        let target: ChannelDirectory.SessionBrief?
        if let index = ChannelCommands.index(trimmed), briefs.indices.contains(index - 1) {
            target = briefs[index - 1]
        } else {
            target = briefs.first { $0.id == trimmed || (trimmed.count >= 6 && $0.id.hasPrefix(trimmed)) }
        }
        guard let target else {
            return t("没找到会话「\(trimmed)」。发 /sessions 看序号，或 /use 新 新建。", "沒找到會話「\(trimmed)」。發 /sessions 看序號，或 /use 新 新建。", "No conversation “\(trimmed)”. Send /sessions, or /use new.")
        }
        var peer = existing ?? Peer(
            userID: userID,
            sessionID: target.id,
            temporaryID: target.temporaryID,
            title: target.title
        )
        peer.sessionID = target.id
        peer.projectName = target.projectName
        peer.temporaryID = target.temporaryID
        peer.title = target.title
        // The conversation has a model of its own; the phone's picks were
        // for the one it was in.
        peer.provider = nil
        peer.model = nil
        peer.effort = nil
        peer.tier = nil
        peer.updatedAt = Date()
        bind(peer)
        return t(
            "已切换到「\(target.title)」· \(target.projectName ?? "通用")。之后的消息都进这个会话。",
            "已切換到「\(target.title)」· \(target.projectName ?? "通用")。之後的訊息都進這個會話。",
            "Switched to “\(target.title)” · \(target.projectName ?? "General")."
        )
    }

    /// `/workspace`: the projects, numbered, with this phone's marked.
    private func workspaceListText(for userID: String) -> String {
        let projects = ChannelDirectory.projects(home: home)
        guard !projects.isEmpty else {
            return t("这台设备还没有任何项目。先在 Apelin 里建一个。", "這台裝置還沒有任何專案。先在 Apelin 裡建一個。", "No projects on this device yet. Make one in Apelin first.")
        }
        let current = peers.items.first(where: { $0.userID == userID })?.projectName ?? record.projectName
        var lines = [t("项目（共 \(projects.count) 个）：", "專案（共 \(projects.count) 個）：", "Projects (\(projects.count)):"), ""]
        for (index, name) in projects.enumerated() {
            lines.append("\(index + 1). \(name)\(name == current ? t("（目前）", "（目前）", " (current)") : "")")
        }
        lines.append("")
        lines.append(t("发 /workspace <序号> 设定默认项目，之后 /use 新 会在那里新建。", "發 /workspace <序號> 設定預設專案，之後 /use 新 會在那裡新建。", "Send /workspace <number> to set it; /use new opens there."))
        return lines.joined(separator: "\n")
    }

    /// `/workspace <number|name>`: where new conversations are opened. A
    /// conversation already bound keeps its own project.
    private func workspace(_ argument: String, from userID: String) -> String {
        let projects = ChannelDirectory.projects(home: home)
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        let target: String?
        if let index = ChannelCommands.index(trimmed), projects.indices.contains(index - 1) {
            target = projects[index - 1]
        } else {
            target = projects.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        }
        guard let target else {
            return t("没找到项目「\(trimmed)」。发 /workspace 看序号。", "沒找到專案「\(trimmed)」。發 /workspace 看序號。", "No project “\(trimmed)”. Send /workspace.")
        }
        var peer = peers.items.first(where: { $0.userID == userID })
            ?? Peer(userID: userID, sessionID: UUID().uuidString.lowercased(), temporaryID: nil, title: nil)
        peer.projectName = target
        peer.updatedAt = Date()
        bind(peer)
        return t(
            "已把默认项目设为「\(target)」。新建会话会在那里；已绑定的会话不变。发 /use 新 立即开一个。",
            "已把預設專案設為「\(target)」。新建會話會在那裡；已綁定的會話不變。發 /use 新 立即開一個。",
            "Default project is now “\(target)”. New conversations open there; the current one stays. Send /use new."
        )
    }

    /// `/model`: the models this device can use, numbered, or one of them.
    private func model(argument: String?, effort: String?, from userID: String) async -> String {
        let models = await models()
        guard !models.isEmpty else {
            return t(
                "还没有可用的模型。先在 Apelin 的「模型供应商」里登录，再到「模型」里启用要用的。",
                "還沒有可用的模型。先在 Apelin 的「模型供應商」裡登入，再到「模型」裡啟用要用的。",
                "No models yet. Sign in a provider in Apelin, then enable the ones you want under Models."
            )
        }
        guard let argument else {
            return modelListText(models, for: userID)
        }
        guard let index = ChannelCommands.index(argument), models.indices.contains(index - 1) else {
            return t("用法：/model <序号> [lo|mid|hi]。发 /model 看序号。", "用法：/model <序號> [lo|mid|hi]。發 /model 看序號。", "Usage: /model <number> [lo|mid|hi]. Send /model for the numbers.")
        }
        let chosen = models[index - 1]
        var peer = peers.items.first(where: { $0.userID == userID })
            ?? Peer(userID: userID, sessionID: UUID().uuidString.lowercased(), temporaryID: nil, title: nil)
        peer.provider = chosen.provider
        peer.model = chosen.model
        if let effort, let parsed = ChannelCommands.effort(effort) {
            peer.effort = parsed
        } else if let effort {
            return t("强度「\(effort)」不认识。用 lo、mid 或 hi。", "強度「\(effort)」不認識。用 lo、mid 或 hi。", "Unknown effort “\(effort)”. Use lo, mid or hi.")
        }
        peer.updatedAt = Date()
        bind(peer)
        await configure(peer)
        let effortName = peer.effort.map(ChannelCommands.effortName) ?? t("会话默认", "會話預設", "the conversation’s")
        return t(
            "已切到 \(chosen.label) · 强度 \(effortName)。下一条消息就用它。",
            "已切到 \(chosen.label) · 強度 \(effortName)。下一則訊息就用它。",
            "Now \(chosen.label) · effort \(effortName). The next message uses it."
        )
    }

    private func modelListText(_ models: [ChannelModel], for userID: String) -> String {
        let peer = peers.items.first(where: { $0.userID == userID })
        var lines = [t("模型（共 \(models.count) 个）：", "模型（共 \(models.count) 個）：", "Models (\(models.count)):"), ""]
        for (index, model) in models.prefix(40).enumerated() {
            let mark = model.model == peer?.model && model.provider == peer?.provider ? t("（目前）", "（目前）", " (current)") : ""
            lines.append("\(index + 1). \(model.label)\(mark)")
        }
        if models.count > 40 {
            lines.append(t("… 还有 \(models.count - 40) 个未列出。", "… 還有 \(models.count - 40) 個未列出。", "… \(models.count - 40) more not listed."))
        }
        lines.append("")
        lines.append(t("发 /model <序号> [lo|mid|hi] 切换；/effort <lo|mid|hi> 只改强度。", "發 /model <序號> [lo|mid|hi] 切換；/effort <lo|mid|hi> 只改強度。", "Send /model <number> [lo|mid|hi]; /effort <lo|mid|hi> changes only the effort."))
        return lines.joined(separator: "\n")
    }

    /// `/effort`: what it is now, or what it becomes.
    private func effortArgument(_ argument: String?, from userID: String) -> String {
        guard let peer = peers.items.first(where: { $0.userID == userID }) else {
            return t("还没有绑定会话。直接发消息会自动新建一个。", "還沒有綁定會話。直接發訊息會自動新建一個。", "This phone has no conversation yet. Send a message.")
        }
        guard let argument else {
            let name = peer.effort.map(ChannelCommands.effortName) ?? t("会话默认", "會話預設", "the conversation’s")
            return t("当前思考强度：\(name)。发 /effort lo|mid|hi 修改。", "目前思考強度：\(name)。發 /effort lo|mid|hi 修改。", "Effort now: \(name). Send /effort lo|mid|hi.")
        }
        guard let parsed = ChannelCommands.effort(argument) else {
            return t("强度「\(argument)」不认识。用 lo、mid 或 hi。", "強度「\(argument)」不認識。用 lo、mid 或 hi。", "Unknown effort “\(argument)”. Use lo, mid or hi.")
        }
        var updated = peer
        updated.effort = parsed
        updated.updatedAt = Date()
        bind(updated)
        let chosen = updated
        Task { [weak self] in await self?.configure(chosen) }
        return t("已把思考强度设为 \(ChannelCommands.effortName(parsed))。", "已把思考強度設為 \(ChannelCommands.effortName(parsed))。", "Effort is now \(ChannelCommands.effortName(parsed)).")
    }

    /// The models this device offers, read from the agent's own account list
    /// and kept for a minute. Only what Settings ▸ Models has enabled is
    /// asked for — a phone choosing a conversation's model is offered the
    /// models the app offers, not every model a provider lists. A host that
    /// was never told (a channel saved before the app sent the list) still
    /// answers with everything, as it did then.
    private func models() async -> [ChannelModel] {
        if let modelList, Date().timeIntervalSince(modelList.taken) < 60 {
            return modelList.models
        }
        let enabled = record.enabledModels
        guard let wire = try? WireRequest(AgentAccountListRequest(
            extraModels: enabled.flatMap { $0.isEmpty ? nil : $0 },
            onlyExtraModels: enabled == nil ? nil : true
        )) else { return [] }
        let reply = await route(wire, [])
        guard case let .success(data) = reply.result,
              let answer = try? JSONCoding.decode(AgentAccountListResponse.self, from: data)
        else { return [] }
        var models: [ChannelModel] = []
        for account in answer.accounts where account.signedIn {
            for model in account.models ?? [] {
                models.append(ChannelModel(
                    provider: account.provider,
                    model: model,
                    label: "\(account.provider.rawValue)·\(model)"
                ))
            }
        }
        models.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        modelList = (Date(), models)
        return models
    }

    /// Opens a conversation for `peer` — the same id when it has one, a new
    /// one when it does not — with the phone's project and model, and this
    /// message as its first prompt when there is one.
    private func open(_ peer: Peer, prompt: String?, origin: String? = nil) async -> Bool {
        prepareWorkspace(peer)
        var request = AgentOpenRequest(
            projectName: peer.projectName ?? record.projectName,
            temporaryID: (peer.projectName ?? record.projectName) == nil ? peer.temporaryID : nil,
            sessionID: peer.sessionID,
            provider: peer.provider,
            model: peer.model,
            approvalMode: record.approvalMode,
            reasoningEffort: peer.effort,
            serviceTier: peer.tier,
            prompt: prompt,
            title: prompt.flatMap(AgentConversationRules.title),
            origin: origin
        )
        request.asksBeforeScreen = false
        guard let wire = try? WireRequest(request) else { return false }
        let reply = await route(wire, [])
        if case let .failure(error) = reply.result {
            message = error.message
            return false
        }
        return true
    }

    /// General Chat's workspace is a folder under `Temporary/`, and the app
    /// makes it before it opens a chat. A phone's conversation may name one
    /// that was never made, or was removed with the chat: the host refuses a
    /// temporary chat whose folder is missing, so it is made here.
    private func prepareWorkspace(_ peer: Peer) {
        guard peer.projectName == nil, let temporary = peer.temporaryID else { return }
        let data = DataFolder(home: home)
        try? data.makeLevels(to: data.root.appendingPathComponent("Temporary/" + temporary, isDirectory: true))
    }

    /// The model a conversation is opened with when the phone has not picked
    /// one: what the project's most recent conversation used, else the first
    /// model this device is signed in to. Without one, an open falls to a
    /// provider this device may not be signed in to at all.
    private func inheritedModel(projectName: String?) async -> (provider: AgentProvider, model: String)? {
        let recent = ChannelDirectory.storedSessions(home: home)
            .filter { $0.projectName == projectName }
            .sorted { $0.updatedAt > $1.updatedAt }
        for session in recent.prefix(10) {
            if let pair = Self.model(inSession: session.id, home: home) {
                return pair
            }
        }
        for model in await models() {
            return (model.provider, model.model)
        }
        return nil
    }

    /// The provider and model a saved conversation was created with, read
    /// from its `session.json`: the model half of `ProviderConfiguration`,
    /// whichever case it was written as.
    static func model(inSession id: String, home: String) -> (provider: AgentProvider, model: String)? {
        let file = DataFolder(home: home).sessions
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providerObject = object["provider"] as? [String: Any],
              let entry = providerObject.first
        else { return nil }
        let body = entry.value as? [String: Any] ?? [:]
        let model = body["model"] as? String
        switch entry.key {
        case "githubCopilot":
            return model.map { (.githubCopilot, $0) }
        case "openAICompatible":
            return model.map { (.openAICompatible, $0) }
        case "anthropic":
            guard let model else { return nil }
            let oauth = body["oauth"] as? Bool ?? false
            return (oauth ? .anthropicOAuth : .anthropic, model)
        case "stored":
            guard let store = body["storeID"] as? String, let model,
                  let provider = provider(forStore: store)
            else { return nil }
            return (provider, model)
        default:
            return nil
        }
    }

    /// kwwk's store ids, as the app's providers are named on the wire.
    static func provider(forStore store: String) -> AgentProvider? {
        switch store {
        case "github-copilot": .githubCopilot
        case "anthropic": .anthropicOAuth
        case "anthropic-api-key": .anthropic
        case "openai-compatible": .openAICompatible
        case "openai-codex": .openAICodex
        case "cursor": .cursor
        case "devin": .devin
        case "kiro": .kiro
        case "antigravity": .antigravity
        case "qoder": .qoder
        case "qoder-cn": .qoderCN
        case "workbuddy": .workBuddy
        case "workbuddy-ai": .workBuddyAI
        case "raccoon": .raccoon
        case "kimi-coding": .kimiCoding
        case "kimi-coding-ai": .kimiCodingGlobal
        case "xai": .xai
        case "zai": .zai
        case "zai-coding-cn": .zaiCodingCN
        case "openrouter": .openRouter
        case "openai-api-key": .openAI
        case "google-api-key": .google
        case "deepseek-api-key": .deepSeek
        case "opencode-go": .openCodeGo
        case "opencode": .openCodeZen
        default: nil
        }
    }

    /// `peer` with the model a message from it is sent with: what it chose,
    /// else what the project last used.
    private func resolved(_ peer: Peer) async -> Peer {
        guard peer.provider == nil || peer.model == nil else { return peer }
        guard let inherited = await inheritedModel(projectName: peer.projectName) else { return peer }
        var updated = peer
        updated.provider = peer.provider ?? inherited.provider
        updated.model = peer.model ?? inherited.model
        return updated
    }

    /// Applies the phone's model to a conversation that is already open.
    private func configure(_ peer: Peer) async {
        guard let provider = peer.provider, let model = peer.model else { return }
        let request = AgentConfigureRequest(
            sessionID: peer.sessionID,
            provider: provider,
            model: model,
            reasoningEffort: peer.effort,
            serviceTier: peer.tier
        )
        guard let wire = try? WireRequest(request) else { return }
        // A conversation nothing serves now takes its model from the next
        // open, which carries it; the host's refusal is not the phone's.
        _ = await route(wire, [])
    }

    private func bind(_ peer: Peer) {
        if let index = peers.items.firstIndex(where: { $0.userID == peer.userID }) {
            peers.items[index] = peer
        } else {
            peers.items.append(peer)
        }
        savePeers()
    }

    private static func prompt(for peer: Peer, text: String) -> AgentPromptRequest {
        AgentPromptRequest(
            sessionID: peer.sessionID,
            text: text,
            provider: peer.provider,
            model: peer.model,
            reasoningEffort: peer.effort,
            serviceTier: peer.tier,
            source: ChatChannel.weChat
        )
    }

    /// `MM-dd HH:mm`, the way a list of conversations shows a time.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// One line in the app's own language: the three the channel writes.
    private func t(_ hans: String, _ hant: String, _ english: String) -> String {
        switch replyLanguage {
        case "zh-Hans": hans
        case "zh-Hant": hant
        default: english
        }
    }

    /// A line whose two Chinese spellings are the same words.
    private func t(_ chinese: String, _ english: String) -> String {
        t(chinese, chinese, english)
    }

    /// `/help` in the app's own language, never two at once.
    static func helpText(_ language: String) -> String {
        switch language {
        case "zh-Hans":
            """
            /sessions  列出全部会话
            /use <序号>  切换会话；/use 新 新建
            /current  查看当前会话
            /workspace  列出项目；/workspace <序号> 设定默认项目
            /model  列出已启用的模型；/model <序号> [lo|mid|hi] 切换
            /effort <lo|mid|hi>  修改思考强度
            /send <路径>  把设备上的文件发到微信
            /help  显示本帮助

            直接发普通文字则交给会话里的 AI。需要授权或回答问题时，回数字即可。
            """
        case "zh-Hant":
            """
            /sessions  列出全部會話
            /use <序號>  切換會話；/use 新 新建
            /current  查看目前會話
            /workspace  列出專案；/workspace <序號> 設定預設專案
            /model  列出已啟用的模型；/model <序號> [lo|mid|hi] 切換
            /effort <lo|mid|hi>  修改思考強度
            /send <路徑>  把裝置上的檔案發到微信
            /help  顯示本說明

            直接發普通文字則交給會話裡的 AI。需要授權或回答問題時，回數字即可。
            """
        default:
            """
            /sessions  every conversation
            /use <number>  switch; /use new  start one
            /current  which conversation this phone is in
            /workspace  the projects; /workspace <number>  the default one
            /model  the models you have enabled; /model <number> [lo|mid|hi]  pick one
            /effort <lo|mid|hi>  only the effort
            /send <path>  send a file of this device to WeChat
            /help  this page
            """
        }
    }

    /// Sends one approval or question to the phone that talks in this
    /// conversation, and keeps it for the reply.
    private func announce(_ payload: JSONValue, sessionID: String) async {
        guard let peer = peers.items.first(where: { $0.sessionID == sessionID }),
              let approvalID = payload["approvalID"]?.stringValue
        else {
            // A conversation no phone talks in: the app's own, or one whose
            // binding moved. Nothing is sent, and the log says which.
            trace(
                "ask \(payload["approvalID"]?.stringValue ?? "(none)") for session \(sessionID) has no phone"
            )
            return
        }
        let question = payload["detail"]?[AgentQuestionRules.detailKey]
            .flatMap { try? $0.decode(AgentQuestion.self) }
        // A command as root takes the device owner's check, which a chat
        // message cannot give: announced, answered only in Apelin.
        let needsApp = payload["detail"]?[RunCodeApproval.rootCommandDetail] != nil
        var ask = ChannelAsk(
            approvalID: approvalID,
            sessionID: sessionID,
            tool: payload["tool"]?.stringValue,
            question: question,
            needsAppToApprove: needsApp,
            text: ""
        )
        ask.text = ChannelReplies.text(
            for: ask,
            reason: payload["reason"]?.stringValue,
            arguments: payload["arguments"]?.stringValue,
            language: replyLanguage
        )
        let contextToken = lastContextTokens[peer.userID]
        pendingAsks[sessionID] = PendingAsk(ask: ask, contextToken: contextToken, userID: peer.userID)
        saveAsks()
        trace("ask \(approvalID) for session \(sessionID) waits for a reply")
        await send(ask.text, to: peer.userID, contextToken: contextToken)
    }

    /// The reader's answer, given to the session as the app gives one: an
    /// approval once, or a question answered with the labels it offered.
    /// Nil when taken, the refusal otherwise — `notFound` for an ask whose
    /// run, or whose approval, is no longer there.
    private func settle(_ ask: ChannelAsk, answer: ChannelAnswer) async -> ApelinError? {
        let request = AgentApproveRequest(
            sessionID: ask.sessionID,
            approvalID: ask.approvalID,
            decision: answer.approved ? .approve : .deny,
            scope: .once,
            answer: answer.approved ? answer.answer : nil
        )
        guard let wire = try? WireRequest(request) else {
            return ApelinError(.badRequest, "the answer could not be encoded")
        }
        let reply = await route(wire, [])
        if case let .failure(error) = reply.result {
            message = error.message
            return error
        }
        return nil
    }

    private func clearAsk(_ approvalID: String?) {
        guard let approvalID else { return }
        var cleared = false
        for (session, pending) in pendingAsks where pending.ask.approvalID == approvalID {
            pendingAsks[session] = nil
            cleared = true
        }
        if cleared { saveAsks() }
    }

    /// The run ended: the ask it was waiting on can no longer be answered.
    private func clearAsks(session: String) {
        if pendingAsks.removeValue(forKey: session) != nil { saveAsks() }
    }

    private func failed(_ error: any Error, to reply: Reply) {
        message = (error as? ApelinError)?.message ?? String(describing: error)
        Task { [weak self] in
            await self?.send("Apelin could not start this turn.", to: reply.userID, contextToken: reply.contextToken)
        }
    }

    /// The collector a new message adds its turn to: the one in flight when
    /// the conversation is still answering, else a fresh one.
    private func collect(_ reply: Reply, into existing: Reply?) -> Reply {
        guard var existing else { return Reply(userID: reply.userID, contextToken: reply.contextToken, text: "", turns: 1) }
        existing.turns += 1
        existing.contextToken = reply.contextToken ?? existing.contextToken
        return existing
    }

    private func deliver(_ request: WireRequest, descriptors: [OwnedDescriptor] = []) async throws {
        let reply = await route(request, descriptors)
        if case let .failure(error) = reply.result {
            throw error
        }
    }

    // MARK: Answering

    /// One event of a conversation, as the host's feed sees it: the text a
    /// turn writes is collected, and the end of the turn sends it.
    func relayed(sessionID: String?, kind: String, payload: JSONValue?) {
        guard let sessionID else { return }
        // A call that needs the reader: carried to the phone that talks in
        // this conversation. A decision taken in the app clears the ask the
        // phone was given, so a reply to it is not read as one.
        if kind == "approvalRequested", let payload {
            Task { [weak self] in
                await self?.announce(payload, sessionID: sessionID)
            }
            return
        }
        if kind == "approvalResolved" {
            clearAsk(payload?["approvalID"]?.stringValue)
            return
        }
        // Files a tool wrote: sent to the phone that talks in this
        // conversation, as the app shows them in its result row.
        if kind == "toolResult", let payload,
           let peer = peers.items.first(where: { $0.sessionID == sessionID }),
           let attachments = payload["attachments"],
           let files = try? attachments.decode([AgentAttachment].self), !files.isEmpty
        {
            Task { [weak self] in
                await self?.relay(files, peer: peer)
            }
            return
        }
        guard var reply = replies[sessionID] else { return }
        // The end of a turn: the agent's `finished`, or the task's own final
        // `state` when the run ended another way (Stop, a crash, an abort).
        if kind == "finished" || kind == TaskEvent.stateKind {
            // The run ended: whatever it was waiting for is gone with it.
            if kind == TaskEvent.stateKind {
                clearAsks(session: sessionID)
            }
            let final = Reply(userID: reply.userID, contextToken: reply.contextToken, text: reply.text, turns: 1)
            // A message that arrived during the run is answered next: the
            // collector stays, with what it has written from now on.
            reply.text = ""
            reply.turns -= 1
            replies[sessionID] = kind == "finished" && reply.turns > 0 ? reply : nil
            Task { [weak self] in
                await self?.send(reply: final)
            }
            return
        }
        switch kind {
        case "text":
            reply.text += payload?["text"]?.stringValue ?? ""
        case "message":
            reply.text = payload?["text"]?.stringValue ?? reply.text
        case "error":
            if let error = payload?["message"]?.stringValue, !error.isEmpty {
                reply.text += (reply.text.isEmpty ? "" : "\n\n") + error
            }
        default:
            return
        }
        replies[sessionID] = reply
    }

    /// One reply, whole: WeChat takes a long message as one bubble, and a
    /// turn's answer is not cut into pieces.
    private func send(reply: Reply) async {
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await send(text, to: reply.userID, contextToken: reply.contextToken)
    }

    private func send(_ text: String, to userID: String, contextToken: String?) async {
        guard let client = signedClient() else { return }
        do {
            try await client.send(text: text, to: userID, contextToken: contextToken)
        } catch {
            message = (error as? IlinkFailure)?.message ?? String(describing: error)
        }
    }

    // MARK: Plumbing

    private func signedClient() -> IlinkClient? {
        guard let token = record.botToken, !token.isEmpty else { return nil }
        let base = record.baseURL ?? IlinkClient.defaultBaseURL.absoluteString
        if let clientCache, clientCache.base == base, clientCache.token == token {
            return clientCache.client
        }
        let url = URL(string: base) ?? IlinkClient.defaultBaseURL
        let client = IlinkClient(baseURL: url, token: token)
        clientCache = (base, token, client)
        return client
    }

    private func fail(_ error: any Error) {
        phase = .failed
        message = (error as? IlinkFailure)?.message ?? String(describing: error)
        login = nil
        loginTask = nil
    }

    private var recordFile: URL {
        folder.appendingPathComponent("channel.json")
    }

    private var peersFile: URL {
        folder.appendingPathComponent("peers.json")
    }

    private var asksFile: URL {
        folder.appendingPathComponent("pending-asks.json")
    }

    /// The log's own cap: past it, the older half goes.
    private static let logLimit = 64 * 1024

    /// What the channel did that a phone cannot see: one line per ask, per
    /// message and per answer. NSLog keeps no history, so the same line goes
    /// to `channel-log.txt` beside the asks — ids and lengths, never what the
    /// message said.
    private func trace(_ line: String) {
        Self.trace(line, folder: folder)
    }

    private static func trace(_ line: String, folder: URL) {
        NSLog("wechat-channel: %@", line)
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        guard let data = stamped.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("channel-log.txt")
        var written = (try? Data(contentsOf: file)) ?? Data()
        written.append(data)
        if written.count > logLimit {
            written = Data(written.suffix(logLimit / 2))
        }
        try? written.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func makeFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only the account that runs the channel reads it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    /// The record holds the credential: written where only the channel's own
    /// account can read it, and never logged or returned.
    private func saveRecord() {
        makeFolder()
        guard let data = try? JSONCoding.encode(record) else { return }
        try? data.write(to: recordFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordFile.path)
    }

    private func savePeers() {
        makeFolder()
        guard let data = try? JSONCoding.encode(peers) else { return }
        try? data.write(to: peersFile, options: .atomic)
    }

    /// An ask as the file keeps it: the phone it went to, the ask itself,
    /// and the thread its answer belongs in.
    private struct StoredAsk: Codable, Sendable, Equatable {
        var userID: String
        var ask: ChannelAsk
        var contextToken: String?
        var savedAt: Date
    }

    /// Writes the asks where the next host run finds them: an approval
    /// outlives a restart that way, and a reply to it is still read as one.
    /// No file at all when nothing waits.
    private func saveAsks() {
        guard !pendingAsks.isEmpty else {
            try? FileManager.default.removeItem(at: asksFile)
            return
        }
        makeFolder()
        let stored = pendingAsks.values
            .map {
                StoredAsk(
                    userID: $0.userID,
                    ask: $0.ask,
                    contextToken: $0.contextToken,
                    savedAt: Date()
                )
            }
            .sorted { $0.ask.sessionID < $1.ask.sessionID }
        guard let data = try? JSONCoding.encode(stored) else { return }
        try? data.write(to: asksFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: asksFile.path)
    }

    /// The asks an earlier run left. One file that does not read is set
    /// aside, never replaced by nothing: what it names is still a decision
    /// the phone may give.
    private static func loadAsks(_ folder: URL) -> [String: PendingAsk] {
        let file = folder.appendingPathComponent("pending-asks.json")
        guard let data = try? Data(contentsOf: file) else { return [:] }
        guard let stored = try? JSONCoding.decode([StoredAsk].self, from: data) else {
            UnreadableFile.setAside(file)
            return [:]
        }
        var asks: [String: PendingAsk] = [:]
        for entry in stored where !entry.ask.sessionID.isEmpty && asks[entry.ask.sessionID] == nil {
            asks[entry.ask.sessionID] = PendingAsk(
                ask: entry.ask,
                contextToken: entry.contextToken,
                userID: entry.userID
            )
        }
        return asks
    }

    /// A record that does not read is set aside, never silently replaced by
    /// an empty one: the credential in it is the reader's to keep.
    private static func loadRecord(_ folder: URL) -> Record {
        let file = folder.appendingPathComponent("channel.json")
        guard let data = try? Data(contentsOf: file) else { return Record() }
        if let record = try? JSONCoding.decode(Record.self, from: data) {
            return record
        }
        UnreadableFile.setAside(file)
        return Record()
    }

    private static func loadPeers(_ folder: URL) -> PreservedList<Peer> {
        let file = folder.appendingPathComponent("peers.json")
        guard let data = try? Data(contentsOf: file) else { return PreservedList() }
        if let peers = try? JSONCoding.decode(PreservedList<Peer>.self, from: data) {
            return peers
        }
        UnreadableFile.setAside(file)
        return PreservedList()
    }
}
