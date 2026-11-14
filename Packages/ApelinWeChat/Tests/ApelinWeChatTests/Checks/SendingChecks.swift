import ApelinWeChat
import Foundation

/// What a send puts on the wire, how a receipt that does not parse is taken,
/// and the one thing that makes it fail.
func checkIlinkSending() async throws {
    let folder = try makeTemporaryFolder("sending")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = IlinkFileSessionStore(fileURL: folder.appendingPathComponent("session.json"))
    try store.write(makeSession(token: "token-1", cursor: "c0", tokens: ["peer-1": "ctx-9"]))

    let transport = FakeTransport { request in
        switch request.url.path {
        case "/ilink/bot/sendmessage":
            // A receipt this version cannot read still means the message went out.
            return httpResponse(200, "accepted, not json")
        case "/ilink/bot/sendtyping":
            return httpResponse(200, "{}")
        default:
            throw IlinkFailure.invalidResponse("unexpected path")
        }
    }
    let client = IlinkClient(transport: transport, store: store)
    try await client.restoreSession()

    let peer = IlinkPeer(id: "peer-1")
    let result = try await client.send(text: "hi there", to: peer)
    try expectEqual(result.messageID, nil, "an unreadable receipt is not a failed send")
    try expect(result.clientID.hasPrefix("apelin-wechat-"), "the client id names the adapter")
    try expect(result.acceptedAt.timeIntervalSince1970 > 0, "the send is timestamped")

    let request = transport.requests[0]
    try expectEqual(request.method, "POST", "sendmessage is a POST")
    try expectEqual(request.url.path, "/ilink/bot/sendmessage", "its path")
    try expectEqual(request.headers["Authorization"], "Bearer token-1", "the send carries the bot token")
    try expectEqual(request.headers["AuthorizationType"], "ilink_bot_token", "AuthorizationType")
    try expect(request.description.contains("sendmessage"), "the description names the path")
    try expect(!request.description.contains("token-1"), "a request's description carries no token")

    let body = try jsonObject(request.body)
    let message = try expectValue(body["msg"] as? [String: Any], "the body carries msg")
    try expectEqual(message["from_user_id"] as? String, "", "from_user_id is empty")
    try expectEqual(message["to_user_id"] as? String, "peer-1", "to_user_id is the peer")
    try expectEqual(message["message_type"] as? Int, 2, "message_type is 2")
    try expectEqual(message["message_state"] as? Int, 2, "message_state is 2")
    try expectEqual(message["context_token"] as? String, "ctx-9", "the reply context travels with the send")
    let items = try expectValue(message["item_list"] as? [[String: Any]], "item_list")
    try expectEqual(items.count, 1, "one item")
    try expectEqual(items[0]["type"] as? Int, 1, "the item is text")
    try expectEqual((items[0]["text_item"] as? [String: Any])?["text"] as? String, "hi there", "the text")
    let base = try expectValue(body["base_info"] as? [String: Any], "base_info")
    try expectEqual(base["channel_version"] as? String, "2.4.10", "channel_version")
    try expectEqual(base["bot_agent"] as? String, "apelin", "bot_agent")

    // Only an HTTP status outside 200..<300 fails.
    transport.set { _ in httpResponse(500, #"{"ret":0}"#) }
    do {
        _ = try await client.send(text: "again", to: peer)
        throw CheckFailure(message: "a 500 must fail the send")
    } catch let failure as IlinkFailure {
        try expectEqual(failure, IlinkFailure.http(status: 500), "the HTTP status is the failure")
    }
    transport.set { _ in httpResponse(200, "{}") }
    try await client.sendTyping(.active, to: peer)
    let typing = transport.requests.last
    guard let typing else { throw CheckFailure(message: "the typing request must be recorded") }
    try expectEqual(typing.url.path, "/ilink/bot/sendtyping", "the typing path")
    let typingBody = try jsonObject(typing.body)
    try expectEqual(typingBody["ilink_user_id"] as? String, "peer-1", "the typing user")
    try expectEqual(typingBody["status"] as? Int, 1, "active typing")
    try expectEqual(typingBody["context_token"] as? String, "ctx-9", "the typing context")

    transport.set { _ in httpResponse(503, "") }
    do {
        try await client.sendTyping(.idle, to: peer)
        throw CheckFailure(message: "a 503 must fail the typing request")
    } catch let failure as IlinkFailure {
        try expectEqual(failure, IlinkFailure.http(status: 503), "the typing failure")
    }

    let token = await client.contextToken(for: peer)
    try expectEqual(token, "ctx-9", "the stored context token is readable")
}

/// A small helper so a missing field fails with a message, not a crash.
func expectValue<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else { throw CheckFailure(message: "missing \(what)") }
    return value
}
