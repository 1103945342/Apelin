import CryptoKit
import Foundation

/// Immutable, content-addressed blobs. Forks copy only the objects their
/// manifests reference; neither a source session nor its later turns are
/// needed to open a fork. Shared messages (including images) occupy one
/// object per session, rather than one copy per turn.
struct HistoryObjectStore {
    let directory: URL

    enum Failure: Error {
        case invalidName
        case unsafePath
        case damagedObject
    }

    func put(_ data: Data) throws -> String {
        try makeDirectory()
        let name = Self.digest(data)
        let url = directory.appendingPathComponent(name)
        if try Self.itemExists(url) {
            // Verify, never silently replace a damaged immutable object.
            guard try get(name) == data else { throw Failure.damagedObject }
            return name
        }
        try Self.write(data, to: url)
        return name
    }

    func get(_ name: String) throws -> Data {
        guard name.count == 64, name.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw Failure.invalidName
        }
        try Self.requireDirectory(directory)
        let url = directory.appendingPathComponent(name)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.unsafePath }
        let data = try Data(contentsOf: url)
        guard Self.digest(data) == name else { throw Failure.damagedObject }
        return data
    }

    func makeDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try Self.requireDirectory(directory)
    }

    static func itemExists(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
        {
            return false
        }
    }

    static func requireDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unsafePath }
    }

    /// A new file, then rename: a failed save leaves the old reference usable.
    static func write(_ data: Data, to url: URL) throws {
        try requireDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".history-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
