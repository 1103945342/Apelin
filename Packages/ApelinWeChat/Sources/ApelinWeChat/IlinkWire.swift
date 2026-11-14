import Foundation

/// The paths of the protocol. The base is `IlinkConfiguration.apiBaseURL`.
enum IlinkEndpoint {
    static let qrCode = "/ilink/bot/get_bot_qrcode"
    static let qrCodeStatus = "/ilink/bot/get_qrcode_status"
    static let updates = "/ilink/bot/getupdates"
    static let sendMessage = "/ilink/bot/sendmessage"
    static let sendTyping = "/ilink/bot/sendtyping"
}

/// The headers every request carries, and the one that changes per request.
enum IlinkHeaders {
    static func base(_ configuration: IlinkConfiguration, uinOverride: String? = nil) -> [String: String] {
        return [
            "AuthorizationType": "ilink_bot_token",
            "iLink-App-Id": configuration.appID,
            "iLink-App-ClientVersion": String(configuration.clientVersion),
            "X-WECHAT-UIN": uinOverride ?? uin(),
            "Content-Type": "application/json",
        ]
    }

    /// base64 of a random uint32 written in decimal, a fresh one per request.
    static func uin(_ value: UInt32 = .random(in: 0...UInt32.max)) -> String {
        Data(String(value).utf8).base64EncodedString()
    }
}

/// `base_info` — every POST except `get_bot_qrcode` carries it, and the server
/// refuses a body without it.
struct IlinkBaseInfo: Encodable, Equatable {
    let channelVersion: String
    let botAgent: String

    enum CodingKeys: String, CodingKey {
        case channelVersion = "channel_version"
        case botAgent = "bot_agent"
    }

    init(_ configuration: IlinkConfiguration) {
        self.channelVersion = configuration.channelVersion
        self.botAgent = configuration.agent
    }
}

// MARK: - get_bot_qrcode

struct IlinkQRCodeRequest: Encodable {
    let localTokenList: [String]

    enum CodingKeys: String, CodingKey {
        case localTokenList = "local_token_list"
    }
}

struct IlinkQRCodeReply: Decodable {
    let ret: Int?
    let qrcode: String?
    let qrcodeImgContent: String?

    enum CodingKeys: String, CodingKey {
        case ret
        case qrcode
        case qrcodeImgContent = "qrcode_img_content"
    }
}

// MARK: - get_qrcode_status

struct IlinkQRCodeStatusReply: Decodable {
    let status: String?
    let botToken: String?
    let ilinkBotID: String?
    let baseurl: String?
    let ilinkUserID: String?
    let redirectHost: String?

    enum CodingKeys: String, CodingKey {
        case status
        case botToken = "bot_token"
        case ilinkBotID = "ilink_bot_id"
        case baseurl
        case ilinkUserID = "ilink_user_id"
        case redirectHost = "redirect_host"
    }
}

// MARK: - getupdates

struct IlinkGetUpdatesRequest: Encodable {
    let getUpdatesBuf: String
    let baseInfo: IlinkBaseInfo

    enum CodingKeys: String, CodingKey {
        case getUpdatesBuf = "get_updates_buf"
        case baseInfo = "base_info"
    }
}

struct IlinkGetUpdatesReply: Decodable {
    let ret: Int?
    let errcode: Int?
    let errmsg: String?
    let msgs: [IlinkWireMessage]?
    let getUpdatesBuf: String?
    let longpollingTimeoutMs: Int?

    enum CodingKeys: String, CodingKey {
        case ret
        case errcode
        case errmsg
        case msgs
        case getUpdatesBuf = "get_updates_buf"
        case longpollingTimeoutMs = "longpolling_timeout_ms"
    }
}

/// A number the wire may state as a JSON number or as a string, kept as text
/// so a uint64 never passes through a double.
struct IlinkTextNumber: Decodable, Equatable {
    let raw: String

    init(raw: String) {
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
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
            debugDescription: "not a number"
        )
    }

    var uint64: UInt64? { UInt64(raw) }
}

struct IlinkWireTextItem: Decodable {
    let text: String?
}

struct IlinkWireItem: Decodable {
    let type: Int?
    let textItem: IlinkWireTextItem?

    enum CodingKeys: String, CodingKey {
        case type
        case textItem = "text_item"
    }
}

struct IlinkWireMessage: Decodable {
    let fromUserID: String?
    let toUserID: String?
    let clientID: String?
    let messageID: IlinkMessageID?
    let seq: IlinkTextNumber?
    let messageType: Int?
    let messageState: Int?
    let itemList: [IlinkWireItem]?
    let contextToken: String?
    let createTimeMs: IlinkTextNumber?

    enum CodingKeys: String, CodingKey {
        case fromUserID = "from_user_id"
        case toUserID = "to_user_id"
        case clientID = "client_id"
        case messageID = "message_id"
        case seq
        case messageType = "message_type"
        case messageState = "message_state"
        case itemList = "item_list"
        case contextToken = "context_token"
        case createTimeMs = "create_time_ms"
    }

    /// The inbound view of this message, or nil when it names no sender, no
    /// recipient or no stable identity.
    var rawInbound: IlinkRawInbound? {
        guard let from = fromUserID, !from.isEmpty,
              let to = toUserID, !to.isEmpty,
              let id = messageID, !id.raw.isEmpty
        else {
            return nil
        }
        var items: [IlinkInboundItem] = []
        for item in itemList ?? [] {
            let type = IlinkItemType(rawType: item.type ?? -1)
            switch type {
            case .text:
                items.append(.text(item.textItem?.text ?? ""))
            case .image:
                items.append(.media(.image))
            case .voice:
                items.append(.media(.voice))
            case .file:
                items.append(.media(.file))
            case .video:
                items.append(.media(.video))
            case .toolCall:
                items.append(.toolCall)
            case .toolResult:
                items.append(.toolResult)
            case .unknown(let raw):
                items.append(.unknown(type: raw))
            }
        }
        var createdAt: Date?
        if let milliseconds = createTimeMs.flatMap({ Double($0.raw) }), milliseconds > 0 {
            createdAt = Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return IlinkRawInbound(
            fromUserID: from,
            toUserID: to,
            clientID: clientID,
            messageID: id,
            sequence: seq?.uint64,
            items: items,
            contextToken: contextToken,
            createdAt: createdAt
        )
    }
}

// MARK: - sendmessage

struct IlinkWireOutgoingText: Encodable {
    let text: String
}

struct IlinkWireOutgoingItem: Encodable {
    let type: Int
    let textItem: IlinkWireOutgoingText?

    enum CodingKeys: String, CodingKey {
        case type
        case textItem = "text_item"
    }
}

struct IlinkWireOutgoingMessage: Encodable {
    let fromUserID: String
    let toUserID: String
    let clientID: String
    let messageType: Int
    let messageState: Int
    let itemList: [IlinkWireOutgoingItem]
    let contextToken: String?

    enum CodingKeys: String, CodingKey {
        case fromUserID = "from_user_id"
        case toUserID = "to_user_id"
        case clientID = "client_id"
        case messageType = "message_type"
        case messageState = "message_state"
        case itemList = "item_list"
        case contextToken = "context_token"
    }
}

struct IlinkSendMessageRequest: Encodable {
    let msg: IlinkWireOutgoingMessage
    let baseInfo: IlinkBaseInfo

    enum CodingKeys: String, CodingKey {
        case msg
        case baseInfo = "base_info"
    }
}

/// The receipt is read when it parses; a reply that does not is not a failed
/// send, since only an HTTP status decides that.
struct IlinkSendReceipt: Decodable {
    let ret: Int?
    let errcode: Int?
    let errmsg: String?
    let messageID: IlinkMessageID?

    enum CodingKeys: String, CodingKey {
        case ret
        case errcode
        case errmsg
        case messageID = "message_id"
    }
}

// MARK: - sendtyping

struct IlinkSendTypingRequest: Encodable {
    let ilinkUserID: String
    let contextToken: String?
    let status: Int
    let baseInfo: IlinkBaseInfo

    enum CodingKeys: String, CodingKey {
        case ilinkUserID = "ilink_user_id"
        case contextToken = "context_token"
        case status
        case baseInfo = "base_info"
    }
}

// MARK: - decoding

enum IlinkWire {
    /// A `getupdates` reply.
    ///
    /// The whole body is decoded first. When that fails, the body is read as
    /// JSON again and each `msgs[]` element is decoded on its own: one message
    /// this version cannot read does not cost the others, and the rest of the
    /// reply (`ret`, the cursor) is still read.
    static func decodeUpdates(_ data: Data) throws -> IlinkGetUpdatesReply {
        do {
            return try JSONDecoder().decode(IlinkGetUpdatesReply.self, from: data)
        } catch {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IlinkFailure.invalidResponse("getupdates")
            }
            var messages: [IlinkWireMessage] = []
            if let elements = object["msgs"] as? [Any] {
                for element in elements {
                    guard let bytes = try? JSONSerialization.data(withJSONObject: element) else { continue }
                    guard let message = try? JSONDecoder().decode(IlinkWireMessage.self, from: bytes) else { continue }
                    messages.append(message)
                }
            }
            return IlinkGetUpdatesReply(
                ret: integer(object["ret"]),
                errcode: integer(object["errcode"]),
                errmsg: object["errmsg"] as? String,
                msgs: messages,
                getUpdatesBuf: object["get_updates_buf"] as? String,
                longpollingTimeoutMs: integer(object["longpolling_timeout_ms"])
            )
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}
