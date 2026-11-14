import Foundation

/// A conversation on the other side: the `from_user_id` of the messages it
/// sent us, and the `to_user_id` of ours.
public struct IlinkPeer: Sendable, Hashable, Codable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// Who wrote an inbound message.
public enum IlinkSender: Sendable, Equatable {
    case user(id: String)
    case bot(id: String?)
    case unknown
}

/// A message identity as the wire states it.
///
/// `message_id` is a bare uint64 JSON number such as 7527228441904002056, which
/// does not fit a `Double` and is not to be kept in an `Int64` on every path:
/// the raw text is kept, so two IDs compare equal only when the server said the
/// same number.
public struct IlinkMessageID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self.raw = text
            return
        }
        if let signed = try? container.decode(Int64.self) {
            self.raw = String(signed)
            return
        }
        if let unsigned = try? container.decode(UInt64.self) {
            self.raw = String(unsigned)
            return
        }
        if let decimal = try? container.decode(Decimal.self) {
            self.raw = NSDecimalNumber(decimal: decimal).stringValue
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "message_id is neither a number nor a string"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public var description: String { raw }
}

/// The item kinds an `item_list` can carry. 11 and 12 are the tool-call pair;
/// they are recognised and kept, not acted on.
public enum IlinkItemType: Sendable, Equatable {
    case text
    case image
    case voice
    case file
    case video
    case toolCall
    case toolResult
    case unknown(Int)

    public init(rawType: Int) {
        switch rawType {
        case 1: self = .text
        case 2: self = .image
        case 3: self = .voice
        case 4: self = .file
        case 5: self = .video
        case 11: self = .toolCall
        case 12: self = .toolResult
        default: self = .unknown(rawType)
        }
    }

    public var rawValue: Int {
        switch self {
        case .text: return 1
        case .image: return 2
        case .voice: return 3
        case .file: return 4
        case .video: return 5
        case .toolCall: return 11
        case .toolResult: return 12
        case .unknown(let value): return value
        }
    }
}

/// The media kinds M1 keeps but does not fetch or send.
public enum IlinkMediaKind: Sendable, Equatable {
    case image
    case voice
    case file
    case video
}

/// One item of an inbound message. Only text is read in M1; the others are
/// reported by kind so a later version can add them without a new shape.
public enum IlinkInboundItem: Sendable, Equatable {
    case text(String)
    case media(IlinkMediaKind)
    case toolCall
    case toolResult
    case unknown(type: Int)
}

/// An inbound message as the filter judges it: direction, sender and the
/// stable identity are checked here, not in the client.
public struct IlinkRawInbound: Sendable, Equatable {
    public var fromUserID: String
    public var toUserID: String
    public var clientID: String?
    public var messageID: IlinkMessageID
    public var sequence: UInt64?
    public var items: [IlinkInboundItem]
    public var contextToken: String?
    public var createdAt: Date?

    public init(
        fromUserID: String,
        toUserID: String,
        clientID: String?,
        messageID: IlinkMessageID,
        sequence: UInt64?,
        items: [IlinkInboundItem],
        contextToken: String?,
        createdAt: Date?
    ) {
        self.fromUserID = fromUserID
        self.toUserID = toUserID
        self.clientID = clientID
        self.messageID = messageID
        self.sequence = sequence
        self.items = items
        self.contextToken = contextToken
        self.createdAt = createdAt
    }
}

/// A message the filter let through.
public struct IlinkInboundMessage: Sendable, Identifiable, Equatable {
    public let id: IlinkMessageID
    /// The other side: where a reply goes.
    public let peer: IlinkPeer
    public let sender: IlinkSender
    public let items: [IlinkInboundItem]
    /// The text items joined with newlines, or nil when the message carries
    /// no text.
    public let text: String?
    /// The reply token this message brought, if any. The client also stores
    /// it per peer in the session file.
    public let contextToken: String?
    public let sequence: UInt64?
    public let clientID: String?
    public let receivedAt: Date
}

/// What a successful `send` answers. The server's receipt is a courtesy: a
/// reply that cannot be read still means the message went out.
public struct IlinkSendResult: Sendable, Equatable {
    /// The `client_id` this send carried, which the server echoes back.
    public let clientID: String
    public let messageID: IlinkMessageID?
    public let acceptedAt: Date

    public init(clientID: String, messageID: IlinkMessageID?, acceptedAt: Date) {
        self.clientID = clientID
        self.messageID = messageID
        self.acceptedAt = acceptedAt
    }
}

/// `sendtyping`'s `status`: 1 while the bot writes, 2 when it stops.
public enum IlinkTypingStatus: Int, Sendable, Equatable {
    case active = 1
    case idle = 2
}

/// A media item a later version sends. Defined now, not sent in M1.
public struct IlinkOutgoingMedia: Sendable, Equatable {
    public var kind: IlinkMediaKind
    public var url: URL

    public init(kind: IlinkMediaKind, url: URL) {
        self.kind = kind
        self.url = url
    }
}
