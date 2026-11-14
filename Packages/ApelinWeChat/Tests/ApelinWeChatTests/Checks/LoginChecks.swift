import ApelinWeChat
import Foundation

private func qrCodeReply(_ id: String) -> String {
    #"{"ret":0,"qrcode":"\#(id)","qrcode_img_content":"https://ilinkai.weixin.qq.com/\#(id).png"}"#
}

private func statusReply(_ status: String, extra: String = "") -> String {
    if extra.isEmpty {
        return #"{"status":"\#(status)"}"#
    }
    return #"{"status":"\#(status)",\#(extra)}"#
}

/// base64 of the decimal the `X-WECHAT-UIN` header carries.
private func decodedUIN(_ request: IlinkHTTPRequest) throws -> String {
    guard let header = request.headers["X-WECHAT-UIN"],
          let data = Data(base64Encoded: header),
          let text = String(data: data, encoding: .utf8)
    else {
        throw CheckFailure(message: "X-WECHAT-UIN is not base64 text")
    }
    return text
}

/// The whole login: the QR code request and its headers, the status walk, the
/// verify code asked twice, and the confirmed credential landing in the file.
func checkIlinkLoginFlow() async throws {
    let folder = try makeTemporaryFolder("login")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = IlinkFileSessionStore(fileURL: folder.appendingPathComponent("session.json"))

    let replies = [
        statusReply("wait"),
        statusReply("scaned"),
        statusReply("need_verifycode"),
        statusReply("need_verifycode"),
        statusReply(
            "confirmed",
            extra: #""bot_token":"token-xyz","ilink_bot_id":"bot-42","baseurl":"https://idc.weixin.qq.com","ilink_user_id":"user-42""#
        ),
    ]
    let round = LockedBox(0)
    let transport = FakeTransport { request in
        switch request.url.path {
        case "/ilink/bot/get_bot_qrcode":
            return httpResponse(200, qrCodeReply("qr-1"))
        case "/ilink/bot/get_qrcode_status":
            let index = round.read()
            round.update { $0 += 1 }
            return httpResponse(200, index < replies.count ? replies[index] : statusReply("wait"))
        case "/ilink/bot/sendmessage":
            return httpResponse(200, #"{"ret":0,"message_id":9001}"#)
        default:
            throw IlinkFailure.invalidResponse("unexpected path")
        }
    }

    let client = IlinkClient(transport: transport, store: store)
    let code = try await client.beginLogin()
    try expectEqual(code.id, "qr-1", "the qrcode id")
    try expectEqual(code.content, "https://ilinkai.weixin.qq.com/qr-1.png", "the content to show")
    try expectEqual(code.imageURL?.host, "ilinkai.weixin.qq.com", "the image url")
    try expect(code.expiresAt.timeIntervalSince(Date()) > 200, "the code has a local lifetime")

    let first = transport.requests[0]
    try expectEqual(first.method, "POST", "the QR code is a POST")
    try expectEqual(first.headers["AuthorizationType"], "ilink_bot_token", "AuthorizationType")
    try expectEqual(first.headers["iLink-App-Id"], "bot", "iLink-App-Id")
    try expectEqual(first.headers["iLink-App-ClientVersion"], "132106", "iLink-App-ClientVersion")
    try expectEqual(first.headers["Content-Type"], "application/json", "Content-Type")
    try expect(first.headers["Authorization"] == nil, "the QR code request carries no token")
    let uin = try decodedUIN(first)
    try expect(!uin.isEmpty && uin.allSatisfy(\.isNumber), "X-WECHAT-UIN is a decimal in base64")
    let qrBody = try jsonObject(first.body)
    try expect(qrBody["local_token_list"] is [Any], "the QR body carries local_token_list")
    try expect(qrBody["base_info"] == nil, "the QR body carries no base_info")

    try expectEqual(try await client.pollLogin(code), IlinkLoginStatus.pending, "wait")
    try expectEqual(try await client.pollLogin(code), IlinkLoginStatus.scanned, "scaned")
    let asked = try await client.pollLogin(code)
    guard case .needsVerification(let firstRetry) = asked else {
        throw CheckFailure(message: "need_verifycode asks for the phone's number")
    }
    try expect(!firstRetry, "the first request for a code is not a retry")

    let again = try await client.pollLogin(code, verifyCode: "111111")
    guard case .needsVerification(let secondRetry) = again else {
        throw CheckFailure(message: "a refused code asks again")
    }
    try expect(secondRetry, "asking again means the previous number was wrong")
    let statusRequest = transport.requests[transport.requests.count - 1]
    let query = URLComponents(url: statusRequest.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    try expectEqual(query.first(where: { $0.name == "verify_code" })?.value, "111111", "the code is sent back")

    let confirmed = try await client.pollLogin(code, verifyCode: "222222")
    guard case .confirmed(let credentials) = confirmed else {
        throw CheckFailure(message: "the login confirms")
    }
    try expectEqual(credentials.botID, "bot-42", "the bot id")
    try expectEqual(credentials.token, "token-xyz", "the token")
    try expectEqual(credentials.userID, "user-42", "the iLink user id")

    let state = await client.state
    try expectEqual(state, IlinkClientState.idle, "a confirmed login leaves the client idle")
    try expect(!String(describing: state).contains("token-xyz"), "the state carries no token")
    try expect(!String(describing: credentials).contains("token-xyz"), "the credential's description hides the token")

    guard case .present(let saved) = try store.read() else {
        throw CheckFailure(message: "the confirmed credential is written")
    }
    try expectEqual(saved.credentials.token, "token-xyz", "the file holds the token")
    try expectEqual(saved.baseURL?.host, "idc.weixin.qq.com", "the file holds the IDC base")

    let sent = try await client.send(text: "hi", to: IlinkPeer(id: "peer-42"))
    try expectEqual(sent.clientID.hasPrefix("apelin-wechat-"), true, "the client id names this adapter")
    try expectEqual(transport.requests.last?.url.host, "idc.weixin.qq.com", "a send goes to the IDC host")
    try expectEqual(transport.requests.last?.headers["Authorization"], "Bearer token-xyz", "the send carries the token")

    // A second login supersedes the first, and either way it is cancelled.
    let replacement = try await client.beginLogin()
    await client.cancelLogin()
    do {
        _ = try await client.pollLogin(replacement)
        throw CheckFailure(message: "a cancelled login must not poll")
    } catch let failure as IlinkFailure {
        guard case .loginEnded(.superseded) = failure else { throw failure }
    }
}

/// The host an IDC move may name, and the statuses that end a login.
func checkIlinkLoginRedirects() async throws {
    let folder = try makeTemporaryFolder("login-redirect")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = IlinkFileSessionStore(fileURL: folder.appendingPathComponent("session.json"))

    let evil = FakeTransport { request in
        if request.url.path == "/ilink/bot/get_bot_qrcode" {
            return httpResponse(200, qrCodeReply("q1"))
        }
        return httpResponse(200, statusReply("scaned_but_redirect", extra: #""redirect_host":"evil.example""#))
    }
    let refused = IlinkClient(transport: evil, store: store)
    let refusedCode = try await refused.beginLogin()
    do {
        _ = try await refused.pollLogin(refusedCode)
        throw CheckFailure(message: "a foreign redirect host is refused")
    } catch let failure as IlinkFailure {
        guard case .untrustedURL = failure else { throw failure }
    }

    let moving = FakeTransport { request in
        if request.url.path == "/ilink/bot/get_bot_qrcode" {
            return httpResponse(200, qrCodeReply("q2"))
        }
        if request.url.host == "ilinkai.weixin.qq.com" {
            return httpResponse(200, statusReply("scaned_but_redirect", extra: #""redirect_host":"idc.weixin.qq.com""#))
        }
        return httpResponse(200, statusReply("wait"))
    }
    let client = IlinkClient(transport: moving, store: store)
    let code = try await client.beginLogin()
    let moved = try await client.pollLogin(code)
    guard case .redirecting(let target) = moved else {
        throw CheckFailure(message: "a trusted redirect host moves the session")
    }
    try expectEqual(target.host, "idc.weixin.qq.com", "the IDC host")
    try expectEqual(try await client.pollLogin(code), IlinkLoginStatus.pending, "polling continues on the IDC")
    try expectEqual(moving.requests.last?.url.host, "idc.weixin.qq.com", "the next poll goes to the IDC")

    let endings: [(String, IlinkLoginStatus)] = [
        (statusReply("binded_redirect"), IlinkLoginStatus.ended(.boundToAnotherChannel)),
        (statusReply("verify_code_blocked"), IlinkLoginStatus.ended(.verificationBlocked)),
        (statusReply("a-status-this-version-does-not-know"), IlinkLoginStatus.pending),
    ]
    for (reply, expected) in endings {
        let transport = FakeTransport { request in
            if request.url.path == "/ilink/bot/get_bot_qrcode" {
                return httpResponse(200, qrCodeReply("q3"))
            }
            return httpResponse(200, reply)
        }
        let ending = IlinkClient(transport: transport, store: store)
        let endingCode = try await ending.beginLogin()
        try expectEqual(try await ending.pollLogin(endingCode), expected, reply)
    }

    // A status call that reaches its read timeout is a wait.
    let timingOut = FakeTransport { request in
        if request.url.path == "/ilink/bot/get_bot_qrcode" {
            return httpResponse(200, qrCodeReply("q4"))
        }
        throw IlinkFailure.timedOut
    }
    let patient = IlinkClient(transport: timingOut, store: store)
    let patientCode = try await patient.beginLogin()
    try expectEqual(try await patient.pollLogin(patientCode), IlinkLoginStatus.pending, "a timed-out status is a wait")

    // The local QR lifetime runs out, and the code limit ends the login.
    let now = LockedBox(Date(timeIntervalSince1970: 1_000_000))
    let staleTransport = FakeTransport { request in
        if request.url.path == "/ilink/bot/get_bot_qrcode" {
            return httpResponse(200, qrCodeReply("q5"))
        }
        return httpResponse(200, statusReply("wait"))
    }
    let stale = IlinkClient(
        configuration: IlinkConfiguration(maxQRCodes: 1),
        transport: staleTransport,
        store: store,
        clock: { now.read() }
    )
    let staleCode = try await stale.beginLogin()
    now.update { $0 = $0.addingTimeInterval(301) }
    let ended = try await stale.pollLogin(staleCode)
    guard case .ended(.qrExpired) = ended else {
        throw CheckFailure(message: "an expired local code with none left ends the login")
    }
}

/// `expired` asks for a replacement code, and the login ends after the code
/// limit.
func checkIlinkLoginCodeReplacement() async throws {
    let folder = try makeTemporaryFolder("login-expired")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = IlinkFileSessionStore(fileURL: folder.appendingPathComponent("session.json"))
    let codes = LockedBox(0)
    let transport = FakeTransport { request in
        if request.url.path == "/ilink/bot/get_bot_qrcode" {
            codes.update { $0 += 1 }
            return httpResponse(200, qrCodeReply("qr-\(codes.read())"))
        }
        return httpResponse(200, statusReply("expired"))
    }
    let client = IlinkClient(
        configuration: IlinkConfiguration(maxQRCodes: 2),
        transport: transport,
        store: store
    )
    let first = try await client.beginLogin()
    let replacement = try await client.pollLogin(first)
    guard case .expired(let next) = replacement else {
        throw CheckFailure(message: "an expired code is replaced")
    }
    try expect(next.id != first.id, "the replacement is a new code")
    try expectEqual(codes.read(), 2, "a second code was asked")
    let ended = try await client.pollLogin(next)
    guard case .ended(.qrExpired) = ended else {
        throw CheckFailure(message: "after the code limit the login ends")
    }
}
