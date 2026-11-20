import CryptoKit
import Foundation
import KWWKAI

/// Where a message of the reader's is in the conversation the model reads:
/// the text the model got for it, by digest, and how the reader's own text
/// sits in it. The model's text has this moment's `<system-state>` before
/// the reader's, and the attached files' list after it; an edit changes the
/// reader's part only. Kept by message id in `anchors.json`.
public struct HistoryAnchor: Codable, Sendable, Hashable {
    /// SHA-256 of the message's text blocks, joined, as the model got them.
    public var digest: String
    /// What the reader typed, as the event log has it.
    public var typed: String
    /// The bytes after it in the model's text: the attachments' list.
    public var suffixBytes: Int
    /// When the message was made, in milliseconds (`Timestamp`): of two with
    /// the same text, the one nearest this.
    public var timestamp: Int64

    public init(digest: String, typed: String, suffixBytes: Int, timestamp: Int64) {
        self.digest = digest
        self.typed = typed
        self.suffixBytes = suffixBytes
        self.timestamp = timestamp
    }
}

/// The edits Checkpoint & Rewind and a message's menu make to the model's
/// conversation, and how a message is found in it. Pure functions of
/// kwwk's messages.
enum ConversationHistory {
    // MARK: Finding messages

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A user message's text blocks, joined: what a digest is made of.
    static func text(of message: UserMessage) -> String {
        var parts: [String] = []
        for block in message.content {
            if case let .text(content) = block {
                parts.append(content.text)
            }
        }
        return parts.joined()
    }

    /// Whether `message` is one the reader sent (or another conversation
    /// sent as theirs), not one kwwk or a compaction put there.
    static func isReaderMessage(_ message: Message) -> Bool {
        guard case let .user(user) = message else { return false }
        return user.source == nil && user.nativeCompaction == nil
    }

    /// The index of the message `anchor` names, the nearest in time when
    /// two have the same text; nil when none has it any more (a compaction
    /// summarised it, or it was taken back).
    static func index(of anchor: HistoryAnchor, in messages: [Message]) -> Int? {
        var best: (index: Int, distance: Int64)?
        for (index, message) in messages.enumerated() {
            guard isReaderMessage(message), case let .user(user) = message,
                  digest(text(of: user)) == anchor.digest
            else { continue }
            let distance = abs(user.timestamp - anchor.timestamp)
            if let current = best, current.distance < distance {
                continue
            }
            best = (index, distance)
        }
        return best?.index
    }

    /// For a message sent before anchors were kept: the reader's message
    /// whose text holds `typed` with `suffix` after it, counted from the end
    /// as the log counts the same text after it (`later`).
    static func index(typed: String, suffix: String, later: Int, in messages: [Message]) -> Int? {
        var seen = 0
        for index in messages.indices.reversed() {
            guard isReaderMessage(messages[index]), case let .user(user) = messages[index] else { continue }
            let text = text(of: user)
            guard text.hasSuffix(typed + suffix) else { continue }
            if seen == later {
                return index
            }
            seen += 1
        }
        return nil
    }

    /// The first message the reader sent after `index`, else the end.
    static func nextReaderMessage(after index: Int, in messages: [Message]) -> Int {
        var next = index + 1
        while next < messages.count, !isReaderMessage(messages[next]) {
            next += 1
        }
        return next
    }

    /// The files' list the model reads after what the reader typed, from
    /// each attachment's name and path.
    static func attachmentSuffix(_ attachments: [(name: String, path: String)]) -> String {
        let paths = attachments.map { "\($0.name): \($0.path)" }.joined(separator: "\n")
        return paths.isEmpty ? "" : "\n\nAttached files in the workspace:\n" + paths
    }

    // MARK: Editing messages

    /// `message` with what the reader typed replaced by `text`: the bytes
    /// before it and the `suffixBytes` after it stay. Nil when the text
    /// block does not hold `typed` there.
    static func replacingTyped(
        in message: UserMessage,
        typed: String,
        suffixBytes: Int,
        with text: String,
    ) -> UserMessage? {
        guard let blockIndex = message.content.firstIndex(where: {
            if case .text = $0 { return true }
            return false
        }), case let .text(content) = message.content[blockIndex] else { return nil }
        let bytes = Array(content.text.utf8)
        let typedBytes = Array(typed.utf8)
        guard suffixBytes >= 0, bytes.count >= suffixBytes + typedBytes.count else { return nil }
        let end = bytes.count - suffixBytes
        let start = end - typedBytes.count
        guard Array(bytes[start ..< end]) == typedBytes else { return nil }
        let replaced = String(decoding: bytes[..<start], as: UTF8.self) + text
            + String(decoding: bytes[end...], as: UTF8.self)
        var edited = message
        edited.content[blockIndex] = .text(TextContent(text: replaced))
        return edited
    }

    // MARK: Replies

    /// An assistant message's text blocks, joined, as the app shows a reply.
    static func text(of message: AssistantMessage) -> String {
        var parts: [String] = []
        for block in message.content {
            if case let .text(content) = block {
                parts.append(content.text)
            }
        }
        return parts.joined()
    }

    /// The last reply with text in `messages[range]`: the one the app shows
    /// last in that turn.
    static func lastReply(in messages: [Message], range: Range<Int>) -> Int? {
        for index in range.reversed() {
            if case let .assistant(assistant) = messages[index], !text(of: assistant).isEmpty {
                return index
            }
        }
        return nil
    }

    /// The reply's text made `text`: its first text block takes it, any
    /// other text block goes, and its thinking and calls stay.
    static func replacingText(of message: AssistantMessage, with text: String) -> AssistantMessage {
        var edited = message
        var blocks: [AssistantBlock] = []
        var placed = false
        for block in message.content {
            guard case .text = block else {
                blocks.append(block)
                continue
            }
            if !placed {
                blocks.append(.text(TextContent(text: text)))
                placed = true
            }
        }
        if !placed {
            blocks.append(.text(TextContent(text: text)))
        }
        edited.content = blocks
        edited.responseId = nil
        return edited
    }

    /// The reply with its text taken out; nil when nothing else of it is
    /// left, and the whole message goes. A call it made stays, so the
    /// call's result still answers something.
    static func removingText(from message: AssistantMessage) -> AssistantMessage? {
        var edited = message
        edited.content = message.content.filter {
            if case .text = $0 { return false }
            return true
        }
        edited.responseId = nil
        let hasCall = edited.content.contains {
            if case .toolCall = $0 { return true }
            return false
        }
        return hasCall ? edited : nil
    }

    /// Every reply from `index` on forgets the provider's id for it: a
    /// provider that goes on from its own copy of the conversation would
    /// otherwise go on from the text before the edit.
    static func forgettingResponses(from index: Int, in messages: inout [Message]) {
        guard index < messages.count else { return }
        for position in index ..< messages.count {
            if case var .assistant(assistant) = messages[position], assistant.responseId != nil {
                assistant.responseId = nil
                messages[position] = .assistant(assistant)
            }
        }
    }
}
