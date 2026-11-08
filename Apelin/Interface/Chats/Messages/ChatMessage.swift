import ApelinProtocol
import Foundation

/// A conversation row or an ordered entry in its summary's trace.
struct ChatMessage: Identifiable, Hashable {
    enum Role: Hashable {
        case user
        case assistant
        case thinking(seconds: Int?, tools: Int)
        case tool
        case approval(ApprovalDecision?)
        /// Where the reader's Compact… compacted the conversation; the
        /// row's text is the summary it goes on from, empty for a session
        /// that did not keep it.
        case compaction

        var isActivity: Bool {
            switch self {
            case .thinking, .tool: true
            default: false
            }
        }

        var isApproval: Bool {
            if case .approval = self {
                return true
            }
            return false
        }

        var needsApproval: Bool {
            if case .approval(nil) = self {
                return true
            }
            return false
        }

        var isThinking: Bool {
            if case .thinking(nil, _) = self {
                return true
            }
            return false
        }
    }

    let id: UUID
    var role: Role
    var text: String
    var detail = ""
    var trace: [ChatMessage] = []
    var attachments: [ComposerAttachment]
    /// A user message sent during a run that the run has not taken yet.
    var isQueued = false
    /// A user message another conversation's agent sent: the line shown
    /// over the bubble naming that conversation.
    var sender: String?
    /// Only the currently running summary names the message it is processing.
    /// A queued message must not replace this until the model takes it.
    var processingSource: String?
    /// A tool row's call, and on a running summary its newest call, for the
    /// line under the summary.
    var banner: ToolCallBanner?
    /// A tool row whose result has not come back yet.
    var awaitsResult = false
    /// On a running summary, the calls in its trace still waiting for a result.
    var runningTools = 0
    /// On the running summary, a model request that failed is being made
    /// again (the session's `reconnecting`) and nothing has come of it yet.
    var isReconnecting = false
    /// On the turn's latest summary while the run goes, the output tokens
    /// the run has received so far (the session's `received`); nil before
    /// the first count, once the run has ended, and for a session older
    /// than the count.
    var receivedTokens: Int?
    /// The summary's count belongs to a reply the run is writing after it:
    /// the figure settles in half a second, not five (`TokenClimb`).
    var receivedSettles = false
    /// An approval of a command that runs as root (`ApprovalCardText`):
    /// the card says so, and Approve checks the device owner first.
    var runsAsRoot = false
    var approvalSections: [ApprovalCardText.Section] = []
    /// An approval that is a question the agent asked
    /// (`apelin_question_ask`): the card offers its options instead of
    /// Approve and Deny, and the decision sends the answer.
    var question: AgentQuestion?
    /// When the reader sent it: a user message's, for the line under it.
    var sentAt: Date?
    /// Text the model wrote (`text`, `message`), not an error or a tool's
    /// images: the rows a reply's menu acts on.
    var isReply = false
    /// The message whose turn this row is in, by its own id: a user
    /// message's, and a reply's. Nil for a message without one (another
    /// conversation's), which the history's changes cannot name.
    var turnMessageID: UUID?
    /// A user message whose run saved the code first: Checkpoint & Rewind
    /// can put it back.
    var hasCheckpoint = false
    /// On a turn's last reply: what the turn cost and how long it took.
    var turnStats: ChatTurnStats?
    /// The conversation's newest reply, while no run goes: Copy and More
    /// under it.
    var offersActions = false
    /// A reply the reader deleted (`replyDeleted`): left out of the rows
    /// shown.
    var isRemoved = false

    var activityTitle: String {
        guard case let .thinking(seconds, tools) = role else { return text }
        // An unfinished summary counts only the calls still running; between
        // them the model is at work again, so it reads "Thinking…", or
        // "Reconnecting…" while a failed request is made again.
        guard let seconds else {
            if isReconnecting {
                return String(localized: "Reconnecting…")
            }
            guard runningTools > 0 else { return String(localized: "Thinking…") }
            return runningTools == 1
                ? String(localized: "Executing tool…")
                : String(localized: "Executing \(runningTools) tools…")
        }
        if seconds <= 0 {
            guard tools > 0 else { return "" }
            return tools == 1 ? String(localized: "Called 1 tool") : String(localized: "Called \(tools) tools")
        }
        if tools <= 0 {
            return seconds == 1
                ? String(localized: "Thought for 1 second")
                : String(localized: "Thought for \(seconds) seconds")
        }
        if seconds == 1 {
            return tools == 1
                ? String(localized: "Thought for 1 second and called 1 tool")
                : String(localized: "Thought for 1 second and called \(tools) tools")
        }
        return tools == 1
            ? String(localized: "Thought for \(seconds) seconds and called 1 tool")
            : String(localized: "Thought for \(seconds) seconds and called \(tools) tools")
    }

    var approvalTitle: String {
        text.components(separatedBy: "\n\n").first ?? ""
    }

    var approvalDetail: String {
        text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
    }

    init(id: UUID = UUID(), role: Role, text: String, attachments: [ComposerAttachment] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
    }
}

/// What one turn of the conversation cost, as the provider counted it
/// (the `usage` of each reply in it, summed), and how long it ran.
struct ChatTurnStats: Hashable {
    /// Read fresh, not from the provider's prompt cache.
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    /// From the message to the turn's end; nil while it has not ended.
    var seconds: Int?

    /// Everything the model read: fresh, from the cache and into it.
    var promptTokens: Int {
        inputTokens + cacheReadTokens + cacheWriteTokens
    }

    /// The share of what it read that came from the cache, 0 ... 1; nil
    /// when nothing did.
    var cacheHitRate: Double? {
        guard promptTokens > 0, cacheReadTokens > 0 else { return nil }
        return min(1, Double(cacheReadTokens) / Double(promptTokens))
    }

    var hasTokens: Bool {
        promptTokens > 0 || outputTokens > 0
    }
}
