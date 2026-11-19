import ApelinCore
import ApelinProtocol
import Foundation

/// A conversation's events on disk, beside its record: `Chats/<id>.events.jsonl`,
/// one event per line, appended as they come. The record itself,
/// `Chats/<id>.json`, keeps the conversation's summary, draft and pending
/// sends and says how many events there are, so launching reads a few hundred
/// bytes per chat instead of the megabytes its history can be
/// (`Documents/Plan/Memory.md`).
///
/// A record written before the split still carries its events inline; `load`
/// moves them out once, and a record that cannot be moved keeps working as it
/// was.
enum ChatEventsFile {
    static func url(for id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(id.uuidString + ".events.jsonl")
    }

    /// Every event the file holds. A last line that does not decode is a write
    /// that was cut short and is dropped, as a session log's is; damage
    /// anywhere else throws, and is never read as an empty history.
    static func read(_ id: UUID, in folder: URL) throws -> [TaskEvent] {
        let url = url(for: id, in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONCoding.decoder()
        var events: [TaskEvent] = []
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            // The file ends with a newline, so a full last line is followed by
            // an empty one; anything else is the write that was cut short.
            let last = lines.last?.isEmpty == false ? index == lines.count - 1 : index >= lines.count - 2
            do {
                events.append(try decoder.decode(TaskEvent.self, from: Data(line)))
            } catch {
                guard last else { throw error }
            }
        }
        return events
    }

    /// The events of one kind a saved conversation holds, read for a scan that
    /// must not keep the history: restoring the lineage between chats needs the
    /// events that opened another, and nothing else (`ChatRuntime.scanLineage`).
    /// Only a line that mentions the kind is decoded, so a history costs a
    /// pass over its bytes rather than an event in memory each.
    static func scan(_ kind: String, for id: UUID, in folder: URL) throws -> [TaskEvent] {
        let url = url(for: id, in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let needle = Data(kind.utf8)
        let decoder = JSONCoding.decoder()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var events: [TaskEvent] = []
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty, line.range(of: needle) != nil else { continue }
            // The file ends with a newline, so a full last line is followed by
            // an empty one; anything else is the write that was cut short.
            let last = lines.last?.isEmpty == false ? index == lines.count - 1 : index >= lines.count - 2
            do {
                let event = try decoder.decode(TaskEvent.self, from: Data(line))
                if event.kind == kind { events.append(event) }
            } catch {
                guard last else { throw error }
            }
        }
        return events
    }

    /// Replaces the file with `events`, atomically: a compaction, a rewind or an
    /// edit rewrites the history, and a reader never sees it half written. No
    /// events leaves no file, rather than an empty one per conversation.
    static func write(_ events: [TaskEvent], for id: UUID, in folder: URL) throws {
        guard !events.isEmpty else {
            remove(id, in: folder)
            return
        }
        let encoder = JSONCoding.encoder()
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        let destination = url(for: id, in: folder)
        let temporary = folder.appendingPathComponent(".\(id.uuidString).events.\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600],
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Adds the events the conversation gained, one line each.
    static func append(_ events: [TaskEvent], for id: UUID, in folder: URL) throws {
        guard !events.isEmpty else { return }
        let destination = url(for: id, in: folder)
        let encoder = JSONCoding.encoder()
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        // A line the last write left half written would swallow this one.
        trimTornLine(destination)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard FileManager.default.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600],
            ) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    static func remove(_ id: UUID, in folder: URL) {
        unlink(url(for: id, in: folder).path)
    }

    /// Cuts a last line with no newline after it, which the read drops anyway.
    private static func trimTornLine(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return }
        do { try handle.seek(toOffset: size - 1) } catch { return }
        guard let last = try? handle.read(upToCount: 1), last == Data([0x0A]) else {
            // Find the last newline and cut the file there.
            guard let whole = try? Data(contentsOf: url) else { return }
            if let index = whole.lastIndex(of: 0x0A) {
                truncate(url.path, off_t(index + 1))
            } else {
                truncate(url.path, 0)
            }
            return
        }
    }
}
