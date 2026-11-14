import Foundation

/// The channel that lets a chat platform drive one Apelin conversation.
///
/// The network lives in the mobile `apelin-channel` worker, never in apelind
/// or its session host: the app configures the channel, the host keeps it
/// alive and is the only thing that may speak for it to apelin-agent, and the
/// worker holds the login, the message loop and the token's one read. A
/// channel reaches exactly one conversation — the one it was bound to, or the
/// one the host opened for it — and nothing else on the wire.

public enum ChannelKind: String, Codable, Sendable, CaseIterable {
    /// WeChat through iLink, first version text only.
    case weChatClawBot
}

/// What the channel is doing now. `enabled` in `ChannelSummary` is the switch
/// that is on disk; this is what the worker last reported, and the two differ
/// on purpose — a channel can be enabled and not yet running.
public enum ChannelState: String, Codable, Sendable {
    case stopped
    case starting
    case awaitingLogin
    case online
    /// Stood down: the bound conversation is gone, or the saved configuration
    /// could not be read. Nothing is retried until the user starts it again.
    case paused
    case failed
}

public enum ChannelErrorCode: String, Codable, Sendable {
    case credentialMissing
    case emptyAllowlist
    case sessionGone
    case loginExpired
    case network
    case protocolUnsupported
    case configurationUnreadable
    /// The configured approval mode is not one a channel may open a
    /// conversation with (`full` never is).
    case unsupportedApprovalMode
}

public struct ChannelError: Codable, Sendable, Equatable {
    public var code: ChannelErrorCode
    /// One sentence for the user: never a token, a cookie or a device path.
    public var message: String

    public init(code: ChannelErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// Everything the app may know about a channel. Never carries the credential:
/// that is written once and answered only by `hasCredential`.
public struct ChannelSummary: Codable, Sendable, Equatable {
    public var id: String
    public var kind: ChannelKind
    /// The switch as it was saved.
    public var enabled: Bool
    /// Whether a worker process is live for it now.
    public var running: Bool
    public var state: ChannelState
    /// The project the host opens a conversation in; nil is General Chat.
    public var projectID: String?
    /// The conversation this channel drives; nil until the first message
    /// opened one.
    public var sessionID: String?
    /// Who may drive this channel, trimmed and de-duplicated. The app is the
    /// one that configured them; a token is never part of this.
    public var allowlist: [String]
    public var allowlistCount: Int {
        allowlist.count
    }
    public var approvalMode: ApprovalMode
    /// Whether the channel is signed in. No token reaches the app or the
    /// host: WeChat hands one to the worker when the reader scans the code,
    /// and it stays in the worker's own session file.
    public var hasCredential: Bool
    /// The channel task a reader attaches to for login codes and state.
    public var taskID: TaskID?
    public var lastError: ChannelError?
    public var updatedAt: Date?

    public init(
        id: String,
        kind: ChannelKind = .weChatClawBot,
        enabled: Bool = false,
        running: Bool = false,
        state: ChannelState = .stopped,
        projectID: String? = nil,
        sessionID: String? = nil,
        allowlist: [String] = [],
        approvalMode: ApprovalMode = .confirm,
        hasCredential: Bool = false,
        taskID: TaskID? = nil,
        lastError: ChannelError? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.running = running
        self.state = state
        self.projectID = projectID
        self.sessionID = sessionID
        self.allowlist = allowlist
        self.approvalMode = approvalMode
        self.hasCredential = hasCredential
        self.taskID = taskID
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

// MARK: - The app's calls

public struct ChannelListRequest: OperationRequest {
    public typealias Response = ChannelListResponse
    public static let operation = AppOperation.channelList
    /// One channel, or every one when nil.
    public var channelID: String?

    public init(channelID: String? = nil) {
        self.channelID = channelID
    }
}

public struct ChannelListResponse: Codable, Sendable, Equatable {
    public var channels: [ChannelSummary]

    public init(channels: [ChannelSummary] = []) {
        self.channels = channels
    }
}

/// How the channel's conversation is chosen. Spelled out because "leave it
/// alone" and "bind it to General Chat" are both a nil `projectID`.
public enum ChannelBindingChoice: Codable, Sendable, Equatable {
    case unchanged
    /// Forget the conversation; the next message opens a new one.
    case clear
    /// Open in this project, or in General Chat when nil.
    case project(String?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case projectID
    }

    private enum Kind: String, Codable {
        case unchanged
        case clear
        case project
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .unchanged:
            self = .unchanged
        case .clear:
            self = .clear
        case .project:
            self = .project(try container.decodeIfPresent(String.self, forKey: .projectID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unchanged:
            try container.encode(Kind.unchanged, forKey: .kind)
        case .clear:
            try container.encode(Kind.clear, forKey: .kind)
        case .project(let id):
            try container.encode(Kind.project, forKey: .kind)
            try container.encodeIfPresent(id, forKey: .projectID)
        }
    }
}

public struct ChannelConfigureRequest: OperationRequest {
    public typealias Response = ChannelSummary
    public static let operation = AppOperation.channelConfigure
    public var channelID: String
    /// A channel is created by naming it; nil keeps the kind it has.
    public var kind: ChannelKind?
    /// nil leaves the switch as it is. `true` on a channel with an empty
    /// allowlist, or with an approval mode a channel may not open with, is
    /// refused: the host fails closed rather than saving a channel that
    /// could act on nobody's behalf.
    public var enabled: Bool?
    public var binding: ChannelBindingChoice?
    /// The platform's peer IDs allowed to drive the conversation. Nil leaves
    /// the list as it is; `[]` empties it.
    public var allowlist: [String]?
    /// `.confirm` or `.relaxed` only; `.full` is refused. The conversation it
    /// opens never runs looser than the app's own mode.
    public var approvalMode: ApprovalMode?

    public init(
        channelID: String,
        kind: ChannelKind? = nil,
        enabled: Bool? = nil,
        binding: ChannelBindingChoice? = nil,
        allowlist: [String]? = nil,
        approvalMode: ApprovalMode? = nil
    ) {
        self.channelID = channelID
        self.kind = kind
        self.enabled = enabled
        self.binding = binding
        self.allowlist = allowlist
        self.approvalMode = approvalMode
    }
}

public struct ChannelStartRequest: OperationRequest {
    public typealias Response = ChannelSummary
    public static let operation = AppOperation.channelStart
    public var channelID: String

    public init(channelID: String) {
        self.channelID = channelID
    }
}

public struct ChannelStopRequest: OperationRequest {
    public typealias Response = ChannelSummary
    public static let operation = AppOperation.channelStop
    public var channelID: String

    public init(channelID: String) {
        self.channelID = channelID
    }
}

public struct ChannelLogoutRequest: OperationRequest {
    public typealias Response = ChannelSummary
    public static let operation = AppOperation.channelLogout
    public var channelID: String

    public init(channelID: String) {
        self.channelID = channelID
    }
}

public struct ChannelAttachRequest: TaskAttachRequest {
    public static let operation = AppOperation.channelAttach
    public var taskID: TaskID
    public var afterSeq: EventSeq
    public var waitMilliseconds: Int

    public init(
        taskID: TaskID,
        afterSeq: EventSeq = .start,
        waitMilliseconds: Int = Self.defaultWaitMilliseconds
    ) {
        self.taskID = taskID
        self.afterSeq = afterSeq
        self.waitMilliseconds = waitMilliseconds
    }
}

// MARK: - The channel worker's calls

public struct ChannelBindingRequest: OperationRequest {
    public typealias Response = ChannelWorkerBinding
    public static let operation = AppOperation.channelBinding

    public init() {}
}

/// What the host tells its channel worker: which task to report on, which
/// conversation it may reach, and who may drive it. Read again after every
/// restart and whenever the host reports a change.
public struct ChannelWorkerBinding: Codable, Sendable, Equatable {
    public var channelID: String
    public var taskID: TaskID
    /// Nil is General Chat: the host opens there.
    public var projectID: String?
    /// Nil until the host has opened the conversation; the worker never
    /// opens one itself.
    public var sessionID: String?
    public var allowlist: [String]
    public var approvalMode: ApprovalMode
    public var state: ChannelState

    public init(
        channelID: String,
        taskID: TaskID,
        projectID: String?,
        sessionID: String?,
        allowlist: [String],
        approvalMode: ApprovalMode,
        state: ChannelState
    ) {
        self.channelID = channelID
        self.taskID = taskID
        self.projectID = projectID
        self.sessionID = sessionID
        self.allowlist = allowlist
        self.approvalMode = approvalMode
        self.state = state
    }
}

public struct ChannelLoginCodeRequest: OperationRequest {
    public typealias Response = ChannelLoginCodeResponse
    public static let operation = AppOperation.channelLoginCode
    public var channelID: String
    /// The number WeChat showed on the phone while signing in. Typed in the
    /// app, never in the chat.
    public var code: String

    public init(channelID: String, code: String) {
        self.channelID = channelID
        self.code = code
    }
}

public struct ChannelLoginCodeResponse: Codable, Sendable, Equatable {
    public init() {}
}

public struct ChannelSayRequest: OperationRequest {
    public typealias Response = ChannelSayResponse
    public static let operation = AppOperation.channelSay
    public var channelID: String
    /// The platform's ID for the peer that sent it, checked against the
    /// channel's allowlist by the host.
    public var from: String
    /// Stable across reconnects and replays: the host accepts each one once.
    public var clientMessageID: String
    /// The conversation the worker believes it drives; nil before the first
    /// message has opened one. The host uses its own binding either way, and
    /// refuses another conversation.
    public var sessionID: String?
    public var text: String

    public init(channelID: String, from: String, clientMessageID: String, sessionID: String?, text: String) {
        self.channelID = channelID
        self.from = from
        self.clientMessageID = clientMessageID
        self.sessionID = sessionID
        self.text = text
    }
}

public struct ChannelSayResponse: Codable, Sendable, Equatable {
    /// False only when the host refused the message; a refusal is an error
    /// reply instead, so a successful answer is true.
    public var accepted: Bool
    /// The host saw this `clientMessageID` already and did not inject it again.
    public var duplicate: Bool
    public var taskID: TaskID?
    /// The conversation the message went to, opened for the channel when it
    /// had none yet.
    public var sessionID: String?

    public init(accepted: Bool, duplicate: Bool = false, taskID: TaskID? = nil, sessionID: String? = nil) {
        self.accepted = accepted
        self.duplicate = duplicate
        self.taskID = taskID
        self.sessionID = sessionID
    }
}

public struct ChannelReadRequest: OperationRequest {
    public typealias Response = ChannelReadResponse
    public static let operation = AppOperation.channelRead
    public var channelID: String
    /// Must be the channel's bound conversation.
    public var sessionID: String
    public var afterSeq: EventSeq
    public var waitMilliseconds: Int
    /// The worker's own ceiling; the host clamps it too.
    public var maxBytes: Int

    public init(
        channelID: String,
        sessionID: String,
        afterSeq: EventSeq = .start,
        waitMilliseconds: Int = 20000,
        maxBytes: Int = 8 * 1024
    ) {
        self.channelID = channelID
        self.sessionID = sessionID
        self.afterSeq = afterSeq
        self.waitMilliseconds = waitMilliseconds
        self.maxBytes = maxBytes
    }
}

public enum ChannelMessageRole: String, Codable, Sendable {
    case assistant
    case error
    /// A line the channel must show the reader, such as "this needs to be
    /// approved on the device". Never a tool call, a path or an attachment.
    case notice
}

public struct ChannelMessage: Codable, Sendable, Equatable {
    public var seq: EventSeq
    public var role: ChannelMessageRole
    public var text: String

    public init(seq: EventSeq, role: ChannelMessageRole, text: String) {
        self.seq = seq
        self.role = role
        self.text = text
    }
}

public enum ChannelConversationState: String, Codable, Sendable {
    case idle
    case running
    case waitingForApproval
    case ended
    /// The conversation is no longer there; the channel stops rather than
    /// opening another one on its own.
    case unavailable
}

/// What the conversation said since `afterSeq`, as much as a chat message can
/// carry. `pendingApproval` is a flag and nothing more: the worker says the
/// approval has to happen on the device, and a message sent from the platform
/// is never read as one.
public struct ChannelReadResponse: Codable, Sendable, Equatable {
    public var messages: [ChannelMessage]
    public var state: ChannelConversationState
    public var pendingApproval: Bool
    /// Where the next read goes on from. A message cut for size is not
    /// passed: the read stops at the last whole one.
    public var nextSeq: EventSeq

    public init(
        messages: [ChannelMessage] = [],
        state: ChannelConversationState = .idle,
        pendingApproval: Bool = false,
        nextSeq: EventSeq = .start
    ) {
        self.messages = messages
        self.state = state
        self.pendingApproval = pendingApproval
        self.nextSeq = nextSeq
    }
}

// MARK: - Typed calls

public extension ApelinService {
    func channelList(channelID: String? = nil) async throws -> ChannelListResponse {
        try await send(ChannelListRequest(channelID: channelID))
    }

    func channelConfigure(_ request: ChannelConfigureRequest) async throws -> ChannelSummary {
        try await send(request)
    }

    func channelLoginCode(channelID: String, code: String) async throws -> ChannelLoginCodeResponse {
        try await send(ChannelLoginCodeRequest(channelID: channelID, code: code))
    }

    func channelStart(channelID: String) async throws -> ChannelSummary {
        try await send(ChannelStartRequest(channelID: channelID))
    }

    func channelStop(channelID: String) async throws -> ChannelSummary {
        try await send(ChannelStopRequest(channelID: channelID))
    }

    func channelLogout(channelID: String) async throws -> ChannelSummary {
        try await send(ChannelLogoutRequest(channelID: channelID))
    }

    func channelAttach(_ request: ChannelAttachRequest) async throws -> TaskEventBatch {
        try await send(request)
    }

    func channelBinding() async throws -> ChannelWorkerBinding {
        try await send(ChannelBindingRequest())
    }

    func channelSay(_ request: ChannelSayRequest) async throws -> ChannelSayResponse {
        try await send(request)
    }

    func channelRead(_ request: ChannelReadRequest) async throws -> ChannelReadResponse {
        try await send(request)
    }
}
