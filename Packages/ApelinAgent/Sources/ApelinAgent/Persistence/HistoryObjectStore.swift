import CryptoKit
import Foundation

/// Immutable, content-addressed blobs. Existing sessions keep loose objects;
/// forks pack their inherited objects into one file instead of creating
/// thousands of tiny files. Neither format depends on the source session.
struct HistoryObjectStore {
    let directory: URL
    private var packed: [String: Data]

    private struct Archive: Codable {
        var version = 1
        var objects: [String: Data]
    }

    static let archiveName = "inherited.plist"

    enum Failure: Error {
        case invalidName
        case unsafePath
        case damagedObject
    }

    init(directory: URL) throws {
        self.directory = directory
        let archive = directory.appendingPathComponent(Self.archiveName)
        if try Self.itemExists(archive) {
            try Self.requireDirectory(directory)
            let fd = try Self.openDirectory(directory)
            defer { close(fd) }
            guard let bytes = try Self.read(Self.archiveName, in: fd) else { throw Failure.damagedObject }
            let decoded = try PropertyListDecoder().decode(Archive.self, from: bytes)
            guard decoded.version == 1 else { throw Failure.damagedObject }
            for (name, data) in decoded.objects {
                try Self.validateName(name)
                guard Self.digest(data) == name else { throw Failure.damagedObject }
            }
            packed = decoded.objects
        } else {
            packed = [:]
        }
    }

    func put(_ data: Data) throws -> String {
        let name = Self.digest(data)
        if let existing = packed[name] {
            guard existing == data else { throw Failure.damagedObject }
            return name
        }
        try makeDirectory()
        let url = directory.appendingPathComponent(name)
        if try Self.itemExists(url) {
            guard try get(name) == data else { throw Failure.damagedObject }
            return name
        }
        try Self.write(data, to: url)
        return name
    }

    /// A transaction copies each object once and publishes one archive. All
    /// bytes are verified before publishing; an error changes neither the old
    /// archive nor `copied`. Call once with the union of ancestor references.
    mutating func copy(_ names: [String], from source: HistoryObjectStore, copied: inout Set<String>, preloaded: [String: Data] = [:]) throws {
        let needed = Set(names).subtracting(copied)
        guard !needed.isEmpty else { return }
        try makeDirectory()
        let input = try Self.openDirectory(source.directory)
        defer { close(input) }
        let output = try Self.openDirectory(directory)
        defer { close(output) }
        var objects = packed
        for name in needed {
            try Self.validateName(name)
            let data: Data
            if let cached = preloaded[name] {
                guard Self.digest(cached) == name else { throw Failure.damagedObject }
                data = cached
            } else {
                data = try source.get(name, in: input)
            }
            if let existing = packed[name] {
                guard existing == data else { throw Failure.damagedObject }
            } else if let existing = try Self.read(name, in: output) {
                guard existing == data else { throw Failure.damagedObject }
            }
            objects[name] = data
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try Self.write(encoder.encode(Archive(objects: objects)), to: directory.appendingPathComponent(Self.archiveName))
        packed = objects
        copied.formUnion(needed)
    }

    func get(_ name: String) throws -> Data {
        try Self.validateName(name)
        if let data = packed[name] { return data }
        let fd = try Self.openDirectory(directory)
        defer { close(fd) }
        return try get(name, in: fd)
    }

    /// Reading a snapshot pins its directory once rather than resolving the
    /// same path for every event. Packed bytes were verified by init.
    func get(_ names: [String]) throws -> [Data] {
        guard !names.isEmpty else { return [] }
        let fd = try Self.openDirectory(directory)
        defer { close(fd) }
        var result: [Data] = []
        result.reserveCapacity(names.count)
        for name in names { result.append(try get(name, in: fd)) }
        return result
    }

    private func get(_ name: String, in directory: Int32) throws -> Data {
        try Self.validateName(name)
        if let data = packed[name] { return data }
        guard let data = try Self.read(name, in: directory), Self.digest(data) == name else {
            throw Failure.damagedObject
        }
        return data
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        return fd
    }

    private static func validateName(_ name: String) throws {
        let bytes = name.utf8
        guard bytes.count == 64, bytes.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else {
            throw Failure.invalidName
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    /// Nil means absent, never unreadable. O_NONBLOCK lets fstat reject a
    /// special file without blocking; O_NOFOLLOW rejects even dangling links.
    private static func read(_ name: String, in directory: Int32) throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              let count = Int(exactly: info.st_size) else { throw Failure.unsafePath }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let readCount = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
                if readCount < 0, errno == EINTR { continue }
                guard readCount >= 0 else { throw posixError() }
                guard readCount > 0 else { throw Failure.damagedObject }
                offset += readCount
            }
        }
        var extra: UInt8 = 0
        var tail: Int
        repeat { tail = Darwin.read(fd, &extra, 1) } while tail < 0 && errno == EINTR
        guard tail >= 0 else { throw posixError() }
        guard tail == 0 else { throw Failure.damagedObject }
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
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
