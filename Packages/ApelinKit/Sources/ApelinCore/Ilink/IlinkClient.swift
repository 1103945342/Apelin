import Foundation

/// The iLink bot API, as the session host calls it: one HTTPS JSON endpoint
/// per operation, with the header set the official plugin sends — an
/// `Authorization` bearer for everything but the login, and a random
/// `X-WECHAT-UIN` per request (the API expects it to differ).
///
/// Nothing here logs, and no error carries the token: a failure names the
/// call, the HTTP status and what the server said, never the credential.
public struct IlinkClient {
    /// `ilinkai.weixin.qq.com`, the host every QR code request goes to.
    public static let defaultBaseURL = URL(string: "https://ilinkai.weixin.qq.com")!
    /// The bot type this build registers as.
    public static let defaultBotType = "3"
    /// The `iLink-App-ClientVersion` the API reads: 2.4.10 as 0x0002040A.
    public static let clientVersion = (2 << 16) | (4 << 8) | 10
    public static let appID = "bot"
    /// Self-declared name, as `bot_agent` (UA-style, ASCII).
    public static let agentName = "Apelin/1.0"

    public let baseURL: URL
    public let token: String?
    private let session: URLSession

    /// A client for one host, with or without a signed-in bot.
    public init(baseURL: URL = IlinkClient.defaultBaseURL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 90
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        session = URLSession(configuration: configuration)
    }

    /// The same client, signed in to `baseURL` as `token`.
    public func signing(in baseURL: URL, token: String?) -> IlinkClient {
        IlinkClient(baseURL: baseURL, token: token)
    }

    // MARK: Login

    /// A fresh code to scan. `localTokens` names the bots this device is
    /// signed in to already, which the server uses to answer
    /// `bindedRedirect` instead of issuing another credential.
    public func requestQRCode(botType: String = IlinkClient.defaultBotType, localTokens: [String] = []) async throws -> IlinkQRCode {
        var request = try makeRequest(path: "ilink/bot/get_bot_qrcode")
        request.httpMethod = "POST"
        request.url = url(path: "ilink/bot/get_bot_qrcode", query: [URLQueryItem(name: "bot_type", value: botType)])
        request.httpBody = try JSONCoding.encode(LocalTokens(tokens: localTokens))
        return try await perform(request, as: IlinkQRCode.self, label: "sign-in code")
    }

    /// One status poll. The server holds it open for about 35 seconds while
    /// nothing happens, so the request's own timeout is longer.
    public func loginStatus(
        _ qrcode: String,
        verifyCode: String? = nil,
        baseURL: URL? = nil
    ) async throws -> IlinkLoginPoll {
        var query = [URLQueryItem(name: "qrcode", value: qrcode)]
        if let verifyCode, !verifyCode.isEmpty {
            query.append(URLQueryItem(name: "verify_code", value: verifyCode))
        }
        var request = try makeRequest(path: "ilink/bot/get_qrcode_status", baseURL: baseURL)
        request.url = url(path: "ilink/bot/get_qrcode_status", query: query, baseURL: baseURL)
        request.timeoutInterval = 40
        return try await perform(request, as: IlinkLoginPoll.self, label: "sign-in status")
    }

    // MARK: Messages

    /// The messages that arrived since `buffer`, or none when the server held
    /// the request to its long-poll timeout. `buffer` is the answer's own
    /// `buffer` and is empty the first time.
    public func updates(buffer: String = "") async throws -> IlinkUpdates {
        struct Body: Encodable {
            var get_updates_buf: String
            var base_info: BaseInfo
        }
        var request = try makeRequest(path: "ilink/bot/getupdates")
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.httpBody = try JSONCoding.encode(Body(get_updates_buf: buffer, base_info: baseInfo()))
        do {
            return try await perform(request, as: IlinkUpdates.self, label: "messages")
        } catch let failure as IlinkFailure where failure.isTimeout {
            // A long poll that ran out is a poll with nothing in it.
            return IlinkUpdates(buffer: buffer)
        }
    }

    /// Sends one text message in `to`'s thread. Answers the server's id.
    @discardableResult
    public func send(
        text: String,
        to userID: String,
        contextToken: String?,
        clientID: String = UUID().uuidString.lowercased()
    ) async throws -> String? {
        struct Body: Encodable {
            var msg: IlinkMessage
            var base_info: BaseInfo
        }
        // `from_user_id` is the empty string on a bot's own message, as the
        // official plugin sends it: the credential says who the bot is.
        let message = IlinkMessage(
            fromUserID: "",
            toUserID: userID,
            clientID: clientID,
            messageType: .bot,
            messageState: .finish,
            items: [IlinkMessageItem(type: .text, text: text)],
            contextToken: contextToken
        )
        var request = try makeRequest(path: "ilink/bot/sendmessage")
        request.httpMethod = "POST"
        request.httpBody = try JSONCoding.encode(Body(msg: message, base_info: baseInfo()))
        let reply = try await perform(request, as: SentMessage.self, label: "reply")
        if let ret = reply.ret, ret != 0 {
            throw IlinkFailure.http(status: nil, message: "WeChat refused the reply (ret \(ret)\(reply.errmsg.map { ": \($0)" } ?? ""))")
        }
        return reply.messageID
    }

    /// Tells WeChat this client is up, so messages are delivered to it.
    public func notifyStart() async throws {
        try await notify(path: "ilink/bot/msg/notifystart", label: "start notice")
    }

    /// Tells WeChat this client is stopping.
    public func notifyStop() async throws {
        try await notify(path: "ilink/bot/msg/notifystop", label: "stop notice")
    }

    // MARK: Plumbing

    private struct LocalTokens: Encodable {
        var local_token_list: [String]

        init(tokens: [String]) {
            local_token_list = tokens
        }
    }

    struct BaseInfo: Encodable {
        var channel_version: String
        var bot_agent: String
    }

    private struct SentMessage: Decodable {
        var messageID: String?
        var ret: Int?
        var errmsg: String?

        private enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
            case ret
            case errmsg
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? container.decode(UInt64.self, forKey: .messageID) {
                messageID = String(number)
            } else {
                messageID = try? container.decodeIfPresent(String.self, forKey: .messageID)
            }
            ret = try container.decodeIfPresent(Int.self, forKey: .ret)
            errmsg = try container.decodeIfPresent(String.self, forKey: .errmsg)
        }
    }

    func baseInfo() -> BaseInfo {
        BaseInfo(channel_version: "1.0", bot_agent: IlinkClient.agentName)
    }

    private func notify(path: String, label: String) async throws {
        struct Body: Encodable {
            var base_info: BaseInfo
        }
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.httpBody = try JSONCoding.encode(Body(base_info: baseInfo()))
        _ = try await performData(request, label: label)
    }

    func url(path: String, query: [URLQueryItem] = [], baseURL: URL? = nil) -> URL {
        var components = URLComponents(
            url: (baseURL ?? self.baseURL).appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            components.queryItems = query
        }
        return components.url!
    }

    func makeRequest(path: String, baseURL: URL? = nil) throws -> URLRequest {
        var request = URLRequest(url: url(path: path, baseURL: baseURL))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ilink_bot_token", forHTTPHeaderField: "AuthorizationType")
        request.setValue(Self.randomUIN(), forHTTPHeaderField: "X-WECHAT-UIN")
        request.setValue(IlinkClient.appID, forHTTPHeaderField: "iLink-App-Id")
        request.setValue(String(IlinkClient.clientVersion), forHTTPHeaderField: "iLink-App-ClientVersion")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// A random uint32 as a decimal string, base64-encoded — what the API
    /// reads as the device's identity.
    static func randomUIN() -> String {
        Data(String(UInt32.random(in: 0 ... UInt32.max)).utf8).base64EncodedString()
    }

    func perform<T: Decodable>(_ request: URLRequest, as type: T.Type, label: String) async throws -> T {
        let data = try await performData(request, label: label)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw IlinkFailure.http(status: nil, message: "WeChat's \(label) answer could not be read")
        }
    }

    func performData(_ request: URLRequest, label: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut {
                throw IlinkFailure.timeout(label: label)
            }
            throw IlinkFailure.http(status: nil, message: "WeChat could not be reached (\(error.code.rawValue)); check the network and try again")
        }
        if let response = response as? HTTPURLResponse, !(200 ... 299).contains(response.statusCode) {
            throw IlinkFailure.http(status: response.statusCode, message: "WeChat answered \(response.statusCode) to the \(label) request")
        }
        return data
    }

    /// The body and the response itself, for a call whose answer is a
    /// header (a CDN upload answers with `x-encrypted-param`).
    func performRaw(_ request: URLRequest, label: String) async throws -> (Data, HTTPURLResponse?) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut {
                throw IlinkFailure.timeout(label: label)
            }
            throw IlinkFailure.http(status: nil, message: "WeChat could not be reached (\(error.code.rawValue)); check the network and try again")
        }
        let http = response as? HTTPURLResponse
        if let http, !(200 ... 299).contains(http.statusCode) {
            throw IlinkFailure.http(status: http.statusCode, message: "WeChat answered \(http.statusCode) to the \(label) request")
        }
        return (data, http)
    }
}

/// Why an iLink call did not answer. `message` is safe to show and safe to
/// log: it never holds the token.
public struct IlinkFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public var status: Int?
    public var message: String
    /// The server simply did not answer in time (a long poll running out).
    public var isTimeout: Bool

    public init(status: Int?, message: String, isTimeout: Bool = false) {
        self.status = status
        self.message = message
        self.isTimeout = isTimeout
    }

    public static func timeout(label: String) -> IlinkFailure {
        IlinkFailure(status: nil, message: "WeChat did not answer the \(label) request in time", isTimeout: true)
    }

    public static func http(status: Int?, message: String) -> IlinkFailure {
        IlinkFailure(status: status, message: message)
    }

    public var description: String {
        message
    }
}
