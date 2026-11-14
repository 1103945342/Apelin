import Foundation

// WeChat's ClawBot channel — the iLink bot API the official
// `@tencent-weixin/openclaw-weixin` plugin speaks (2026-11). JSON over HTTPS;
// the bytes fields are base64 strings and the 64-bit ids are numbers that do
// not fit a Double, so `message_id` is read as text where it matters.
//
// Nothing here is Apelin's protocol: this is the far side of the wire, and
// what Apelin does with a message lives in the session host
// (`Apelind/Session/Channel/`). No token is ever put in an error or a log.

/// One QR code to scan, as `ilink/bot/get_bot_qrcode` answers it.
public struct IlinkQRCode: Codable, Sendable, Equatable {
    /// The token the status poll takes.
    public var qrcode: String
    /// The URL to draw as a QR code: what WeChat reads when the reader scans.
    public var content: String

    public init(qrcode: String, content: String) {
        self.qrcode = qrcode
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case qrcode
        case content = "qrcode_img_content"
    }
}

/// What scanning the code has done so far.
public enum IlinkLoginStatus: String, Codable, Sendable {
    case wait
    case scaned
    case confirmed
    case expired
    /// The code was scanned, and the account's data centre is another host:
    /// poll `redirectHost` from then on.
    case scanedButRedirect = "scaned_but_redirect"
    /// WeChat shows a number on the phone; send it back with the next poll.
    case needVerifyCode = "need_verifycode"
    /// Too many wrong numbers; a new code is needed.
    case verifyCodeBlocked = "verify_code_blocked"
    /// This bot is already signed in: no credential is issued again.
    case bindedRedirect = "binded_redirect"
}

/// The answer of one status poll. `botToken`, `botID` and `userID` come with
/// `confirmed` alone.
public struct IlinkLoginPoll: Codable, Sendable, Equatable {
    public var status: IlinkLoginStatus
    public var botToken: String?
    public var botID: String?
    public var userID: String?
    /// The host to talk to after signing in (`baseurl`).
    public var baseURL: String?
    /// The host to poll when `status` is `scanedButRedirect`.
    public var redirectHost: String?

    public init(
        status: IlinkLoginStatus,
        botToken: String? = nil,
        botID: String? = nil,
        userID: String? = nil,
        baseURL: String? = nil,
        redirectHost: String? = nil
    ) {
        self.status = status
        self.botToken = botToken
        self.botID = botID
        self.userID = userID
        self.baseURL = baseURL
        self.redirectHost = redirectHost
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case botToken = "bot_token"
        case botID = "ilink_bot_id"
        case userID = "ilink_user_id"
        case baseURL = "baseurl"
        case redirectHost = "redirect_host"
    }
}

/// Who a message is from, from iLink's point of view.
public enum IlinkMessageType: Int, Codable, Sendable {
    case none = 0
    /// A message the reader's phone sent — the one an assistant answers.
    case user = 1
    /// A message a bot sent, this one included: never answered.
    case bot = 2
}

/// One part of a message. The channel answers text only; every other part is
/// read so it is not mistaken for one, and dropped.
public enum IlinkItemType: Int, Codable, Sendable {
    case none = 0
    case text = 1
    case image = 2
    case voice = 3
    case file = 4
    case video = 5
    case toolCallStart = 11
    case toolCallResult = 12
}

/// A media reference on the CDN: the parameter the download takes, and the
/// key its ciphertext was encrypted with (base64 over the wire).
public struct IlinkCDNMedia: Codable, Sendable, Equatable {
    public var encryptQueryParam: String?
    public var aesKey: String?
    /// 0 encrypts the file id alone, 1 packages the thumbnail and the
    /// middle image too.
    public var encryptType: Int?
    /// The whole download URL, when the server sent one.
    public var fullURL: String?

    public init(encryptQueryParam: String? = nil, aesKey: String? = nil, encryptType: Int? = nil, fullURL: String? = nil) {
        self.encryptQueryParam = encryptQueryParam
        self.aesKey = aesKey
        self.encryptType = encryptType
        self.fullURL = fullURL
    }

    private enum CodingKeys: String, CodingKey {
        case encryptQueryParam = "encrypt_query_param"
        case aesKey = "aes_key"
        case encryptType = "encrypt_type"
        case fullURL = "full_url"
    }
}

public struct IlinkImageItem: Codable, Sendable, Equatable {
    public var media: IlinkCDNMedia?
    public var thumbMedia: IlinkCDNMedia?
    /// The raw AES key as 32 hex characters, which inbound images carry.
    public var aesKey: String?
    public var url: String?
    public var middleSize: Int?
    public var thumbSize: Int?

    public init(media: IlinkCDNMedia? = nil, thumbMedia: IlinkCDNMedia? = nil, aesKey: String? = nil, url: String? = nil, middleSize: Int? = nil, thumbSize: Int? = nil) {
        self.media = media
        self.thumbMedia = thumbMedia
        self.aesKey = aesKey
        self.url = url
        self.middleSize = middleSize
        self.thumbSize = thumbSize
    }

    private enum CodingKeys: String, CodingKey {
        case media
        case thumbMedia = "thumb_media"
        case aesKey = "aeskey"
        case url
        case middleSize = "mid_size"
        case thumbSize = "thumb_size"
    }
}

public struct IlinkFileItem: Codable, Sendable, Equatable {
    public var media: IlinkCDNMedia?
    public var fileName: String?
    public var md5: String?
    /// The plaintext size, as a string.
    public var length: String?

    public init(media: IlinkCDNMedia? = nil, fileName: String? = nil, md5: String? = nil, length: String? = nil) {
        self.media = media
        self.fileName = fileName
        self.md5 = md5
        self.length = length
    }

    private enum CodingKeys: String, CodingKey {
        case media
        case fileName = "file_name"
        case md5
        case length = "len"
    }
}

public struct IlinkVideoItem: Codable, Sendable, Equatable {
    public var media: IlinkCDNMedia?
    public var videoSize: Int?
    public var playLength: Int?

    public init(media: IlinkCDNMedia? = nil, videoSize: Int? = nil, playLength: Int? = nil) {
        self.media = media
        self.videoSize = videoSize
        self.playLength = playLength
    }

    private enum CodingKeys: String, CodingKey {
        case media
        case videoSize = "video_size"
        case playLength = "play_length"
    }
}

public struct IlinkMessageItem: Codable, Sendable, Equatable {
    public var type: IlinkItemType?
    public var text: String?
    /// Read for a voice message: what WeChat transcribed it to, when it did.
    public var voiceText: String?
    public var image: IlinkImageItem?
    public var file: IlinkFileItem?
    public var video: IlinkVideoItem?

    public init(
        type: IlinkItemType? = nil,
        text: String? = nil,
        voiceText: String? = nil,
        image: IlinkImageItem? = nil,
        file: IlinkFileItem? = nil,
        video: IlinkVideoItem? = nil
    ) {
        self.type = type
        self.text = text
        self.voiceText = voiceText
        self.image = image
        self.file = file
        self.video = video
    }

    private struct TextItem: Codable, Sendable, Equatable {
        var text: String?
    }

    private struct VoiceItem: Codable, Sendable, Equatable {
        var text: String?
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case textItem = "text_item"
        case voiceItem = "voice_item"
        case imageItem = "image_item"
        case fileItem = "file_item"
        case videoItem = "video_item"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(IlinkItemType.self, forKey: .type)
        text = try container.decodeIfPresent(TextItem.self, forKey: .textItem)?.text
        voiceText = try container.decodeIfPresent(VoiceItem.self, forKey: .voiceItem)?.text
        image = try container.decodeIfPresent(IlinkImageItem.self, forKey: .imageItem)
        file = try container.decodeIfPresent(IlinkFileItem.self, forKey: .fileItem)
        video = try container.decodeIfPresent(IlinkVideoItem.self, forKey: .videoItem)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        if let text {
            try container.encode(TextItem(text: text), forKey: .textItem)
        }
        if let voiceText {
            try container.encode(VoiceItem(text: voiceText), forKey: .voiceItem)
        }
        try container.encodeIfPresent(image, forKey: .imageItem)
        try container.encodeIfPresent(file, forKey: .fileItem)
        try container.encodeIfPresent(video, forKey: .videoItem)
    }

    /// The media a message carries, when it carries one of the three the
    /// channel can take down from the CDN.
    public var media: IlinkCDNMedia? {
        switch type {
        case .image?: image?.media
        case .file?: file?.media
        case .video?: video?.media
        default: nil
        }
    }

    /// The key that decrypts `media`: for an image the item's own `aeskey`
    /// (32 hex characters) takes precedence over the media's field.
    public var mediaKey: String? {
        if type == .image, let aesKey = image?.aesKey, !aesKey.isEmpty {
            return aesKey
        }
        return media?.aesKey
    }
}

/// How far a message has got. A reply is sent whole (`finish`); the other
/// two are what a streaming bot would send.
public enum IlinkMessageState: Int, Codable, Sendable {
    case new = 0
    case generating = 1
    case finish = 2
}

/// One message, as `getupdates` delivers it and `sendmessage` takes it.
public struct IlinkMessage: Codable, Sendable, Equatable {
    public var messageID: String?
    public var fromUserID: String?
    public var toUserID: String?
    public var clientID: String?
    public var messageType: IlinkMessageType?
    public var messageState: IlinkMessageState?
    public var items: [IlinkMessageItem]
    /// The token that keeps a conversation's replies in its thread.
    public var contextToken: String?
    public var sessionID: String?
    public var groupID: String?

    public init(
        messageID: String? = nil,
        fromUserID: String? = nil,
        toUserID: String? = nil,
        clientID: String? = nil,
        messageType: IlinkMessageType? = nil,
        messageState: IlinkMessageState? = nil,
        items: [IlinkMessageItem] = [],
        contextToken: String? = nil,
        sessionID: String? = nil,
        groupID: String? = nil
    ) {
        self.messageID = messageID
        self.fromUserID = fromUserID
        self.toUserID = toUserID
        self.clientID = clientID
        self.messageType = messageType
        self.messageState = messageState
        self.items = items
        self.contextToken = contextToken
        self.sessionID = sessionID
        self.groupID = groupID
    }

    /// What to hand a conversation: the text parts joined, or a voice
    /// message's transcription. Nil when the message holds neither.
    public var readableText: String? {
        var parts: [String] = []
        for item in items {
            switch item.type {
            case .text?:
                if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(text)
                }
            case .voice?:
                if let text = item.voiceText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(text)
                }
            default:
                break
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case fromUserID = "from_user_id"
        case toUserID = "to_user_id"
        case clientID = "client_id"
        case messageType = "message_type"
        case messageState = "message_state"
        case items = "item_list"
        case contextToken = "context_token"
        case sessionID = "session_id"
        case groupID = "group_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A 64-bit id arrives as a JSON number; read it whole or not at all.
        if let number = try? container.decode(UInt64.self, forKey: .messageID) {
            messageID = String(number)
        } else {
            messageID = try? container.decodeIfPresent(String.self, forKey: .messageID)
        }
        fromUserID = try container.decodeIfPresent(String.self, forKey: .fromUserID)
        toUserID = try container.decodeIfPresent(String.self, forKey: .toUserID)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        messageType = try container.decodeIfPresent(IlinkMessageType.self, forKey: .messageType)
        messageState = try container.decodeIfPresent(IlinkMessageState.self, forKey: .messageState)
        items = try container.decodeIfPresent([IlinkMessageItem].self, forKey: .items) ?? []
        contextToken = try container.decodeIfPresent(String.self, forKey: .contextToken)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(messageID, forKey: .messageID)
        try container.encodeIfPresent(fromUserID, forKey: .fromUserID)
        try container.encodeIfPresent(toUserID, forKey: .toUserID)
        try container.encodeIfPresent(clientID, forKey: .clientID)
        try container.encodeIfPresent(messageType, forKey: .messageType)
        try container.encodeIfPresent(messageState, forKey: .messageState)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(contextToken, forKey: .contextToken)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(groupID, forKey: .groupID)
    }
}

/// One long poll's answer: the messages that arrived, and the buffer to send
/// next time so nothing is read twice.
public struct IlinkUpdates: Codable, Sendable, Equatable {
    public var ret: Int?
    public var errorCode: Int?
    public var errorMessage: String?
    public var messages: [IlinkMessage]
    public var buffer: String?
    /// How long the server is willing to hold the next poll.
    public var longPollingTimeoutMilliseconds: Int?

    public init(
        ret: Int? = nil,
        errorCode: Int? = nil,
        errorMessage: String? = nil,
        messages: [IlinkMessage] = [],
        buffer: String? = nil,
        longPollingTimeoutMilliseconds: Int? = nil
    ) {
        self.ret = ret
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.messages = messages
        self.buffer = buffer
        self.longPollingTimeoutMilliseconds = longPollingTimeoutMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case ret
        case errorCode = "errcode"
        case errorMessage = "errmsg"
        case messages = "msgs"
        case buffer = "get_updates_buf"
        case longPollingTimeoutMilliseconds = "longpolling_timeout_ms"
    }
}
