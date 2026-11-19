import Foundation

// Reporting a turn of a conversation an agent opened back to the conversation
// that opened it (Documents/Plan/Team-Collaboration.md). The host reads the
// child's own task events and reports what it saw: a report is a fact about a
// turn that ended, never an instruction, and it never speaks for the reader.
// The opener's worker receives a batch with the prompt
// (`AgentPromptRequest.reports`) and keeps it with the message
// (`PendingMessage.reports`).

/// How the turn ended, as the closing event of the child's run says.
public enum AgentTurnOutcome: String, Codable, Sendable, Hashable {
    case completed
    case aborted
    case failed
    /// The child's worker went away mid-turn (the host closed it, or the
    /// process died), which `finished` records as aborted history.
    case interrupted
}

/// Who asked the turn to stop, when it did not end on its own.
public enum AgentTurnStoppedBy: String, Codable, Sendable, Hashable {
    /// The reader, in Apelin or through a chat channel.
    case user
    /// The conversation that opened the child.
    case opener
    /// The host itself: a worker it had to end, a channel it closed.
    case host
}

/// One turn of a conversation an agent opened, as the host reported it.
///
/// `childTaskID` and `closingSeq` name the turn exactly: the child's task and
/// the sequence number of the `finished` event that ended it. They are what
/// makes a redelivered report the same fact (`key`), which the opener's
/// session drops instead of handing its model a second copy.
public struct AgentTurnReport: Codable, Sendable, Hashable {
    /// The conversation whose turn ended.
    public var childSessionID: String
    /// The child's task (its run) that ended.
    public var childTaskID: String
    /// The child conversation's title, as the host knows it.
    public var title: String?
    public var outcome: AgentTurnOutcome
    /// Who stopped it; nil when it ended on its own.
    public var stoppedBy: AgentTurnStoppedBy?
    /// The `finished` event's sequence number in the child's log.
    public var closingSeq: UInt64
    /// The messages of the opener's the child took in that turn, by id.
    public var answered: [UUID]
    /// The child's last answer, bounded by the host.
    public var text: String
    /// Whether `text` is shorter than the child's whole answer.
    public var truncated: Bool

    public init(
        childSessionID: String,
        childTaskID: String,
        title: String? = nil,
        outcome: AgentTurnOutcome,
        stoppedBy: AgentTurnStoppedBy? = nil,
        closingSeq: UInt64,
        answered: [UUID] = [],
        text: String,
        truncated: Bool = false,
    ) {
        self.childSessionID = childSessionID
        self.childTaskID = childTaskID
        self.title = title
        self.outcome = outcome
        self.stoppedBy = stoppedBy
        self.closingSeq = closingSeq
        self.answered = answered
        self.text = text
        self.truncated = truncated
    }

    /// What makes two deliveries of one report the same fact.
    public var key: AgentTurnReportKey {
        AgentTurnReportKey(
            childSessionID: childSessionID,
            childTaskID: childTaskID,
            closingSeq: closingSeq,
        )
    }
}

/// The identity of one closed turn: the child's session, its task and the
/// sequence number of the event that ended it.
public struct AgentTurnReportKey: Codable, Sendable, Hashable {
    public var childSessionID: String
    public var childTaskID: String
    public var closingSeq: UInt64

    public init(childSessionID: String, childTaskID: String, closingSeq: UInt64) {
        self.childSessionID = childSessionID
        self.childTaskID = childTaskID
        self.closingSeq = closingSeq
    }
}
