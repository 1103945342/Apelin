import ApelinWeChat
import Foundation

private func inbound(
    _ id: String,
    from: String = "peer-1",
    to: String = "bot-1",
    text: String = "hello",
    token: String? = "ctx-1"
) -> IlinkRawInbound {
    IlinkRawInbound(
        fromUserID: from,
        toUserID: to,
        clientID: nil,
        messageID: IlinkMessageID(id),
        sequence: 7,
        items: [.text(text)],
        contextToken: token,
        createdAt: nil
    )
}

/// Direction, the bot's own echo copies, a missing identity, and the bounded
/// window of seen IDs.
func checkIlinkInboundFilter() throws {
    var filter = IlinkInboundFilter(botIDs: ["bot-1"], capacity: 2)
    let first = filter.accept(inbound("7527228441904002056"), receivedAt: Date(timeIntervalSince1970: 0))
    guard let message = first else {
        throw CheckFailure(message: "the first copy of a message is accepted")
    }
    try expectEqual(message.id.raw, "7527228441904002056", "a uint64 message id keeps every digit")
    try expectEqual(message.text, "hello", "the text item is read")
    try expectEqual(message.peer.id, "peer-1", "the peer is the sender")
    try expectEqual(message.contextToken, "ctx-1", "the context token travels with the message")

    try expect(
        filter.accept(inbound("7527228441904002056"), receivedAt: Date()) == nil,
        "the same stable id is not delivered twice"
    )
    try expect(
        filter.accept(inbound("2", from: "bot-1", to: "peer-1"), receivedAt: Date()) == nil,
        "the bot's own echo copy is dropped"
    )
    try expect(
        filter.accept(inbound("3", to: "bot-2"), receivedAt: Date()) == nil,
        "a message addressed to another bot is dropped"
    )
    try expect(
        filter.accept(inbound(""), receivedAt: Date()) == nil,
        "a message without a stable identity is dropped"
    )

    var capacity = IlinkInboundFilter(botIDs: ["bot-1"], capacity: 2)
    _ = capacity.accept(inbound("11"), receivedAt: Date())
    _ = capacity.accept(inbound("12"), receivedAt: Date())
    _ = capacity.accept(inbound("13"), receivedAt: Date())
    try expect(
        capacity.accept(inbound("11"), receivedAt: Date()) != nil,
        "an id that left the bounded window is delivered again"
    )
    try expect(
        capacity.accept(inbound("13"), receivedAt: Date()) == nil,
        "an id still in the window is not"
    )

    var media = IlinkInboundFilter(botIDs: ["bot-1"])
    let picture = IlinkRawInbound(
        fromUserID: "peer-1",
        toUserID: "bot-1",
        clientID: "client-1",
        messageID: IlinkMessageID("21"),
        sequence: nil,
        items: [.media(.image), .unknown(type: 42)],
        contextToken: nil,
        createdAt: nil
    )
    guard let accepted = media.accept(picture, receivedAt: Date()) else {
        throw CheckFailure(message: "a media-only message is still a message")
    }
    try expect(accepted.text == nil, "a media-only message has no text")
    try expectEqual(accepted.items.count, 2, "its items are kept by kind")
    try expectEqual(accepted.clientID, "client-1", "its client id is kept")
}
