import Foundation

/// The rules a channel is judged by, in one place with no I/O: what a peer
/// may say, how long a message may be, which approval mode a channel may open
/// a conversation with, and which inbound messages were seen already.
///
/// These live beside the wire because both sides must agree on them, and they
/// keep their own small approval enum so this file compiles and runs on its
/// own (`Scripts/test-channel.sh`), with no dependency on the agent's types.
/// `ApprovalMode` is mapped onto it at the boundary, and `full` maps to
/// nothing: a channel never runs a conversation that asks nothing.

public enum ChannelApprovalMode: String, Codable, Sendable, CaseIterable {
    case confirm
    case relaxed
}

public enum ChannelRuleFailure: String, Codable, Sendable, Equatable {
    case emptyAllowlist
    case tooManyEntries
    case entryTooLong
    case messageEmpty
    case messageTooLong
    case peerNotAllowed
    case conversationGone
}

public enum ChannelRules {
    /// The platform peers one channel may admit.
    public static let maximumAllowlistEntries = 32
    public static let maximumAllowlistEntryBytes = 128
    /// One inbound message, before it becomes a prompt.
    public static let maximumMessageBytes = 32 * 1024
    /// What one read hands back at most.
    public static let maximumReadBytes = 8 * 1024
    /// How many inbound message IDs the host remembers for de-duplication.
    public static let inboxLimit = 512

    /// Trimmed, without empty entries, first occurrence kept. Nothing else is
    /// rewritten: a platform's peer ID is opaque and case matters.
    public static func normalizeAllowlist(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// Why a channel may not be enabled with this list, or nil when it may.
    /// An empty list is the important one: with nobody allowed, the channel
    /// must not run at all rather than admit everything.
    public static func allowlistProblem(_ raw: [String]) -> ChannelRuleFailure? {
        let list = normalizeAllowlist(raw)
        if list.isEmpty {
            return .emptyAllowlist
        }
        if list.count > maximumAllowlistEntries {
            return .tooManyEntries
        }
        if list.contains(where: { $0.utf8.count > maximumAllowlistEntryBytes }) {
            return .entryTooLong
        }
        return nil
    }

    public static func admits(peer: String, allowlist: [String]) -> Bool {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return normalizeAllowlist(allowlist).contains(trimmed)
    }

    /// Why this text may not be injected, or nil when it may. An empty
    /// allowlist admits nobody, so it is a refusal here too.
    public static func messageProblem(_ text: String, allowlist: [String], peer: String) -> ChannelRuleFailure? {
        if let problem = allowlistProblem(allowlist) {
            switch problem {
            case .emptyAllowlist:
                return .emptyAllowlist
            default:
                return problem
            }
        }
        guard admits(peer: peer, allowlist: allowlist) else { return .peerNotAllowed }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .messageEmpty
        }
        if text.utf8.count > maximumMessageBytes {
            return .messageTooLong
        }
        return nil
    }

    /// The mode a channel opens its conversation with: the one it was
    /// configured with, never looser than the app's own. A channel cannot be
    /// configured with `full` at all, so `.confirm` from the app wins over
    /// everything.
    public static func effectiveMode(
        configured: ChannelApprovalMode,
        app: ChannelApprovalMode?
    ) -> ChannelApprovalMode {
        guard let app else { return configured }
        return app == .confirm ? .confirm : configured
    }

    /// What a sign-in poll means for the channel. Scanning is the path the
    /// reader takes; the number WeChat shows is a fallback the server may ask
    /// for, and `blocked` means only a new scan helps.
    public enum ChannelLoginStep: String, Sendable, Equatable {
        case wait
        case scanned
        case needsCode
        case newCode
        case confirmed
        case blocked
    }

    /// How many codes a sign-in may replace before it ends and the reader
    /// starts over.
    public static let maximumLoginCodes = 3

    public static func loginStep(_ status: String) -> ChannelLoginStep {
        switch status {
        case "scaned":
            return .scanned
        case "need_verifycode":
            return .needsCode
        case "confirmed":
            return .confirmed
        case "expired":
            return .newCode
        case "verify_code_blocked":
            return .blocked
        case "wait", "scaned_but_redirect":
            return .wait
        default:
            return .wait
        }
    }

    /// A byte ceiling a read may ask for, clamped both ways.
    public static func readBudget(_ asked: Int) -> Int {
        min(max(asked, 1024), maximumReadBytes)
    }

    /// Starting a channel needs an allowlist that admits somebody and a mode
    /// that may open a conversation. It never needs a token: WeChat hands one
    /// out when the reader signs in, and the worker keeps it to itself.
    public static func startProblem(allowlist: [String], mode: ChannelApprovalMode) -> ChannelRuleFailure? {
        allowlistProblem(allowlist)
    }

    /// What a logout keeps and what it clears, as the host applies it: the
    /// conversation, the project and the allowlist stay, the sign-in goes.
    public struct LogoutOutcome: Equatable, Sendable {
        public var keepsConversation: Bool
        public var keepsAllowlist: Bool
        public var keepsProject: Bool
        public var signedIn: Bool
        public var removesLoginState: Bool
    }

    public static let logoutOutcome = LogoutOutcome(
        keepsConversation: true,
        keepsAllowlist: true,
        keepsProject: true,
        signedIn: false,
        removesLoginState: true
    )

    /// How many bytes of a message may be carried as one piece.
    public static func messageBudget(_ asked: Int) -> Int {
        min(max(asked, 1024), maximumMessageBytes)
    }

    /// Letters, digits, `-` and `_`, at most 64: an ID is a folder name under
    /// the host's state directory and never a path.
    public static func isValidChannelID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64 else { return false }
        for scalar in id.unicodeScalars {
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            let isUpper = scalar.value >= 65 && scalar.value <= 90
            let isLower = scalar.value >= 97 && scalar.value <= 122
            if isDigit || isUpper || isLower || scalar.value == 45 || scalar.value == 95 {
                continue
            }
            return false
        }
        return true
    }
}

/// The inbound message IDs a channel has already injected, oldest out first.
/// Kept on disk by the host; a record that does not read is set aside and the
/// channel is paused rather than started with an empty ledger, which would
/// let a reconnect's replay through a second time.
public struct ChannelInbox: Codable, Sendable, Equatable {
    public var seen: [String: Date]

    public init(seen: [String: Date] = [:]) {
        self.seen = seen
    }

    /// True the first time this ID is offered, false after.
    public mutating func accept(_ id: String, at time: Date = Date()) -> Bool {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        if seen[key] != nil {
            return false
        }
        seen[key] = time
        prune()
        return true
    }

    public func contains(_ id: String) -> Bool {
        seen[id.trimmingCharacters(in: .whitespacesAndNewlines)] != nil
    }

    /// Keeps the newest `ChannelRules.inboxLimit`.
    public mutating func prune(limit: Int = ChannelRules.inboxLimit) {
        guard seen.count > limit else { return }
        let newest = seen.sorted { $0.value > $1.value }.prefix(limit)
        seen = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
}
