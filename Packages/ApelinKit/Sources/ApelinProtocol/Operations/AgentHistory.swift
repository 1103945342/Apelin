import Foundation

// A conversation's history changed by the reader, between runs: a message
// taken back with everything after it, a message's or a reply's text
// edited, a reply deleted, and a new conversation forked from a message.
// The app's alone (CallerPolicy names none of them for an agent).
//
// A message is named by the id its `prompt` event carries; a reply by the
// message whose turn it ends, since replies have no id of their own. Each
// change is recorded as an event of its own (`historyRewound`,
// `messageEdited`, `replyEdited`, `replyDeleted`) after the ones it
// changes, so the event log stays append-only and a transcript built from
// it shows what the model reads now.

/// What the reader may change of a conversation's text.
public enum AgentHistoryRules {
    /// The longest text an edit may give a message or a reply.
    public static let maximumEditLength = 200_000
}

/// Takes a message back: the run going is stopped and waited for, and with
/// `truncate` the message and everything after it leave the conversation
/// the model reads (`historyRewound` {id}). Without it only the stop and the
/// wait happen, before the app restores the code (`gitCheckpointRestore`)
/// with the conversation left as it is.
public struct AgentRewindRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentRewind
    public var sessionID: String
    public var messageID: UUID
    public var truncate: Bool

    public init(sessionID: String, messageID: UUID, truncate: Bool = true) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.truncate = truncate
    }
}

/// Gives a message, or with `reply` the reply that ends its turn, new
/// text. Nothing is sent again: the model reads the new text from the next
/// run on. `expected` is the reply's text as the app shows it, so the
/// worker edits the reply the reader sees and no other.
public struct AgentEditMessageRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentEditMessage
    public var sessionID: String
    public var messageID: UUID
    public var reply: Bool
    public var text: String
    public var expected: String?

    public init(sessionID: String, messageID: UUID, reply: Bool = false, text: String, expected: String? = nil) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.reply = reply
        self.text = text
        self.expected = expected
    }
}

/// Deletes the reply that ends the turn of `messageID` (`replyDeleted`).
/// A message of the reader's is deleted with `agentRewind`, which takes
/// what follows it too.
public struct AgentDeleteReplyRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentDeleteReply
    public var sessionID: String
    public var messageID: UUID
    public var expected: String?

    public init(sessionID: String, messageID: UUID, expected: String? = nil) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.expected = expected
    }
}

/// A new conversation `newSessionID` (a UUID the app chose, of no session
/// yet) holding this one's history through the turn of `messageID`, with
/// the edits made to it since. The source session writes it; the app opens
/// it as it opens any saved session, with `agentOpen` naming it.
public struct AgentForkRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentFork
    public var sessionID: String
    public var newSessionID: String
    public var messageID: UUID

    public init(sessionID: String, newSessionID: String, messageID: UUID) {
        self.sessionID = sessionID
        self.newSessionID = newSessionID
        self.messageID = messageID
    }
}

public extension ApelinService {
    func agentRewind(sessionID: String, messageID: UUID, truncate: Bool = true) async throws {
        _ = try await send(AgentRewindRequest(sessionID: sessionID, messageID: messageID, truncate: truncate))
    }

    func agentEditMessage(
        sessionID: String,
        messageID: UUID,
        reply: Bool = false,
        text: String,
        expected: String? = nil,
    ) async throws {
        _ = try await send(AgentEditMessageRequest(
            sessionID: sessionID,
            messageID: messageID,
            reply: reply,
            text: text,
            expected: expected,
        ))
    }

    func agentDeleteReply(sessionID: String, messageID: UUID, expected: String? = nil) async throws {
        _ = try await send(AgentDeleteReplyRequest(sessionID: sessionID, messageID: messageID, expected: expected))
    }

    func agentFork(sessionID: String, newSessionID: String, messageID: UUID) async throws {
        _ = try await send(AgentForkRequest(sessionID: sessionID, newSessionID: newSessionID, messageID: messageID))
    }
}
