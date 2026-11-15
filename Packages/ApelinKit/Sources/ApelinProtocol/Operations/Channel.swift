import ApelinCore
import Foundation

// The chat channels Apelin can be reached through: Settings ▸ Plugins signs
// one in, and its messages run as conversations of a project the reader picks.
//
// One channel for now — WeChat, through the ClawBot plugin's iLink bot API
// (`ApelinCore/Ilink`). The session host owns it (`Apelind/Session/Channel`):
// the sign-in, the long poll, and the conversation each WeChat peer talks in.
// The app only reads its state and gives it instructions; no token is ever
// part of a request or a reply.
//
// What a peer's message becomes: a user message in a conversation of the
// chosen project (a temporary chat when none is chosen), run like any other
// turn; the reply is what that turn wrote. Approvals are never given from
// WeChat — a turn that needs one waits for the app, and says so.

public enum ChannelKind: String, Codable, Sendable, CaseIterable {
    /// WeChat's ClawBot plugin, text in and out.
    case weChatClawBot
}

/// The names a channel writes into the protocol: `AgentOpenRequest.origin`
/// for the conversation it opens, and `AgentPromptRequest.source` for each
/// message it sends there. One spelling, read by the host, the worker and the
/// app alike.
public enum ChatChannel: Sendable {
    public static let weChat = "wechat"
}

/// Where a channel is in its life.
public enum ChannelPhase: String, Codable, Sendable {
    /// Turned off, or signed out: nothing is read and nothing is sent.
    case off
    /// Asking WeChat for a code to scan.
    case starting
    /// A code is on screen, waiting for the reader's phone.
    case waitingForScan
    /// The phone scanned the code.
    case scanned
    /// WeChat showed a number on the phone and wants it typed in.
    case needsCode
    /// Signed in: messages are read and answered.
    case signedIn
    /// The last attempt failed; `ChannelState.message` says what happened.
    case failed
}

/// A channel as the app sees it: what it is doing and what it is waiting for.
public struct ChannelState: Codable, Sendable, Equatable {
    public var kind: ChannelKind
    public var phase: ChannelPhase
    /// Whether the reader wants this channel on. Off stops the reading and
    /// the answering, and keeps the sign-in.
    public var enabled: Bool
    /// The string to draw as a QR code while signing in.
    public var qrContent: String?
    /// The bot it is signed in as (`ilink_bot_id`), shown on the page.
    public var account: String?
    /// `Projects/<name>` the conversations live in; nil for a temporary chat.
    public var projectName: String?
    /// What the conversations run under: an approval that is needed is
    /// answered in Apelin, never in WeChat.
    public var approvalMode: ApprovalMode
    /// Why the phase is what it is, in words the page can show. Nil when
    /// there is nothing to say.
    public var message: String?
    /// Whether messages are being read right now.
    public var listening: Bool
    public var signedInAt: Date?
    /// The last message a peer sent, for the page's one line of recent use.
    public var lastMessageAt: Date?

    public init(
        kind: ChannelKind = .weChatClawBot,
        phase: ChannelPhase = .off,
        enabled: Bool = false,
        qrContent: String? = nil,
        account: String? = nil,
        projectName: String? = nil,
        approvalMode: ApprovalMode = .confirm,
        message: String? = nil,
        listening: Bool = false,
        signedInAt: Date? = nil,
        lastMessageAt: Date? = nil
    ) {
        self.kind = kind
        self.phase = phase
        self.enabled = enabled
        self.qrContent = qrContent
        self.account = account
        self.projectName = projectName
        self.approvalMode = approvalMode
        self.message = message
        self.listening = listening
        self.signedInAt = signedInAt
        self.lastMessageAt = lastMessageAt
    }
}

/// Reads the channel: its phase, the code to scan when it is waiting for
/// one, and how it is configured. The page polls this while it is showing.
public struct ChannelStatusRequest: OperationRequest {
    public typealias Response = ChannelState
    public static let operation = AppOperation.channelStatus
    public init() {}
}

/// Starts (or restarts) the sign-in: a code to scan, and the poll behind it.
/// Turning the channel on is part of it.
public struct ChannelSignInRequest: OperationRequest {
    public typealias Response = ChannelState
    public static let operation = AppOperation.channelSignIn
    public init() {}
}

/// The number WeChat showed on the phone, typed in while signing in.
public struct ChannelVerifyCodeRequest: OperationRequest {
    public typealias Response = ChannelState
    public static let operation = AppOperation.channelVerifyCode
    public var code: String
    public init(code: String) {
        self.code = code
    }
}

/// Changes how the channel behaves. A field that is nil stays as it is;
/// `clearsProject` puts the conversations back in a temporary chat.
public struct ChannelConfigureRequest: OperationRequest {
    public typealias Response = ChannelState
    public static let operation = AppOperation.channelConfigure
    public var enabled: Bool?
    public var projectName: String?
    public var approvalMode: ApprovalMode?
    public var clearsProject: Bool?

    public init(
        enabled: Bool? = nil,
        projectName: String? = nil,
        approvalMode: ApprovalMode? = nil,
        clearsProject: Bool? = nil
    ) {
        self.enabled = enabled
        self.projectName = projectName
        self.approvalMode = approvalMode
        self.clearsProject = clearsProject
    }
}

/// Signs out: tells WeChat this client is stopping, and forgets the
/// credential. The conversations it made stay.
public struct ChannelSignOutRequest: OperationRequest {
    public typealias Response = ChannelState
    public static let operation = AppOperation.channelSignOut
    public init() {}
}

public extension ApelinService {
    func channelStatus() async throws -> ChannelState {
        try await send(ChannelStatusRequest())
    }

    /// Starts the sign-in; the page then polls `channelStatus()` for the
    /// code's state.
    func channelSignIn() async throws -> ChannelState {
        try await send(ChannelSignInRequest())
    }

    func channelVerifyCode(_ code: String) async throws -> ChannelState {
        try await send(ChannelVerifyCodeRequest(code: code))
    }

    @discardableResult
    func channelConfigure(
        enabled: Bool? = nil,
        projectName: String? = nil,
        approvalMode: ApprovalMode? = nil,
        clearsProject: Bool? = nil
    ) async throws -> ChannelState {
        try await send(ChannelConfigureRequest(
            enabled: enabled,
            projectName: projectName,
            approvalMode: approvalMode,
            clearsProject: clearsProject
        ))
    }

    func channelSignOut() async throws -> ChannelState {
        try await send(ChannelSignOutRequest())
    }
}
