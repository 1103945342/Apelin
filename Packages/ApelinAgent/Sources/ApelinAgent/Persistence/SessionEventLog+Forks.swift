import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI

/// A turn's model conversation and UI events, taken together. The log is
/// not a substitute for messages: it truncates tool results and omits image
/// bytes, provider signatures and native compaction blocks.
struct ForkContext: Sendable {
    var messages: [Message]
    var records: [SessionEventRecord]
    var anchors: [String: HistoryAnchor]
    /// Verified serialized bytes retained only for this fork transaction.
    /// Reuse them instead of reading the selected snapshot again while copying.
    var savedObjects: [String: Data] = [:]

    /// Only an unfinished suffix may be discarded after an explicit stop.
    /// A missing result in the middle, an orphan result or a duplicate call
    /// is damage, not cancellation. Keep whole call batches: a partial batch
    /// cannot be resumed even when some of its tools already returned.
    static func completePrefix(of messages: [Message]) throws -> [Message] {
        var outstanding: Set<String> = []
        var boundary = 0
        for (index, message) in messages.enumerated() {
            switch message {
            case let .assistant(assistant):
                if !outstanding.isEmpty, index == messages.count - 1,
                   assistant.stopReason == .aborted,
                   !assistant.content.contains(where: { if case .toolCall = $0 { return true }; return false })
                {
                    // kwwk's thrown-cancellation path appends a terminal
                    // aborted assistant message after the unfinished batch.
                    continue
                }
                guard outstanding.isEmpty else {
                    throw SessionStoreError.corrupt("an assistant message follows unfinished tool calls")
                }
                for block in assistant.content {
                    if case let .toolCall(call) = block, !outstanding.insert(call.id).inserted {
                        throw SessionStoreError.corrupt("duplicate tool call in a message")
                    }
                }
            case let .toolResult(result):
                guard outstanding.remove(result.toolCallId) != nil else {
                    throw SessionStoreError.corrupt("tool result has no pending call")
                }
            default:
                guard outstanding.isEmpty else {
                    throw SessionStoreError.corrupt("a message follows unfinished tool calls")
                }
            }
            if outstanding.isEmpty { boundary = index + 1 }
        }
        return Array(messages.prefix(boundary))
    }

    static func hasCompleteToolResults(_ messages: [Message]) -> Bool {
        var outstanding: Set<String> = []
        for message in messages {
            switch message {
            case let .assistant(assistant):
                for block in assistant.content {
                    if case let .toolCall(call) = block { outstanding.insert(call.id) }
                }
            case let .toolResult(result):
                outstanding.remove(result.toolCallId)
            default:
                break
            }
        }
        return outstanding.isEmpty
    }
}

/// Small manifests reference immutable message objects. Sealed turns never
/// change when later turns edit, rewind or compact the live transcript.
///
/// A turn's UI records are not stored here any more. The event log is
/// append-only, so every turn's records are still in it after an edit, a
/// rewind or a compaction; copying them into objects made every turn, and
/// every fork, write the whole conversation's history again. Version 1
/// manifests are still read, and their object per record is still honoured
/// when the log no longer has the turn.
extension SessionEventLog {
    private struct ForkManifest: Codable {
        var version = 2
        var sealed: Bool
        var messages: [String]
        /// Version 1 only: one object per UI record of the turn.
        var records: [String]?
        var anchors: [String: HistoryAnchor]
    }

    private static let readableForkVersions = 1 ... 2

    private var forksDirectory: URL { directory.appendingPathComponent("forks", isDirectory: true) }

    private static func forkEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Called at stable model boundaries and BEFORE destructive changes.
    /// A legacy conversation seeds every message still in its transcript;
    /// later captures only advance the unsealed current turn.
    func writeHistorySnapshot(_ messages: [Message], anchors: [String: HistoryAnchor], seal: Bool = false) throws {
        guard !messages.isEmpty else { return }
        guard ForkContext.hasCompleteToolResults(messages) else {
            throw SessionStoreError.corrupt("cannot archive a conversation with unfinished tool calls")
        }
        // The pending delta belongs to this snapshot too. On a reopened
        // session the opening summary is not a complete event history.
        let records = try historyRecords()
        var located: [(id: UUID, index: Int, anchor: HistoryAnchor)] = []
        for (position, record) in records.enumerated() {
            let candidate: (id: UUID, text: String, attachments: [AgentAttachment])? = {
                switch record.event {
                case let .userMessage(id, text, attachments): return (id, text, attachments)
                case let .conversationMessageTaken(id, text, _): return (id, text, [])
                default: return nil
                }
            }()
            guard let candidate else { continue }
            let (id, text, attachments) = candidate
            let key = id.uuidString.lowercased()
            if let anchor = anchors[key] {
                if let index = ConversationHistory.index(of: anchor, in: messages), case let .user(user) = messages[index] {
                    // A removed occurrence must not steal a surviving one
                    // with the same text from its own, closer anchor.
                    let distance = abs(user.timestamp - anchor.timestamp)
                    let belongsElsewhere = anchors.contains { other in
                        other.key != key && other.value.digest == anchor.digest
                            && abs(user.timestamp - other.value.timestamp) < distance
                    }
                    if !belongsElsewhere { located.append((id, index, anchor)) }
                }
                continue
            }
            // Sessions predating anchors: never identify repeated text by
            // its first occurrence alone.
            let later = records[(position + 1)...].count {
                switch $0.event {
                case let .userMessage(_, value, files): return value == text && files == attachments
                case let .conversationMessageTaken(_, value, _): return value == text && attachments.isEmpty
                default: return false
                }
            }
            let suffix = ConversationHistory.attachmentSuffix(attachments.map { (name: $0.name, path: $0.path) })
            guard let index = ConversationHistory.index(typed: text, suffix: suffix, later: later, in: messages),
                  case let .user(user) = messages[index]
            else { continue }
            located.append((id, index, HistoryAnchor(
                digest: ConversationHistory.digest(ConversationHistory.text(of: user)),
                typed: text, suffixBytes: suffix.utf8.count, timestamp: user.timestamp,
            )))
        }
        guard !located.isEmpty else { return }
        try prepareForks()
        let encoder = Self.forkEncoder()
        let objects = try HistoryObjectStore(directory: forksDirectory.appendingPathComponent("objects"))
        // The objects are content-addressed, so an object already stored is
        // the message stored again. Encoding and hashing every message on
        // every turn made the cost grow with the conversation; each is
        // encoded once, and a manifest names the ones its turn reaches.
        var encoded: [Data?] = Array(repeating: nil, count: messages.count)
        for item in located {
            let url = manifestURL(item.id)
            let existing = try readManifest(item.id)
            if existing?.sealed == true { continue }
            if existing == nil, case let .user(recap)? = messages.first,
               recap.source == .compaction || recap.nativeCompaction != nil,
               case let .user(user) = messages[item.index], user.timestamp <= recap.timestamp
            {
                // The retained tail predates this summary. Without an older
                // snapshot its original prefix is lost too, even though the
                // selected user message itself survived compaction.
                continue
            }
            let end = ConversationHistory.nextReaderMessage(after: item.index, in: messages)
            if existing == nil, let position = records.firstIndex(where: {
                switch $0.event {
                case let .userMessage(id, _, _), let .conversationMessageTaken(id, _, _):
                    return id == item.id
                default:
                    return false
                }
            }) {
                let prefix = Set(located.filter { $0.index < end }.map(\.id))
                let changedLater = records[(position + 1)...].contains { record in
                    switch record.event {
                    case let .messageEdited(id, _), let .replyEdited(id, _), let .replyDeleted(id):
                        return prefix.contains(id)
                    default:
                        return false
                    }
                }
                // A legacy transcript already edited since this turn is
                // not its historical version. Do not label it as one.
                if changedLater { continue }
            }
            // The turn's records are read back from the log when the turn is
            // forked (`readForkContext`): the log is append-only, so a copy of
            // them here only made every turn write the whole history again.
            guard records.forkRecords(through: item.id) != nil else { continue }
            var turnAnchors: [String: HistoryAnchor] = [:]
            for previous in located where previous.index < end {
                turnAnchors[previous.id.uuidString.lowercased()] = previous.anchor
            }
            var turnMessages: [String] = []
            turnMessages.reserveCapacity(end)
            for index in 0 ..< end {
                let data: Data
                if let done = encoded[index] {
                    data = done
                } else {
                    data = try encoder.encode(messages[index])
                    encoded[index] = data
                }
                turnMessages.append(try objects.put(data))
            }
            let manifest = ForkManifest(
                sealed: seal || end < messages.count,
                messages: turnMessages,
                records: nil, anchors: turnAnchors,
            )
            try HistoryObjectStore.write(encoder.encode(manifest), to: url)
        }
    }

    /// End a stopped run at its last whole model boundary. Sealing is not
    /// recapturing: the saved UI records must stay paired with the saved
    /// messages, without the partial call/approval events emitted afterwards.
    /// Validate every unsealed snapshot before changing any of them, and let
    /// damaged objects, manifests and IO errors reach the caller unchanged.
    func recoverInterruptedHistory(_ messages: [Message]) throws -> [Message] {
        let prefix = try ForkContext.completePrefix(of: messages)
        guard prefix.count < messages.count else { return messages }
        guard !prefix.isEmpty else {
            throw SessionStoreError.corrupt("no complete conversation boundary before interrupted calls")
        }
        let records = try records(afterSeq: 0)
        var pending: [(UUID, ForkManifest)] = []
        var seen: Set<UUID> = []
        for record in records {
            let messageID: UUID? = {
                switch record.event {
                case let .userMessage(id, _, _), let .conversationMessageTaken(id, _, _): return id
                default: return nil
                }
            }()
            guard let messageID,
                  seen.insert(messageID).inserted,
                  var manifest = try readManifest(messageID), !manifest.sealed
            else { continue }
            guard let context = try readForkContext(messageID),
                  try ForkContext.completePrefix(of: context.messages) == context.messages
            else {
                throw SessionStoreError.corrupt("saved boundary has unfinished tool calls")
            }
            manifest.sealed = true
            pending.append((messageID, manifest))
        }
        let encoder = Self.forkEncoder()
        for (id, manifest) in pending {
            try HistoryObjectStore.write(encoder.encode(manifest), to: manifestURL(id))
        }
        try writeTranscript(prefix)
        return prefix
    }

    /// Older builds wrote the stopped run's unfinished tail to the live
    /// transcript. Repair only a recorded stop, not a successful run or an
    /// arbitrary malformed history. Decoding and filesystem failures throw.
    func readResumableTranscript() throws -> [Message] {
        let messages = try readTranscript()
        guard !ForkContext.hasCompleteToolResults(messages) else { return messages }
        let records = try records(afterSeq: 0)
        let ending = records.reversed().first { record in
            switch record.event {
            case .finished, .userMessage, .promptSubmitted, .conversationMessageTaken: true
            default: false
            }
        }
        guard case .finished(reason: .aborted)? = ending?.event else {
            throw SessionStoreError.corrupt("unfinished tool calls without a recorded stop")
        }
        return try recoverInterruptedHistory(messages)
    }

    func readForkContext(_ id: UUID) throws -> ForkContext? {
        guard let manifest = try readManifest(id) else { return nil }
        let objects = try HistoryObjectStore(directory: forksDirectory.appendingPathComponent("objects"))
        var messages: [Message] = []
        var saved: [String: Data] = [:]
        for (name, data) in zip(manifest.messages, try objects.get(manifest.messages)) {
            messages.append(try Self.decoder.decode(Message.self, from: data))
            saved[name] = data
        }
        // The turn's UI records come from the log, which is append-only and
        // still holds every turn after an edit, a rewind or a compaction. A
        // version 1 manifest kept its own copy, and one written from a
        // reopened session's opening summary held a fragment of the history:
        // the log is what keeps a fork's visible replies whole.
        var records: [SessionEventRecord] = []
        // persisted-read: a log that cannot be read falls back to the
        // snapshot's own objects below, never to an empty history
        let history = try? historyRecords()
        if let history, let derived = history.forkRecords(through: id) {
            records = derived
        } else if let names = manifest.records, !names.isEmpty {
            for (name, data) in zip(names, try objects.get(names)) {
                records.append(try Self.decoder.decode(SessionEventRecord.self, from: data))
                saved[name] = data
            }
        }
        return ForkContext(messages: messages, records: records, anchors: manifest.anchors, savedObjects: saved)
    }

    private func prepareForks() throws {
        if !FileManager.default.fileExists(atPath: forksDirectory.path) {
            try FileManager.default.createDirectory(at: forksDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try HistoryObjectStore.requireDirectory(forksDirectory)
    }

    private func manifestURL(_ id: UUID) -> URL {
        forksDirectory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func readManifest(_ id: UUID) throws -> ForkManifest? {
        let url = manifestURL(id)
        guard try HistoryObjectStore.itemExists(url) else { return nil }
        try HistoryObjectStore.requireDirectory(forksDirectory)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw HistoryObjectStore.Failure.unsafePath }
        let manifest = try Self.decoder.decode(ForkManifest.self, from: Data(contentsOf: url))
        guard Self.readableForkVersions.contains(manifest.version) else {
            throw SessionStoreError.corrupt("unsupported fork history version")
        }
        return manifest
    }

    /// Copies the selected version, even if the source advances while the
    /// fork is being written. The new session's target is already sealed.
    /// Its records are not written here: they are read back from the new
    /// session's own log, which holds them through this turn.
    static func writeForkContext(_ context: ForkContext, id: UUID, directory: URL) throws {
        let forks = directory.appendingPathComponent("forks")
        if !FileManager.default.fileExists(atPath: forks.path) {
            try FileManager.default.createDirectory(at: forks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try HistoryObjectStore.requireDirectory(forks)
        let objects = try HistoryObjectStore(directory: forks.appendingPathComponent("objects"))
        let encoder = forkEncoder()
        var messages: [String] = []
        for message in context.messages { messages.append(try objects.put(encoder.encode(message))) }
        let manifest = ForkManifest(sealed: true, messages: messages, records: nil, anchors: context.anchors)
        try HistoryObjectStore.write(encoder.encode(manifest), to: forks.appendingPathComponent(id.uuidString.lowercased() + ".json"))
    }

    /// Called while writing a new session. Copy only ancestors' snapshots,
    /// not future turns, and never retain a dependency on the source folder.
    /// `history` is the source log's records, which the new session's log
    /// also carries: an ancestor whose turn is in it is written without the
    /// version 1 record objects, so a fork of an older conversation stops
    /// copying its whole history. An ancestor the log no longer has keeps its
    /// objects and is copied as it is.
    static func copyForkHistory(
        from source: URL,
        to destination: URL,
        ids: Set<UUID>,
        history: [SessionEventRecord],
        savedObjects: [String: Data] = [:],
    ) throws {
        let sourceForks = source.appendingPathComponent("forks")
        guard try HistoryObjectStore.itemExists(sourceForks) else { return }
        try HistoryObjectStore.requireDirectory(sourceForks)
        let destinationForks = destination.appendingPathComponent("forks")
        try FileManager.default.createDirectory(at: destinationForks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sourceObjects = try HistoryObjectStore(directory: sourceForks.appendingPathComponent("objects"))
        var destinationObjects = try HistoryObjectStore(directory: destinationForks.appendingPathComponent("objects"))
        var names = Set(savedObjects.keys)
        var manifests: [(String, Data)] = []
        let encoder = forkEncoder()
        for id in ids {
            let name = id.uuidString.lowercased() + ".json"
            let url = sourceForks.appendingPathComponent(name)
            guard try HistoryObjectStore.itemExists(url) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw HistoryObjectStore.Failure.unsafePath }
            let data = try Data(contentsOf: url)
            let manifest = try decoder.decode(ForkManifest.self, from: data)
            guard readableForkVersions.contains(manifest.version) else {
                throw SessionStoreError.corrupt("unsupported fork history version")
            }
            names.formUnion(manifest.messages)
            guard history.forkRecords(through: id) != nil else {
                names.formUnion(manifest.records ?? [])
                manifests.append((name, data))
                continue
            }
            let updated = ForkManifest(
                sealed: manifest.sealed,
                messages: manifest.messages,
                records: nil,
                anchors: manifest.anchors,
            )
            manifests.append((name, try encoder.encode(updated)))
        }
        var copied: Set<String> = []
        try destinationObjects.copy(Array(names), from: sourceObjects, copied: &copied, preloaded: savedObjects)
        for (name, data) in manifests {
            try HistoryObjectStore.write(data, to: destinationForks.appendingPathComponent(name))
        }
    }
}

extension Array where Element == SessionEventRecord {
    /// Historical UI events through this turn's first finish or the next
    /// prompt, without untaken queued messages or later maintenance. A
    /// partial boundary gets an aborted finish. Numbered from 1; the app
    /// replays this new log rather than cutting its current UI a second time.
    /// It lives with the log, not the session, because a fork's history is
    /// rebuilt from the append-only log: that is why no manifest has to keep
    /// its own copy of it.
    func forkRecords(through id: UUID) -> [SessionEventRecord]? {
        guard let start = firstIndex(where: {
            switch $0.event {
            case let .userMessage(messageID, _, _), let .conversationMessageTaken(messageID, _, _):
                return messageID == id
            default:
                return false
            }
        }) else { return nil }
        let startsTurn: (SessionEventRecord) -> Bool = { record in
            switch record.event {
            case .userMessage, .promptSubmitted, .conversationMessageTaken:
                return true
            default:
                return false
            }
        }
        let next = self[(start + 1)...].firstIndex(where: startsTurn) ?? count
        // Compaction, edits and other later maintenance are not part of
        // the historical turn, even when no new prompt followed it yet.
        let finished = self[(start + 1) ..< next].firstIndex {
            if case .finished = $0.event { return true }
            return false
        }
        let end = finished.map { $0 + 1 } ?? next
        var taken: Set<UUID> = []
        for record in self[..<end] {
            switch record.event {
            case let .userMessage(messageID, _, _), let .conversationMessageTaken(messageID, _, _):
                taken.insert(messageID)
            default:
                break
            }
        }
        var kept = self[..<end].filter {
            switch $0.event {
            case let .userMessageQueued(messageID, _, _), let .conversationMessageQueued(messageID, _, _):
                return taken.contains(messageID)
            case .conversationMessagesDropped:
                return false // their untaken queue entries are excluded too
            default:
                return true
            }
        }
        let lastTurn = kept.lastIndex(where: startsTurn) ?? 0
        let ended = kept[lastTurn...].contains {
            if case .finished = $0.event { return true }
            return false
        }
        if !ended {
            kept.append(SessionEventRecord(seq: 0, date: kept.last?.date ?? Date(), event: .finished(reason: .aborted)))
        }
        return kept.enumerated().map { offset, record in
            SessionEventRecord(seq: UInt64(offset + 1), date: record.date, event: record.event)
        }
    }
}
