import Foundation

/// What a media message is: the number the upload ticket takes.
public enum IlinkMediaType: Int, Sendable {
    case image = 1
    case video = 2
    case file = 3
    case voice = 4

    /// The type a file's name makes it, for a reply that sends one.
    ///
    /// Only what WeChat's own client produces goes down the image and video
    /// channels: its CDN answers 500 to anything else (a bmp measured, and
    /// heic among them), so those bytes are sent as a file, which the phone
    /// still receives and can open.
    public static func of(name: String) -> IlinkMediaType {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp":
            .image
        case "mp4", "mov", "m4v":
            .video
        default:
            .file
        }
    }
}

/// An upload that went through: what a message must carry to be downloadable.
public struct IlinkUpload: Sendable {
    /// The `encrypted_query_param` the CDN answered with.
    public var downloadParam: String
    /// The key the ciphertext was encrypted with, as the 32 hex characters
    /// the upload ticket named: the message's `aes_key` is base64 of these,
    /// never of the 16 bytes they spell.
    public var aesKeyHex: String
    public var rawSize: Int
    public var cipherSize: Int
    public var fileKey: String
}

public extension IlinkClient {
    /// Where the CDN lives; the API hands back whole URLs too, and one of
    /// those is used when it does.
    static let cdnBase = URL(string: "https://novac2c.cdn.weixin.qq.com/c2c")!

    /// Uploads `data` to WeChat's CDN so a message can point at it.
    ///
    /// Two calls, as the official plugin makes them: a ticket from iLink
    /// (`getuploadurl`, describing the plaintext and its ciphertext), then
    /// the AES-128-ECB ciphertext POSTed to the CDN, whose
    /// `x-encrypted-param` header is the download parameter.
    func upload(
        _ data: Data,
        name: String,
        to userID: String,
        mediaType: IlinkMediaType
    ) async throws -> IlinkUpload {
        struct Request: Encodable {
            var filekey: String
            var media_type: Int
            var to_user_id: String
            var rawsize: Int
            var rawfilemd5: String
            var filesize: Int
            var no_need_thumb: Bool
            var aeskey: String
            var base_info: BaseInfo
        }
        struct Answer: Decodable {
            var upload_param: String?
            var upload_full_url: String?
        }

        let rawSize = data.count
        let cipherSize = IlinkMedia.paddedSize(rawSize)
        let fileKey = IlinkMedia.randomHex(16)
        let aesKeyHex = IlinkMedia.randomHex(16)
        guard let key = IlinkMedia.key(fromHex: aesKeyHex) else {
            throw IlinkFailure.http(status: nil, message: "A key could not be made for the file")
        }
        var request = try makeRequest(path: "ilink/bot/getuploadurl")
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONCoding.encode(Request(
            filekey: fileKey,
            media_type: mediaType.rawValue,
            to_user_id: userID,
            rawsize: rawSize,
            rawfilemd5: IlinkMedia.md5Hex(data),
            filesize: cipherSize,
            no_need_thumb: true,
            aeskey: aesKeyHex,
            base_info: baseInfo()
        ))
        let answer = try await perform(request, as: Answer.self, label: "upload ticket")
        let uploadURL: URL
        if let whole = answer.upload_full_url, let url = URL(string: whole) {
            uploadURL = url
        } else if let param = answer.upload_param {
            var components = URLComponents(
                url: IlinkClient.cdnBase.appendingPathComponent("upload"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "encrypted_query_param", value: param),
                URLQueryItem(name: "filekey", value: fileKey)
            ]
            guard let url = components.url else {
                throw IlinkFailure.http(status: nil, message: "WeChat answered an upload address that could not be read")
            }
            uploadURL = url
        } else {
            throw IlinkFailure.http(status: nil, message: "WeChat answered an upload request with no address")
        }

        guard let cipher = IlinkMedia.crypt(data, key: key, encrypt: true) else {
            throw IlinkFailure.http(status: nil, message: "The file could not be encrypted for WeChat")
        }
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "POST"
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        put.httpBody = cipher
        put.timeoutInterval = 120
        let (_, response) = try await performRaw(put, label: "upload")
        guard let param = response?.value(forHTTPHeaderField: "x-encrypted-param"), !param.isEmpty else {
            throw IlinkFailure.http(status: response?.statusCode, message: "WeChat took the upload but named no download parameter")
        }
        return IlinkUpload(
            downloadParam: param,
            aesKeyHex: aesKeyHex,
            rawSize: rawSize,
            cipherSize: cipherSize,
            fileKey: fileKey
        )
    }

    /// One media reference taken back off the CDN and decrypted: the
    /// plaintext the phone sent.
    func download(_ media: IlinkCDNMedia, key: String?, limit: Int = 100 * 1024 * 1024) async throws -> Data {
        let url: URL
        if let whole = media.fullURL, let parsed = URL(string: whole) {
            url = parsed
        } else if let param = media.encryptQueryParam {
            var components = URLComponents(
                url: IlinkClient.cdnBase.appendingPathComponent("download"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "encrypted_query_param", value: param)]
            guard let parsed = components.url else {
                throw IlinkFailure.http(status: nil, message: "This message named no downloadable media")
            }
            url = parsed
        } else {
            throw IlinkFailure.http(status: nil, message: "This message named no downloadable media")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        let (cipher, _) = try await performRaw(request, label: "media download")
        guard cipher.count <= limit else {
            throw IlinkFailure.http(status: nil, message: "The media is larger than \(limit >> 20) MB")
        }
        guard let key, let raw = IlinkMedia.key(fromBase64: key) ?? IlinkMedia.key(fromHex: key) else {
            // A few uploads carry no key; the bytes are the plaintext then.
            return cipher
        }
        guard let plain = IlinkMedia.crypt(cipher, key: raw, encrypt: false) else {
            throw IlinkFailure.http(status: nil, message: "The media could not be decrypted")
        }
        return plain
    }

    /// Sends one uploaded image, file or video in `to`'s thread.
    @discardableResult
    func sendMedia(
        _ upload: IlinkUpload,
        name: String,
        mediaType: IlinkMediaType,
        to userID: String,
        contextToken: String?,
        clientID: String = UUID().uuidString.lowercased()
    ) async throws -> String? {
        let media = IlinkCDNMedia(
            encryptQueryParam: upload.downloadParam,
            aesKey: IlinkMedia.aesKeyField(forHex: upload.aesKeyHex),
            encryptType: 1
        )
        let item: IlinkMessageItem
        switch mediaType {
        case .image:
            item = IlinkMessageItem(type: .image, image: IlinkImageItem(media: media, middleSize: upload.cipherSize))
        case .video:
            item = IlinkMessageItem(type: .video, video: IlinkVideoItem(media: media, videoSize: upload.cipherSize))
        case .file, .voice:
            item = IlinkMessageItem(type: .file, file: IlinkFileItem(
                media: media,
                fileName: name,
                md5: nil,
                length: String(upload.rawSize)
            ))
        }
        struct Body: Encodable {
            var msg: IlinkMessage
            var base_info: BaseInfo
        }
        let message = IlinkMessage(
            fromUserID: "",
            toUserID: userID,
            clientID: clientID,
            messageType: .bot,
            messageState: .finish,
            items: [item],
            contextToken: contextToken
        )
        var request = try makeRequest(path: "ilink/bot/sendmessage")
        request.httpMethod = "POST"
        request.httpBody = try JSONCoding.encode(Body(msg: message, base_info: baseInfo()))
        let reply = try await perform(request, as: SentMessageReply.self, label: "media reply")
        // A refusal answers 200 with a ret: saying the file went when WeChat
        // said no would leave the phone waiting for a message it never sends.
        if let ret = reply.ret, ret != 0 {
            throw IlinkFailure.http(
                status: nil,
                message: "WeChat refused the \(name) message (ret \(ret)\(reply.errmsg.map { ": \($0)" } ?? ""))"
            )
        }
        return reply.messageID
    }
}

/// The fields every sendmessage answer is read for.
struct SentMessageReply: Decodable {
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
