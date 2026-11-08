import ApelinCore
import Foundation
import KWWKAI

/// `anchors.json` beside the transcript (`HistoryAnchor`), and a forked
/// conversation's folder written whole.
extension SessionEventLog {
    private static func historyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The anchors kept, by message id. A file that does not read is set
    /// aside (`UnreadableFile`) rather than replaced by the next write, and
    /// the messages it named are found the way older ones are.
    func readAnchors() -> [String: HistoryAnchor] {
        let url = directory.appendingPathComponent("anchors.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try Self.decoder.decode([String: HistoryAnchor].self, from: Data(contentsOf: url))
        } catch {
            _ = UnreadableFile.setAside(url)
            return [:]
        }
    }

    func writeAnchors(_ anchors: [String: HistoryAnchor]) throws {
        let data = try Self.historyEncoder().encode(anchors)
        let url = directory.appendingPathComponent("anchors.json")
        let temporary = directory.appendingPathComponent(".anchors.json.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SessionStoreError.io("could not write anchors.json")
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw SessionStoreError.io("could not replace anchors.json")
        }
    }

    /// Writes a new session's folder beside this one's: its metadata, the
    /// events numbered from 1, the model's conversation and the anchors.
    /// Refused when the folder is there already; a write that fails takes
    /// the folder away again.
    static func writeFork(
        sessionsRoot: URL,
        metadata: SessionMetadata,
        records: [SessionEventRecord],
        transcript: [Message],
        anchors: [String: HistoryAnchor],
        historySource: URL,
        through messageID: UUID,
        savedObjects: [String: Data] = [:],
    ) throws {
        guard isValidSessionID(metadata.id) else { throw SessionStoreError.invalidSessionID(metadata.id) }
        let encoder = historyEncoder()
        let folder = sessionsRoot.appendingPathComponent(metadata.id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw SessionStoreError.io("a session \(metadata.id) is there already")
        }
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700],
        )
        do {
            let ids = Set(records.compactMap { record -> UUID? in
                switch record.event {
                case let .userMessage(id, _, _), let .conversationMessageTaken(id, _, _): return id
                default: return nil
                }
            }).subtracting([messageID])
            try copyForkHistory(from: historySource, to: folder, ids: ids, savedObjects: savedObjects)
            try writeForkContext(
                ForkContext(messages: transcript, records: records, anchors: anchors),
                id: messageID, directory: folder,
            )
            var events = Data()
            for record in records {
                let line = try encoder.encode(record)
                events.append(line)
                events.append(0x0A)
            }
            let files: [(String, Data)] = try [
                ("session.json", encoder.encode(metadata)),
                ("events.jsonl", events),
                ("transcript.json", encoder.encode(transcript)),
                ("anchors.json", encoder.encode(anchors)),
            ]
            for (name, data) in files {
                let path = folder.appendingPathComponent(name).path
                guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw SessionStoreError.io("could not write \(name)")
                }
            }
        } catch {
            // the folder made just above, by a UUID's name
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
