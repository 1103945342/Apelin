import ApelinCore
import ApelinProtocol
import Foundation

/// What the channel worker needs from a platform, and nothing more. The iLink
/// implementation is `IlinkPlatform`, the only file that imports
/// `ApelinWeChat`; everything else here works against this protocol.
public protocol ChannelPlatform: Sendable {
    /// Restores the saved login when there is one, else starts one. Answers
    /// `confirmed` when the conversation can start now.
    func connect() async throws -> ChannelLoginPhase
    /// How the reader signs in (a code to scan, a URL to open, a line of
    /// text), as the app shows it.
    func loginPrompt() async throws -> ChannelLoginPrompt
    /// One poll of the sign-in. A prompt is present when the platform issued
    /// a new code (the first one expired), so the app can show it.
    func loginStatus(verifyCode: String?) async throws -> ChannelLoginUpdate
    func cancelLogin() async
    /// Messages from the platform. Ends when the connection does.
    func updates() async -> AsyncThrowingStream<ChannelUpdate, any Error>
    func send(_ text: String, to peer: String) async throws
    /// Forget the platform session on this device (`channelLogout`).
    func discardSession() async
    func close() async
}

public struct ChannelLoginUpdate: Sendable {
    public var phase: ChannelLoginPhase
    /// A replacement code, when the previous one expired.
    public var prompt: ChannelLoginPrompt?
    /// WeChat wants the number shown on the phone. `retry` means the previous
    /// one was refused.
    public var needsVerification: Bool
    public var verificationRetry: Bool

    public init(
        phase: ChannelLoginPhase,
        prompt: ChannelLoginPrompt? = nil,
        needsVerification: Bool = false,
        verificationRetry: Bool = false
    ) {
        self.phase = phase
        self.prompt = prompt
        self.needsVerification = needsVerification
        self.verificationRetry = verificationRetry
    }
}

public enum ChannelLoginPhase: String, Sendable, Equatable {
    case pending
    case scanned
    case redirect
    case pairing
    case confirmed
    case expired
    case failed
}

public enum ChannelLoginPrompt: Sendable, Equatable {
    case qrImage(base64: String, expiresAt: Date?)
    case qrURL(String, expiresAt: Date?)
    case text(String)

    /// What goes on the channel's task as a `channelLogin` event.
    public var payload: [String: JSONValue] {
        switch self {
        case let .qrImage(base64, expiresAt):
            var value: [String: JSONValue] = ["kind": .string("qrImage"), "value": .string(base64)]
            if let expiresAt {
                value["expiresAt"] = .string(ISO8601DateFormatter().string(from: expiresAt))
            }
            return value
        case let .qrURL(url, expiresAt):
            var value: [String: JSONValue] = ["kind": .string("qrURL"), "value": .string(url)]
            if let expiresAt {
                value["expiresAt"] = .string(ISO8601DateFormatter().string(from: expiresAt))
            }
            return value
        case let .text(text):
            return ["kind": .string("text"), "value": .string(text)]
        }
    }
}

public enum ChannelUpdate: Sendable {
    case inbound(peer: String, messageID: String, text: String)
}

struct ChannelFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

/// The platform found something only the user can settle — a session file
/// that does not read, a credential that will not be accepted — and retrying
/// would only repeat it. The worker says so on its task as `paused` and stops;
/// the host stands the channel down until the user starts it again.
struct ChannelStoodDown: Error {
    var code: ChannelErrorCode
    var message: String

    init(_ code: ChannelErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// The lines the channel says on its own, in the reader's language. Nothing
/// here is an approval: the app owns those, and this only says so.
enum ChannelText {
    private static var speaksChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }

    static var approvalWaiting: String {
        speaksChinese
            ? "这条消息需要你在 Apelin 里批准，微信里的回复不会算作批准。"
            : "This needs your approval in Apelin. A reply here is not an approval."
    }

    static var conversationGone: String {
        speaksChinese
            ? "这个通道的对话已经结束，请在 Apelin 里重新打开通道。"
            : "The conversation this channel used has ended. Start the channel again in Apelin."
    }

    static var channelDown: String {
        speaksChinese
            ? "通道暂时不可用，稍后会再试。"
            : "The channel is unavailable right now; it will try again shortly."
    }
}
