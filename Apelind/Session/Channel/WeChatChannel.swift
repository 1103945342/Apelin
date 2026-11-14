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
/// reader's messages. Approvals are never given from WeChat — a turn that
/// needs one waits for the app.
///
/// The credential lives in `<data>/WeChatChannel/channel.json`, written
/// mobile's own; nothing returns it, logs it or puts it in an error.
actor WeChatChannel {
    /// What one WeChat peer's message asks of the host: a request, answered
    /// through the dispatcher as the app's.
    typealias Route = @Sendable (WireRequest) async -> WireReply

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
        var title: String?
        var updatedAt: Date

        init(userID: String, sessionID: String, temporaryID: String?, title: String?, updatedAt: Date = Date()) {
            self.userID = userID
            self.sessionID = sessionID
            self.temporaryID = temporaryID
            self.title = title
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case userID
            case sessionID
            case temporaryID
            case title
            case updatedAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userID = try container.decode(String.self, forKey: .userID)
            sessionID = try container.decode(String.self, forKey: .sessionID)
            temporaryID = try container.decodeIfPresent(String.self, forKey: .temporaryID)
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
    }

    private let folder: URL
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
    /// The approvals and questions a phone has been asked, by its user id.
    /// One per phone: a run waits on one decision at a time.
    private var pendingAsks: [String: PendingAsk] = [:]
    /// The thread a phone's messages came in on, so an ask that arrives
    /// later still answers in the same one.
    private var lastContextTokens: [String: String] = [:]
    private var clientCache: (base: String, token: String, client: IlinkClient)?

    init(folder: URL, route: @escaping Route) {
        self.folder = folder
        self.route = route
        record = Self.loadRecord(folder)
        peers = Self.loadPeers(folder)
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
        clearsProject: Bool,
    ) async -> ChannelState {
        if let enabled {
            record.enabled = enabled
        }
        if let approvalMode {
            record.approvalMode = approvalMode
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
              from != record.botID,
              let text = incoming.readableText
        else { return }
        lastMessageAt = Date()
        message = nil
        if let token = incoming.contextToken {
            lastContextTokens[from] = token
        }
        if let pending = pendingAsks[from] {
            switch ChannelReplies.read(text, ask: pending.ask) {
            case let .answer(answer):
                pendingAsks[from] = nil
                let settled = await settle(pending.ask, answer: answer)
                if settled {
                    await send(
                        ChannelReplies.acknowledged(answer, wasQuestion: pending.ask.question != nil),
                        to: from,
                        contextToken: pending.contextToken
                    )
                } else {
                    // Refused or out of reach: the ask stays, so it can be
                    // answered again here or in Apelin.
                    pendingAsks[from] = pending
                }
                return
            case .needsApp:
                await send(ChannelReplies.onlyInApp(), to: from, contextToken: pending.contextToken)
                return
            case .unclear:
                // A sentence rather than an answer: a new turn, and the ask
                // goes on waiting.
                break
            }
        }
        let reply = Reply(userID: from, contextToken: incoming.contextToken, text: "", turns: 0)
        if let peer = peers.items.first(where: { $0.userID == from }) {
            await ask(peer, text: text, reply: reply)
        } else {
            await openConversation(with: from, text: text, reply: reply)
        }
    }

    /// Sends a message to the conversation the phone already talks in. The
    /// worker that served it may have ended while the phone was away: the
    /// session host says so (`notFound`), and the same conversation is
    /// opened again with this message as its prompt.
    private func ask(_ peer: Peer, text: String, reply: Reply) async {
        replies[peer.sessionID] = collect(reply, into: replies[peer.sessionID])
        do {
            try await deliver(WireRequest(AgentPromptRequest(sessionID: peer.sessionID, text: text)))
        } catch let error as ApelinError where error.code == .notFound {
            replies[peer.sessionID] = reply
            await openConversation(with: peer.userID, text: text, reply: reply, reopening: peer)
        } catch {
            replies[peer.sessionID] = nil
            failed(error, to: reply)
        }
    }

    /// Opens the conversation a phone talks in — the channel's project, or a
    /// temporary chat tied to a UUID the peer keeps — and sends the message
    /// as its first prompt.
    private func openConversation(
        with userID: String,
        text: String,
        reply: Reply,
        reopening peer: Peer? = nil
    ) async {
        let sessionID = peer?.sessionID ?? UUID().uuidString.lowercased()
        let temporaryID = peer?.temporaryID ?? UUID().uuidString.lowercased()
        // Collected before the open: a turn can start writing while the
        // reply to the open is still on its way.
        replies[sessionID] = collect(reply, into: nil)
        var request = AgentOpenRequest(
            projectName: record.projectName,
            temporaryID: record.projectName == nil ? temporaryID : nil,
            sessionID: sessionID,
            approvalMode: record.approvalMode,
            prompt: text,
            title: peer == nil ? AgentConversationRules.title(text) : nil
        )
        // A channel conversation is read, not watched: nothing asks for the
        // screen on its behalf.
        request.asksBeforeScreen = false
        guard let wire = try? WireRequest(request) else {
            replies[sessionID] = nil
            message = "This message could not be turned into a request."
            return
        }
        let answer = await route(wire)
        switch answer.result {
        case let .failure(error):
            replies[sessionID] = nil
            message = error.message
        case .success:
            let stored = Peer(
                userID: userID,
                sessionID: sessionID,
                temporaryID: record.projectName == nil ? temporaryID : nil,
                title: peer?.title ?? AgentConversationRules.title(text),
                updatedAt: Date()
            )
            if let index = peers.items.firstIndex(where: { $0.userID == userID }) {
                peers.items[index] = stored
            } else {
                peers.items.append(stored)
            }
            savePeers()
        }
    }

    /// Sends one approval or question to the phone that talks in this
    /// conversation, and keeps it for the reply.
    private func announce(_ payload: JSONValue, sessionID: String) async {
        guard let peer = peers.items.first(where: { $0.sessionID == sessionID }),
              let approvalID = payload["approvalID"]?.stringValue
        else { return }
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
            arguments: payload["arguments"]?.stringValue
        )
        let contextToken = lastContextTokens[peer.userID]
        pendingAsks[peer.userID] = PendingAsk(ask: ask, contextToken: contextToken)
        await send(ask.text, to: peer.userID, contextToken: contextToken)
    }

    /// The reader's answer, given to the session as the app gives one: an
    /// approval once, or a question answered with the labels it offered.
    private func settle(_ ask: ChannelAsk, answer: ChannelAnswer) async -> Bool {
        let request = AgentApproveRequest(
            sessionID: ask.sessionID,
            approvalID: ask.approvalID,
            decision: answer.approved ? .approve : .deny,
            scope: .once,
            answer: answer.approved ? answer.answer : nil
        )
        guard let wire = try? WireRequest(request) else { return false }
        let reply = await route(wire)
        if case let .failure(error) = reply.result {
            message = error.message
            return false
        }
        return true
    }

    private func clearAsk(_ approvalID: String?) {
        guard let approvalID else { return }
        for (userID, pending) in pendingAsks where pending.ask.approvalID == approvalID {
            pendingAsks[userID] = nil
        }
    }

    /// The run ended: the ask it was waiting on can no longer be answered.
    private func clearAsks(session: String) {
        for (userID, pending) in pendingAsks where pending.ask.sessionID == session {
            pendingAsks[userID] = nil
        }
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

    private func deliver(_ request: WireRequest) async throws {
        let reply = await route(request)
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

    private func send(reply: Reply) async {
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        for chunk in IlinkText.chunks(of: text) {
            await send(chunk, to: reply.userID, contextToken: reply.contextToken)
        }
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
