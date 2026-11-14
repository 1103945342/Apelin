import Foundation

/// What the client reports to a log handler. Every value here is safe to
/// print: no token, no header value, no URL.
public enum IlinkLogEvent: Sendable, Equatable {
    case pollingStarted
    case pollingRound(delivered: Int)
    case loginStatus(String)
    case loginConfirmed(botID: String)
    case backoff(attempt: Int, seconds: Int)
    case pollingFailed(String)
    case sessionWriteFailed
    case sent(peer: String, status: Int)
    case stopped
}

/// Where the client stands. It carries no credential.
public enum IlinkClientState: Sendable, Equatable {
    case idle
    case loggingIn
    case running
    case reconnecting(attempt: Int)
    case stopped
    case failed(IlinkFailure)
}

/// The iLink bot client: QR login, the `getupdates` long poll, and text sends.
///
/// One generation counter guards the lifecycle. `stop()` and `beginLogin()`
/// move it, and every suspended call compares it on waking, so a poll loop or
/// a login step from before cannot write a cursor, revive polling or replace a
/// credential.
public actor IlinkClient {
    public typealias Clock = @Sendable () -> Date
    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    public typealias Logger = @Sendable (IlinkLogEvent) -> Void

    private let configuration: IlinkConfiguration
    private let transport: IlinkTransport
    private let store: IlinkSessionStore
    private let clock: Clock
    private let sleeper: Sleeper
    private let logger: Logger

    private var baseURL: URL
    private var session: IlinkSession?
    private var filter = IlinkInboundFilter()
    private var hub: IlinkUpdateHub?
    private var pollingTask: Task<Void, Never>?
    private var generation = 0
    private var loginGeneration = 0
    private var loginState: IlinkLoginState?
    private var stateStorage: IlinkClientState = .idle

    public init(
        configuration: IlinkConfiguration = IlinkConfiguration(),
        transport: IlinkTransport = URLSessionIlinkTransport(),
        store: IlinkSessionStore,
        clock: @escaping Clock = { Date() },
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) },
        log: @escaping Logger = { _ in }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.store = store
        self.clock = clock
        self.sleeper = sleeper
        self.logger = log
        self.baseURL = configuration.apiBaseURL
    }

    /// No credential in it.
    public var state: IlinkClientState { stateStorage }

    public var isLoggedIn: Bool { session != nil }

    public var loggedInBotID: String? { session?.credentials.botID }

    // MARK: - Session

    /// Reads the session file. `false` means there is none. A file that exists
    /// and does not read throws `sessionUnreadable` and is left untouched.
    @discardableResult
    public func restoreSession() throws -> Bool {
        let stored: IlinkStoredSession
        do {
            stored = try store.read()
        } catch {
            throw IlinkFailure.sessionUnreadable(path: "session", reason: "cannot read")
        }
        switch stored {
        case .absent:
            return false
        case .unreadable(let path, let reason):
            throw IlinkFailure.sessionUnreadable(path: path, reason: reason)
        case .present(let restored):
            if let storedBase = restored.baseURL {
                guard configuration.trust.permits(storedBase) else {
                    throw IlinkFailure.untrustedURL(storedBase)
                }
                baseURL = storedBase
            }
            session = restored
            filter.updateBotIDs([restored.credentials.botID])
            if pollingTask == nil {
                stateStorage = .idle
            }
            return true
        }
    }

    /// Drops the session file and everything read from it. The only way a file
    /// the client reported as unreadable is ever cleared.
    public func discardSession() throws {
        try store.discard()
        session = nil
        loginState = nil
        filter.updateBotIDs([])
        baseURL = configuration.apiBaseURL
        stateStorage = .idle
    }

    public func contextToken(for peer: IlinkPeer) -> String? {
        session?.contextTokens[peer.id]
    }

    // MARK: - Login

    /// Asks for a QR code and starts a login. A login already in flight is
    /// superseded.
    public func beginLogin() async throws -> IlinkLoginQRCode {
        loginGeneration += 1
        let started = loginGeneration
        loginState = nil
        stateStorage = .loggingIn
        let code = try await fetchQRCode()
        guard started == loginGeneration else { throw IlinkFailure.cancelled }
        loginState = IlinkLoginState(generation: started, code: code, codesIssued: 1)
        return code
    }

    /// One `get_qrcode_status` call. `verifyCode` is the number shown on the
    /// phone, and only the `need_verifycode` status asks for it.
    public func pollLogin(_ code: IlinkLoginQRCode, verifyCode: String? = nil) async throws -> IlinkLoginStatus {
        guard var current = loginState,
              current.generation == loginGeneration,
              current.code.id == code.id
        else {
            throw IlinkFailure.loginEnded(.superseded)
        }
        let now = clock()
        if now >= current.code.expiresAt {
            return try await replaceExpiredCode(state: current, now: now)
        }
        if let deadline = current.verifyDeadline, now >= deadline {
            loginState = nil
            stateStorage = .idle
            return .ended(.verificationTimedOut)
        }

        let reply: IlinkQRCodeStatusReply
        do {
            reply = try await fetchQRCodeStatus(codeID: current.code.id, verifyCode: verifyCode)
        } catch let failure as IlinkFailure {
            // A status call that ran into its timeout is left as a wait: the
            // caller polls again.
            if failure == .timedOut { return .pending }
            throw failure
        }

        let didSendCode = !(verifyCode ?? "").isEmpty
        switch reply.status ?? "wait" {
        case "wait":
            loginState = current
            return .pending
        case "scaned":
            loginState = current
            return .scanned
        case "need_verifycode":
            // A number was sent and the server asks again: that number was
            // wrong. The first request, with no number, is not a retry.
            let retry = current.didSendCode || didSendCode
            if current.verifyDeadline == nil {
                current.verifyDeadline = now.addingTimeInterval(configuration.verifyCodeLifetime)
            }
            current.didSendCode = didSendCode
            current.lastVerifyCode = verifyCode
            loginState = current
            logger(.loginStatus("need_verifycode"))
            return .needsVerification(retry: retry)
        case "verify_code_blocked":
            loginState = nil
            stateStorage = .idle
            return .ended(.verificationBlocked)
        case "expired":
            return try await replaceExpiredCode(state: current, now: now)
        case "scaned_but_redirect":
            guard let host = reply.redirectHost, let url = configuration.trust.hostURL(host) else {
                let refused = reply.redirectHost.flatMap { URL(string: "https://\($0)") } ?? baseURL
                throw IlinkFailure.untrustedURL(refused)
            }
            baseURL = url
            current.redirectHost = host
            loginState = current
            logger(.loginStatus("scaned_but_redirect"))
            return .redirecting(IlinkIDCTarget(host: host))
        case "binded_redirect":
            loginState = nil
            stateStorage = .idle
            return .ended(.boundToAnotherChannel)
        case "confirmed":
            return try confirmed(reply: reply, now: now)
        default:
            // An unknown status is not a failure: poll again.
            loginState = current
            return .pending
        }
    }

    /// Ends the login in flight. A `pollLogin` already suspended answers
    /// `loginEnded(.superseded)`.
    public func cancelLogin() {
        loginGeneration += 1
        loginState = nil
        if stateStorage == .loggingIn {
            stateStorage = .idle
        }
    }

    // MARK: - Updates

    /// The stream of inbound messages, already filtered. One stream per
    /// client; ask for it again after `stop()`.
    public func updates() -> AsyncThrowingStream<IlinkInboundMessage, Error> {
        ensureHub().stream
    }

    /// Starts the `getupdates` long poll.
    public func startUpdates() throws {
        guard session != nil else { throw IlinkFailure.notLoggedIn }
        guard pollingTask == nil else { return }
        _ = ensureHub()
        generation += 1
        let started = generation
        stateStorage = .running
        pollingTask = Task { [weak self] in
            await self?.pollLoop(generation: started)
        }
        logger(.pollingStarted)
    }

    /// Stops polling and ends the stream. The generation moves first, so a
    /// round already in flight cannot deliver or commit anything afterwards.
    public func stop() async {
        generation += 1
        let task = pollingTask
        pollingTask = nil
        task?.cancel()
        hub?.finish()
        hub = nil
        stateStorage = .stopped
        _ = await task?.value
        logger(.stopped)
    }

    // MARK: - Sending

    /// Sends one text message. Only an HTTP status outside 200..<300 is a
    /// failure; a receipt this version cannot read still means it went out.
    public func send(text: String, to peer: IlinkPeer) async throws -> IlinkSendResult {
        guard let credentials = session?.credentials else { throw IlinkFailure.notLoggedIn }
        let clientID = "apelin-wechat-\(UUID().uuidString)"
        let outgoing = IlinkWireOutgoingMessage(
            fromUserID: "",
            toUserID: peer.id,
            clientID: clientID,
            messageType: 2,
            messageState: 2,
            itemList: [IlinkWireOutgoingItem(type: 1, textItem: IlinkWireOutgoingText(text: text))],
            contextToken: session?.contextTokens[peer.id]
        )
        let body = IlinkSendMessageRequest(msg: outgoing, baseInfo: IlinkBaseInfo(configuration))
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw IlinkFailure.invalidResponse("send-body")
        }
        let response = try await post(
            path: IlinkEndpoint.sendMessage,
            body: data,
            token: credentials.token,
            timeout: configuration.requestTimeout
        )
        logger(.sent(peer: peer.id, status: response.status))
        guard (200..<300).contains(response.status) else {
            throw IlinkFailure.http(status: response.status)
        }
        var receipt: IlinkSendReceipt?
        do {
            receipt = try JSONDecoder().decode(IlinkSendReceipt.self, from: response.body)
        } catch {
            receipt = nil
        }
        return IlinkSendResult(
            clientID: clientID,
            messageID: receipt?.messageID,
            acceptedAt: clock()
        )
    }

    public func sendTyping(_ status: IlinkTypingStatus, to peer: IlinkPeer) async throws {
        guard let credentials = session?.credentials else { throw IlinkFailure.notLoggedIn }
        let body = IlinkSendTypingRequest(
            ilinkUserID: peer.id,
            contextToken: session?.contextTokens[peer.id],
            status: status.rawValue,
            baseInfo: IlinkBaseInfo(configuration)
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw IlinkFailure.invalidResponse("typing-body")
        }
        let response = try await post(
            path: IlinkEndpoint.sendTyping,
            body: data,
            token: credentials.token,
            timeout: configuration.requestTimeout
        )
        guard (200..<300).contains(response.status) else {
            throw IlinkFailure.http(status: response.status)
        }
    }

    // MARK: - Polling

    private func pollLoop(generation started: Int) async {
        var failures = 0
        while !Task.isCancelled {
            guard started == generation, session != nil else { return }
            let outcome: Result<IlinkUpdatesBatch, IlinkFailure>
            do {
                outcome = .success(try await fetchUpdates())
            } catch let failure as IlinkFailure {
                outcome = .failure(failure)
            } catch {
                outcome = .failure(.transport("unexpected"))
            }
            guard started == generation else { return }
            switch outcome {
            case .success(let batch):
                failures = 0
                if stateStorage != .running {
                    stateStorage = .running
                }
                apply(batch: batch, generation: started)
            case .failure(let failure):
                if failure == .timedOut {
                    // A long poll that reached its read timeout is an empty
                    // round, not a failure.
                    continue
                }
                if failure == .cancelled || failure == .notLoggedIn {
                    return
                }
                failures += 1
                stateStorage = .reconnecting(attempt: failures)
                logger(.pollingFailed(failure.summary))
                if failures >= configuration.maxConsecutiveFailures {
                    let stopped = IlinkFailure.tooManyFailures(attempts: failures)
                    stateStorage = .failed(stopped)
                    hub?.finish(throwing: stopped)
                    pollingTask = nil
                    return
                }
                let delay = configuration.backoff.delay(forAttempt: failures - 1)
                logger(.backoff(attempt: failures, seconds: configuration.backoff.seconds(forAttempt: failures - 1)))
                do {
                    try await sleeper(delay)
                } catch {
                    return
                }
            }
        }
    }

    private func apply(batch: IlinkUpdatesBatch, generation started: Int) {
        guard started == generation, let hub else { return }
        var tokens: [String: String] = [:]
        var delivered = 0
        var lost = 0
        for raw in batch.messages {
            guard let message = filter.accept(raw, receivedAt: clock()) else { continue }
            if let token = raw.contextToken, !token.isEmpty {
                tokens[raw.fromUserID] = token
            }
            if hub.yield(message) {
                delivered += 1
            } else {
                lost += 1
            }
        }
        // A message that did not go into the stream must be fetched again: the
        // cursor stays where it was.
        guard lost == 0 else { return }
        guard delivered > 0 || batch.cursor != nil else { return }
        commitSession(cursor: batch.cursor, tokens: tokens)
        if delivered > 0 {
            logger(.pollingRound(delivered: delivered))
        }
    }

    private func fetchUpdates() async throws -> IlinkUpdatesBatch {
        guard let credentials = session?.credentials else { throw IlinkFailure.notLoggedIn }
        let body = IlinkGetUpdatesRequest(
            getUpdatesBuf: session?.cursor ?? "",
            baseInfo: IlinkBaseInfo(configuration)
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw IlinkFailure.invalidResponse("updates-body")
        }
        let response = try await post(
            path: IlinkEndpoint.updates,
            body: data,
            token: credentials.token,
            timeout: configuration.longPollTimeout
        )
        guard (200..<300).contains(response.status) else {
            throw IlinkFailure.http(status: response.status)
        }
        let reply: IlinkGetUpdatesReply
        do {
            reply = try IlinkWire.decodeUpdates(response.body)
        } catch let failure as IlinkFailure {
            throw failure
        } catch {
            throw IlinkFailure.invalidResponse("updates")
        }
        if let ret = reply.ret, ret != 0 {
            // Only `ret` marks the round as failed; `errcode` in a normal
            // reply may be non-zero.
            throw IlinkFailure.rejected(ret: ret, errcode: reply.errcode, message: reply.errmsg)
        }
        var messages: [IlinkRawInbound] = []
        for wire in reply.msgs ?? [] {
            if let raw = wire.rawInbound {
                messages.append(raw)
            }
        }
        return IlinkUpdatesBatch(messages: messages, cursor: reply.getUpdatesBuf)
    }

    // MARK: - Login internals

    private func replaceExpiredCode(state current: IlinkLoginState, now: Date) async throws -> IlinkLoginStatus {
        guard current.codesIssued < configuration.maxQRCodes else {
            loginState = nil
            stateStorage = .idle
            return .ended(.qrExpired)
        }
        let code = try await fetchQRCode()
        var next = current
        next.code = code
        next.codesIssued += 1
        next.verifyDeadline = nil
        next.didSendCode = false
        next.lastVerifyCode = nil
        loginState = next
        logger(.loginStatus("expired"))
        return .expired(newCode: code)
    }

    private func confirmed(reply: IlinkQRCodeStatusReply, now: Date) throws -> IlinkLoginStatus {
        guard let token = reply.botToken, !token.isEmpty,
              let botID = reply.ilinkBotID, !botID.isEmpty
        else {
            throw IlinkFailure.invalidResponse("confirmed-without-credentials")
        }
        var nextBase = baseURL
        if let raw = reply.baseurl, !raw.isEmpty {
            guard let url = configuration.trust.baseURL(from: raw) else {
                throw IlinkFailure.untrustedURL(URL(string: raw) ?? baseURL)
            }
            nextBase = url
        }
        let credentials = IlinkCredentials(
            botID: botID,
            token: token,
            userID: reply.ilinkUserID,
            issuedAt: now
        )
        let candidate = IlinkSession(
            credentials: credentials,
            cursor: nil,
            contextTokens: [:],
            baseURL: nextBase,
            updatedAt: now
        )
        do {
            try store.write(candidate)
        } catch {
            throw IlinkFailure.sessionUnwritable(path: "session")
        }
        session = candidate
        baseURL = nextBase
        filter.updateBotIDs([botID])
        loginState = nil
        stateStorage = pollingTask == nil ? .idle : .running
        logger(.loginConfirmed(botID: botID))
        return .confirmed(credentials)
    }

    private func fetchQRCode() async throws -> IlinkLoginQRCode {
        let body = try JSONEncoder().encode(IlinkQRCodeRequest(localTokenList: []))
        let request = try makeRequest(
            method: "POST",
            path: IlinkEndpoint.qrCode,
            query: [URLQueryItem(name: "bot_type", value: "3")],
            body: body,
            token: nil,
            timeout: configuration.requestTimeout
        )
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else {
            throw IlinkFailure.http(status: response.status)
        }
        let reply: IlinkQRCodeReply
        do {
            reply = try JSONDecoder().decode(IlinkQRCodeReply.self, from: response.body)
        } catch {
            throw IlinkFailure.invalidResponse("qrcode")
        }
        if let ret = reply.ret, ret != 0 {
            throw IlinkFailure.rejected(ret: ret, errcode: nil, message: nil)
        }
        guard let id = reply.qrcode, !id.isEmpty else {
            throw IlinkFailure.invalidResponse("qrcode-missing")
        }
        let content = reply.qrcodeImgContent ?? id
        var imageURL: URL?
        if let candidate = URL(string: content), candidate.scheme?.lowercased() == "https" {
            imageURL = candidate
        }
        let now = clock()
        return IlinkLoginQRCode(
            id: id,
            content: content,
            imageURL: imageURL,
            expiresAt: now.addingTimeInterval(configuration.qrLifetime)
        )
    }

    private func fetchQRCodeStatus(codeID: String, verifyCode: String?) async throws -> IlinkQRCodeStatusReply {
        var query = [URLQueryItem(name: "qrcode", value: codeID)]
        if let verifyCode, !verifyCode.isEmpty {
            query.append(URLQueryItem(name: "verify_code", value: verifyCode))
        }
        let request = try makeRequest(
            method: "GET",
            path: IlinkEndpoint.qrCodeStatus,
            query: query,
            body: nil,
            token: nil,
            timeout: configuration.requestTimeout
        )
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else {
            throw IlinkFailure.http(status: response.status)
        }
        do {
            return try JSONDecoder().decode(IlinkQRCodeStatusReply.self, from: response.body)
        } catch {
            throw IlinkFailure.invalidResponse("qrcode-status")
        }
    }

    // MARK: - Plumbing

    private func ensureHub() -> IlinkUpdateHub {
        if let hub { return hub }
        let created = IlinkUpdateHub()
        hub = created
        return created
    }

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        token: String?,
        timeout: TimeInterval
    ) throws -> IlinkHTTPRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw IlinkFailure.untrustedURL(baseURL)
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, configuration.trust.permits(url) else {
            throw IlinkFailure.untrustedURL(components.url ?? baseURL)
        }
        var headers = IlinkHeaders.base(configuration)
        if let token {
            headers["Authorization"] = "Bearer \(token)"
        }
        return IlinkHTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: timeout,
            carriesCredential: token != nil
        )
    }

    private func post(
        path: String,
        body: Data,
        token: String?,
        timeout: TimeInterval
    ) async throws -> IlinkHTTPResponse {
        let request = try makeRequest(
            method: "POST",
            path: path,
            query: [],
            body: body,
            token: token,
            timeout: timeout
        )
        return try await transport.send(request)
    }

    /// Writes the cursor and the reply tokens. The cursor in memory moves only
    /// after the file was written, so a failed write leaves the old cursor to
    /// be fetched again.
    private func commitSession(cursor: String?, tokens: [String: String]) {
        guard var current = session else { return }
        if !tokens.isEmpty {
            current.contextTokens.merge(tokens) { _, new in new }
            session = current
        }
        guard let latest = session else { return }
        var next = latest
        if let cursor {
            next.cursor = cursor
        }
        // An empty round with the cursor already committed writes nothing.
        if tokens.isEmpty, next.cursor == latest.cursor {
            return
        }
        next.updatedAt = clock()
        do {
            try store.write(next)
            session = next
        } catch {
            logger(.sessionWriteFailed)
        }
    }
}

/// One answer of `getupdates`, already mapped.
struct IlinkUpdatesBatch: Sendable {
    let messages: [IlinkRawInbound]
    /// nil when the reply carried no `get_updates_buf`: the previous cursor is
    /// kept.
    let cursor: String?
}

/// The login in flight.
struct IlinkLoginState: Sendable {
    let generation: Int
    var code: IlinkLoginQRCode
    var codesIssued: Int
    var verifyDeadline: Date?
    var didSendCode = false
    var lastVerifyCode: String?
    var redirectHost: String?
}
