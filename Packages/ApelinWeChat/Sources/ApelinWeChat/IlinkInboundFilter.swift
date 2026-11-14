import Foundation

/// Decides which inbound messages reach the caller.
///
/// A message is let through only when it is addressed to this bot, was not
/// written by a bot, carries a stable identity, and that identity was not seen
/// before. The server also echoes the bot's own sends back down the stream;
/// those are dropped here, so a reply can never answer itself.
public struct IlinkInboundFilter: Sendable {
    public let capacity: Int
    public private(set) var botIDs: Set<String>
    private var order: [IlinkMessageID]
    private var seen: Set<IlinkMessageID>

    public init(botIDs: Set<String> = [], capacity: Int = 2048) {
        self.capacity = max(1, capacity)
        self.botIDs = botIDs
        self.order = []
        self.seen = []
    }

    /// The bot identity is only known after login or after the session file is
    /// read.
    public mutating func updateBotIDs(_ ids: Set<String>) {
        botIDs = ids
    }

    public mutating func accept(_ raw: IlinkRawInbound, receivedAt: Date) -> IlinkInboundMessage? {
        guard !raw.messageID.raw.isEmpty else { return nil }
        // An upstream copy of our own message is not a new message.
        if botIDs.contains(raw.fromUserID) { return nil }
        // Not addressed to this bot, or the bot is not known yet.
        guard !botIDs.isEmpty, botIDs.contains(raw.toUserID) else { return nil }
        if seen.contains(raw.messageID) { return nil }
        remember(raw.messageID)

        var texts: [String] = []
        for item in raw.items {
            if case .text(let text) = item, !text.isEmpty {
                texts.append(text)
            }
        }
        let sender: IlinkSender = botIDs.contains(raw.fromUserID)
            ? .bot(id: raw.fromUserID)
            : .user(id: raw.fromUserID)
        return IlinkInboundMessage(
            id: raw.messageID,
            peer: IlinkPeer(id: raw.fromUserID),
            sender: sender,
            items: raw.items,
            text: texts.isEmpty ? nil : texts.joined(separator: "\n"),
            contextToken: raw.contextToken,
            sequence: raw.sequence,
            clientID: raw.clientID,
            receivedAt: receivedAt
        )
    }

    private mutating func remember(_ id: IlinkMessageID) {
        order.append(id)
        seen.insert(id)
        while order.count > capacity {
            let oldest = order.removeFirst()
            seen.remove(oldest)
        }
    }
}
