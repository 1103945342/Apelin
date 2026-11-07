import Compression
import Darwin
import Foundation

/// A zip, read here rather than through libarchive: the daemon links no
/// third-party code (`AGENTS.md`), and an `.ipa` is a zip of `Payload/…`.
///
/// Store and deflate only — what an Xcode build writes into an `.ipa`; a
/// member compressed any other way is named in the failure, never guessed
/// at. Every entry is checked before a byte is written: a name that is
/// absolute, holds `..`, a NUL or a backslash, a link, a device, or a size
/// past the caller's limits stops the whole extraction rather than landing
/// half an app on the device.
enum ZipExtractor {
    struct Limits: Sendable {
        var maximumEntries = 20_000
        var maximumEntryBytes: Int64 = 1 << 30
        var maximumTotalBytes: Int64 = 8 << 30
        var maximumNameBytes = 1024
        var maximumDepth = 24
    }

    /// One member, as the central directory described it.
    struct Entry: Sendable, Equatable {
        /// Relative, `/`-separated, no `.` or `..` component.
        var path: String
        var isDirectory: Bool
        /// The mode bits in the archive's external attributes; `0o644` when
        /// the writer recorded none.
        var mode: UInt16
        var size: Int64
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notAZip
        case truncated
        /// A shape this reader does not take: zip64, another compression,
        /// an encrypted member.
        case unsupported(String)
        case unsafeEntry(String)
        case tooLarge(String)
        case corrupt(String)
        case io(String)

        var description: String {
            switch self {
            case .notAZip: "the file is not a zip"
            case .truncated: "the zip ends before its directory"
            case let .unsupported(what): "the zip uses \(what), which this build does not read"
            case let .unsafeEntry(entry): "the zip holds \(entry), which would land outside the folder it is unpacked into"
            case let .tooLarge(what): "the zip holds \(what), past the size this can unpack"
            case let .corrupt(entry): "\(entry) does not unpack to the bytes the zip promises"
            case let .io(message): message
            }
        }
    }

    /// Unpacks every member of `archive` into `directory`, which must already
    /// exist. Answers what it wrote, in the order the directory lists it.
    @discardableResult
    static func extract(
        _ archive: URL,
        into directory: URL,
        limits: Limits = Limits()
    ) throws -> [Entry] {
        let data: Data
        do {
            data = try Data(contentsOf: archive, options: .mappedIfSafe)
        } catch {
            throw Failure.io("\(archive.lastPathComponent) could not be read")
        }
        let records = try centralDirectory(data, limits: limits)
        var written: [Entry] = []
        var total: Int64 = 0
        for record in records {
            guard let entry = try write(record, of: data, into: directory, limits: limits) else { continue }
            total += entry.size
            guard total <= limits.maximumTotalBytes else {
                throw Failure.tooLarge("more than \(limits.maximumTotalBytes >> 20) MiB of files")
            }
            written.append(entry)
        }
        return written
    }

    // MARK: The central directory

    private struct Record {
        var name: String
        var isDirectory: Bool
        var mode: UInt16
        var method: UInt16
        var crc32: UInt32
        var compressedSize: Int64
        var size: Int64
        var localOffset: Int64
        var flags: UInt16
    }

    private static func centralDirectory(_ data: Data, limits: Limits) throws -> [Record] {
        // The end record is in the last 22 bytes plus a comment of up to 64 KiB.
        guard data.count >= 22 else { throw Failure.notAZip }
        let window = min(data.count, 22 + 0xFFFF)
        guard let end = endRecord(data, from: data.count - window), end.signatureOK else {
            throw Failure.notAZip
        }
        guard end.totalEntries == end.diskEntries, end.thisDisk == 0, end.directoryDisk == 0 else {
            throw Failure.unsupported("a split archive")
        }
        guard end.totalEntries <= UInt64(limits.maximumEntries) else {
            throw Failure.tooLarge("more than \(limits.maximumEntries) entries")
        }
        let directoryEnd = Int64(end.directoryOffset) + Int64(end.directoryBytes)
        guard directoryEnd <= Int64(data.count) else { throw Failure.truncated }

        var records: [Record] = []
        records.reserveCapacity(Int(end.totalEntries))
        var offset = Int64(end.directoryOffset)
        for _ in 0 ..< end.totalEntries {
            guard let record = try centralRecord(data, at: offset, limits: limits) else { throw Failure.truncated }
            records.append(record.record)
            offset = record.next
        }
        return records
    }

    private struct EndRecord {
        var signatureOK = false
        var thisDisk: UInt16 = 0
        var directoryDisk: UInt16 = 0
        var diskEntries: UInt64 = 0
        var totalEntries: UInt64 = 0
        var directoryBytes: UInt32 = 0
        var directoryOffset: UInt32 = 0
    }

    private static func endRecord(_ data: Data, from start: Int) -> EndRecord? {
        var found: EndRecord?
        var index = data.count - 22
        while index >= max(start, 0) {
            if data.at(index, is: 0x0605_4B50) {
                var record = EndRecord()
                record.signatureOK = true
                record.thisDisk = read16(data, index + 4) ?? 0
                record.directoryDisk = read16(data, index + 6) ?? 0
                record.diskEntries = UInt64(read16(data, index + 8) ?? 0)
                record.totalEntries = UInt64(read16(data, index + 10) ?? 0)
                record.directoryBytes = read32(data, index + 12) ?? 0
                record.directoryOffset = read32(data, index + 16) ?? 0
                // zip64 writes 0xFFFF/0xFFFFFFFF here: not read by this build.
                guard record.totalEntries != 0xFFFF, record.directoryOffset != 0xFFFF_FFFF else {
                    found = EndRecord(signatureOK: false)
                    break
                }
                found = record
                break
            }
            index -= 1
        }
        return found
    }

    private static func centralRecord(
        _ data: Data,
        at offset: Int64,
        limits: Limits
    ) throws -> (record: Record, next: Int64)? {
        guard offset >= 0, offset + 46 <= Int64(data.count) else { return nil }
        let at = Int(offset)
        guard data.at(at, is: 0x0201_4B50) else { return nil }
        let flags = read16(data, at + 8) ?? 0
        let method = read16(data, at + 10) ?? 0
        let crc32 = read32(data, at + 16) ?? 0
        let compressedSize = Int64(read32(data, at + 20) ?? 0)
        let size = Int64(read32(data, at + 24) ?? 0)
        let nameBytes = Int(read16(data, at + 28) ?? 0)
        let extraBytes = Int(read16(data, at + 30) ?? 0)
        let commentBytes = Int(read16(data, at + 32) ?? 0)
        let external = read32(data, at + 38) ?? 0
        let localOffset = Int64(read32(data, at + 42) ?? 0)
        let next = offset + 46 + Int64(nameBytes + extraBytes + commentBytes)
        guard nameBytes > 0, nameBytes <= limits.maximumNameBytes, next <= Int64(data.count),
              at + 46 + nameBytes <= data.count
        else { return nil }
        guard compressedSize != Int64(UInt32.max), size != Int64(UInt32.max), localOffset != Int64(UInt32.max)
        else {
            throw Failure.unsupported("zip64")
        }
        guard flags & 0x0001 == 0 else { throw Failure.unsupported("an encrypted member") }
        let name = String(decoding: data[(at + 46) ..< (at + 46 + nameBytes)], as: UTF8.self)
        guard !name.isEmpty, !name.contains("\0"), nameBytes == name.utf8.count else {
            throw Failure.unsafeEntry("a name that is not UTF-8")
        }
        let path = try plainPath(name, isDirectory: name.hasSuffix("/"), limits: limits)
        let unixMode = UInt16((external >> 16) & 0xFFFF)
        switch unixMode & 0o170_000 {
        case 0o120_000: throw Failure.unsupported("a link: \(path)")
        case 0o020_000, 0o060_000, 0o010_000, 0o140_000: throw Failure.unsupported("a device: \(path)")
        default: break
        }
        let isDirectory = name.hasSuffix("/") || unixMode & 0o170_000 == 0o040_000
        guard compressedSize >= 0, size >= 0 else { throw Failure.corrupt(path) }
        guard size <= limits.maximumEntryBytes else {
            throw Failure.tooLarge("\(path), larger than \(limits.maximumEntryBytes >> 20) MiB")
        }
        let record = Record(
            name: path,
            isDirectory: isDirectory,
            mode: unixMode & 0o777 == 0 ? (isDirectory ? 0o755 : 0o644) : unixMode & 0o777,
            method: method,
            crc32: crc32,
            compressedSize: compressedSize,
            size: size,
            localOffset: localOffset,
            flags: flags
        )
        return (record, next)
    }

    /// `Payload/StarRoom.app/Info.plist` → the same, with every component
    /// checked; answers the path it writes.
    private static func plainPath(_ name: String, isDirectory: Bool, limits: Limits) throws -> String {
        let trimmed = isDirectory ? String(name.dropLast()) : name
        guard !trimmed.hasPrefix("/") else { throw Failure.unsafeEntry(name) }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= limits.maximumDepth else { throw Failure.unsafeEntry(name) }
        for component in components {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("\\") else {
                throw Failure.unsafeEntry(name)
            }
        }
        return trimmed
    }

    // MARK: Writing

    private static func write(
        _ record: Record,
        of data: Data,
        into directory: URL,
        limits: Limits
    ) throws -> Entry? {
        guard record.localOffset >= 0, record.localOffset + 30 <= Int64(data.count) else { return nil }
        let header = Int(record.localOffset)
        guard data.at(header, is: 0x0403_4B50) else { return nil }
        let nameBytes = Int(read16(data, header + 26) ?? 0)
        let extraBytes = Int(read16(data, header + 28) ?? 0)
        let start = header + 30 + nameBytes + extraBytes
        guard start >= 0, record.compressedSize >= 0, record.compressedSize <= Int64(data.count - start) else {
            throw Failure.truncated
        }
        let end = start + Int(record.compressedSize)
        guard end <= data.count else { throw Failure.truncated }

        let destination = directory.appendingPathComponent(record.name)
        if record.isDirectory {
            try makeDirectory(destination)
            return Entry(path: record.name, isDirectory: true, mode: record.mode, size: 0)
        }
        let payload = try bytes(record, data[start ..< end])
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw Failure.io("\(record.name): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        try payload.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw Failure.io("\(record.name): \(String(cString: strerror(errno)))")
                }
                written += count
            }
        }
        guard fchmod(descriptor, mode_t(record.mode | 0o400)) == 0 else {
            throw Failure.io("\(record.name): \(String(cString: strerror(errno)))")
        }
        return Entry(path: record.name, isDirectory: false, mode: record.mode, size: record.size)
    }

    private static func makeDirectory(_ url: URL) throws {
        var metadata = stat()
        if stat(url.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw Failure.unsafeEntry(url.lastPathComponent)
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } catch {
            throw Failure.io("\(url.lastPathComponent) could not be made")
        }
    }

    /// A member's own bytes, and the CRC the directory promised for them.
    private static func bytes(_ record: Record, _ compressed: Data) throws -> Data {
        let payload: Data
        switch record.method {
        case 0:
            guard Int64(compressed.count) == record.size else { throw Failure.corrupt(record.name) }
            payload = compressed
        case 8:
            payload = try inflate(compressed, size: Int(record.size), entry: record.name)
        default:
            throw Failure.unsupported("compression method \(record.method)")
        }
        guard payload.count == Int(record.size), CRC32.of(payload) == record.crc32 else {
            throw Failure.corrupt(record.name)
        }
        return payload
    }

    private static func inflate(_ compressed: Data, size: Int, entry: String) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written: Int = try output.withUnsafeMutableBytes { destination in
            try compressed.withUnsafeBytes { source in
                guard let from = source.bindMemory(to: UInt8.self).baseAddress,
                      let to = destination.bindMemory(to: UInt8.self).baseAddress
                else { throw Failure.corrupt(entry) }
                let count = compression_decode_buffer(
                    to, size,
                    from, source.count,
                    nil, COMPRESSION_ZLIB
                )
                guard count == size else { throw Failure.corrupt(entry) }
                return count
            }
        }
        guard written == size else { throw Failure.corrupt(entry) }
        return output
    }

    // MARK: Little-endian reads

    private static func read16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private extension Data {
    func at(_ offset: Int, is signature: UInt32) -> Bool {
        guard offset >= 0, offset + 4 <= count else { return false }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
            == signature
    }
}

/// The CRC-32 a zip stores for every member.
enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func of<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
