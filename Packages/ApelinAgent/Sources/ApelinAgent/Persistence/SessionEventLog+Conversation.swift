import Darwin
import Foundation
import KWWKAI

/// `messages.jsonl`: the model's conversation, appended to rather than
/// rewritten.
///
/// One line is one record, in the file's order:
///
///     {"kind":"snapshot","messages":[…]}   the whole conversation, when a
///                                          compaction, a repair or the
///                                          reader's edit rewrote it
///     {"kind":"append","messages":[…]}      the messages finished since
///
/// What a conversation is: its last snapshot, and every append after it.
/// A turn therefore costs one small line per finished message instead of the
/// whole history written again, and what a compaction replaces is still in
/// the file — which is what a fork through an older turn reads.
///
/// A line is written with one append and never edited, so a process killed
/// mid-write leaves a torn last line, which the reader drops (the same rule
/// as `events.jsonl`); damage anywhere else is an error, never an empty
/// conversation.
extension SessionEventLog {
    /// How one line of `messages.jsonl` reads.
    struct ConversationRecord: Codable, Equatable {
        enum Kind: String, Codable {
            case snapshot
            case append
        }

        var kind: Kind
        var messages: [Message]
    }

    /// Where the conversation lives, beside the event log.
    var conversationURL: URL {
        directory.appendingPathComponent("messages.jsonl")
    }

    /// Whether the conversation has been written at all: a session that
    /// predates `messages.jsonl` is seeded from its transcript once.
    var hasConversation: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: conversationURL.path),
              let size = attributes[.size] as? Int
        else { return false }
        return size > 0
    }

    /// The conversation as it stands: the last snapshot and what was appended
    /// after it. Nil for a session that has none yet.
    func readConversation() throws -> [Message]? {
        try conversationSegments().last
    }

    /// Every segment the file holds, in order: each one a snapshot and the
    /// appends that followed it. A fork through an older turn reads the
    /// segment that turn belongs to, so a compaction cannot take it away.
    func conversationSegments() throws -> [[Message]] {
        var segments: [[Message]] = []
        for record in try conversationRecords() {
            switch record.kind {
            case .snapshot:
                segments.append(record.messages)
            case .append:
                guard !segments.isEmpty else {
                    throw SessionStoreError.corrupt("messages.jsonl appends before any snapshot")
                }
                segments[segments.count - 1] += record.messages
            }
        }
        return segments
    }

    /// Adds the messages the conversation gained. A file that holds no
    /// snapshot yet is given one, so every append follows a segment's start.
    func appendConversation(_ messages: [Message]) throws {
        guard !messages.isEmpty else { return }
        try trimTornLine()
        if hasConversation {
            try writeConversationLine(ConversationRecord(kind: .append, messages: messages))
        } else {
            try writeConversationLine(ConversationRecord(kind: .snapshot, messages: messages))
        }
    }

    /// Starts a segment: from here on the conversation is `messages`. What
    /// came before stays in the file, where a fork still reads it.
    func snapshotConversation(_ messages: [Message]) throws {
        try trimTornLine()
        try writeConversationLine(ConversationRecord(kind: .snapshot, messages: messages))
    }

    /// The conversation through the turn of `id`, for a fork: the segment
    /// that holds that message — or, when it holds it twice, the first that
    /// does, which is the context it was read in — cut after it.
    ///
    /// `anchors` says what each message's text became in the model's
    /// conversation; a message sent before anchors were kept is found by
    /// `ConversationHistory`, as the history's own changes find it.
    func conversation(through id: UUID, anchors: [String: HistoryAnchor]) throws -> [Message]? {
        let anchor = anchors[id.uuidString.lowercased()]
        for segment in try conversationSegments() {
            guard let anchor,
                  let index = ConversationHistory.index(of: anchor, in: segment)
            else { continue }
            return Array(segment.prefix(index + 1))
        }
        return nil
    }

    private func conversationRecords() throws -> [ConversationRecord] {
        let url = conversationURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var records: [ConversationRecord] = []
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            do {
                records.append(try Self.decoder.decode(ConversationRecord.self, from: Data(line)))
            } catch {
                // the process died mid-write: the last line is not a record
                if index == lines.count - 1 { break }
                throw SessionStoreError.corrupt("messages.jsonl line \(index + 1)")
            }
        }
        return records
    }

    /// Cuts away a last line the process died in the middle of writing.
    /// Appending after it would make it read as damage where it is meant to
    /// be read past, and the file's whole lines are what a reader trusts.
    private func trimTornLine() throws {
        let url = conversationURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > 0
        else { return }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw SessionStoreError.io("could not read messages.jsonl")
        }
        let tail: Data
        do {
            try handle.seek(toOffset: UInt64(size - 1))
            tail = try handle.read(upToCount: 1) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw SessionStoreError.io("could not read messages.jsonl")
        }
        guard tail != Data([0x0A]) else { return }
        let whole = try Data(contentsOf: url)
        let end = whole.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        try Data(whole[..<end]).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    private func writeConversationLine(_ record: ConversationRecord) throws {
        var data = try Self.conversationEncoder.encode(record)
        data.append(0x0A)
        let descriptor = open(conversationURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw SessionStoreError.io("could not open messages.jsonl")
        }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                guard count > 0 else {
                    throw SessionStoreError.io("could not append to messages.jsonl")
                }
                written += count
            }
        }
    }

    /// The conversation's lines are written the way the event log writes
    /// its own: keys sorted, dates ISO 8601, slashes unescaped.
    static let conversationEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
