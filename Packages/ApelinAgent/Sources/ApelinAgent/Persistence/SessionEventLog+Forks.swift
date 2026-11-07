import ApelinCore
import Foundation
import KWWKAI

/// A turn's model conversation and UI events, taken together. The log is
/// not a substitute for messages: it truncates tool results and omits image
/// bytes, provider signatures and native compaction blocks.
struct ForkContext: Sendable {
    var messages: [Message]
    var records: [SessionEventRecord]
    var anchors: [String: HistoryAnchor]

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

/// Small manifests reference immutable message/event objects. Sealed turns
/// never change when later turns edit, rewind or compact the live transcript.
extension SessionEventLog {
    private struct ForkManifest: Codable {
        var version = 1
        var sealed: Bool
        var messages: [String]
        var records: [String]
        var anchors: [String: HistoryAnchor]
    }

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
        let records = try records(afterSeq: 0)
        var located: [(id: UUID, index: Int, anchor: HistoryAnchor)] = []
        for (position, record) in records.enumerated() {
            guard case let .userMessage(id, text, attachments) = record.event else { continue }
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
                if case let .userMessage(_, value, files) = $0.event { return value == text && files == attachments }
                return false
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
        let objects = HistoryObjectStore(directory: forksDirectory.appendingPathComponent("objects"))
        var messageObjects: [String] = []
        for message in messages {
            messageObjects.append(try objects.put(encoder.encode(message)))
        }
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
                if case let .userMessage(id, _, _) = $0.event { return id == item.id }
                return false
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
            guard let turnRecords = AgentSession.forkRecords(records, through: item.id) else { continue }
            var eventObjects: [String] = []
            for record in turnRecords {
                eventObjects.append(try objects.put(encoder.encode(record)))
            }
            var turnAnchors: [String: HistoryAnchor] = [:]
            for previous in located where previous.index < end {
                turnAnchors[previous.id.uuidString.lowercased()] = previous.anchor
            }
            let manifest = ForkManifest(
                sealed: seal || end < messages.count,
                messages: Array(messageObjects[..<end]), records: eventObjects, anchors: turnAnchors,
            )
            try HistoryObjectStore.write(encoder.encode(manifest), to: url)
        }
    }

    func readForkContext(_ id: UUID) throws -> ForkContext? {
        guard let manifest = try readManifest(id) else { return nil }
        let objects = HistoryObjectStore(directory: forksDirectory.appendingPathComponent("objects"))
        var messages: [Message] = []
        for name in manifest.messages {
            messages.append(try Self.decoder.decode(Message.self, from: objects.get(name)))
        }
        var records: [SessionEventRecord] = []
        for name in manifest.records {
            records.append(try Self.decoder.decode(SessionEventRecord.self, from: objects.get(name)))
        }
        return ForkContext(messages: messages, records: records, anchors: manifest.anchors)
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
        guard manifest.version == 1 else { throw SessionStoreError.corrupt("unsupported fork history version") }
        return manifest
    }

    /// Copies the selected version, even if the source advances while the
    /// fork is being written. The new session's target is already sealed.
    static func writeForkContext(_ context: ForkContext, id: UUID, directory: URL) throws {
        let forks = directory.appendingPathComponent("forks")
        if !FileManager.default.fileExists(atPath: forks.path) {
            try FileManager.default.createDirectory(at: forks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try HistoryObjectStore.requireDirectory(forks)
        let objects = HistoryObjectStore(directory: forks.appendingPathComponent("objects"))
        let encoder = forkEncoder()
        var messages: [String] = []
        var records: [String] = []
        for message in context.messages { messages.append(try objects.put(encoder.encode(message))) }
        for record in context.records { records.append(try objects.put(encoder.encode(record))) }
        let manifest = ForkManifest(sealed: true, messages: messages, records: records, anchors: context.anchors)
        try HistoryObjectStore.write(encoder.encode(manifest), to: forks.appendingPathComponent(id.uuidString.lowercased() + ".json"))
    }

    /// Called while writing a new session. Copy only ancestors' snapshots,
    /// not future turns, and never retain a dependency on the source folder.
    static func copyForkHistory(from source: URL, to destination: URL, ids: Set<UUID>) throws {
        let sourceForks = source.appendingPathComponent("forks")
        guard try HistoryObjectStore.itemExists(sourceForks) else { return }
        try HistoryObjectStore.requireDirectory(sourceForks)
        let destinationForks = destination.appendingPathComponent("forks")
        try FileManager.default.createDirectory(at: destinationForks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sourceObjects = HistoryObjectStore(directory: sourceForks.appendingPathComponent("objects"))
        let destinationObjects = HistoryObjectStore(directory: destinationForks.appendingPathComponent("objects"))
        for id in ids {
            let name = id.uuidString.lowercased() + ".json"
            let url = sourceForks.appendingPathComponent(name)
            guard try HistoryObjectStore.itemExists(url) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw HistoryObjectStore.Failure.unsafePath }
            let data = try Data(contentsOf: url)
            let manifest = try decoder.decode(ForkManifest.self, from: data)
            guard manifest.version == 1 else { throw SessionStoreError.corrupt("unsupported fork history version") }
            for object in Set(manifest.messages + manifest.records) {
                _ = try destinationObjects.put(sourceObjects.get(object))
            }
            try HistoryObjectStore.write(data, to: destinationForks.appendingPathComponent(name))
        }
    }
}
