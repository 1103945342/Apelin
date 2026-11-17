import Darwin
import Foundation

/// A project file written through directory descriptors, for a conversation
/// working to a delegation brief. Nothing here is used for an ordinary
/// session: the shared `ScopedRoot.commit` is unchanged.
///
/// Every step is relative to a descriptor: the root is opened once, each
/// directory below it with `openat(O_DIRECTORY | O_NOFOLLOW)`, a missing one
/// made with `mkdirat`, the temporary file created beside the target with
/// `openat(O_CREAT | O_EXCL | O_NOFOLLOW)` and moved into place with
/// `linkat`/`renameat`. A component swapped for a symbolic link after it was
/// opened cannot redirect the write: the descriptor still names the directory
/// that was opened, and the move happens inside it.
///
/// What this cannot prove: if another process moves the opened directory
/// itself out of the project while the write is going, the file lands in that
/// directory wherever it now is. The re-read of the root and of the parent
/// before the move narrows the window to the two syscalls of the move itself,
/// and refuses when either identity changed; it cannot close it. The caller
/// keeps failing closed: an error writes nothing, and the target is never
/// touched except by the one atomic move.
public enum ConfinedWriteError: Error, Equatable, LocalizedError {
    case invalidPath(String)
    case tooLarge(Int)
    case symlink(String)
    case notAFile(String)
    case notADirectory(String)
    case alreadyExists(String)
    case gitDirectory(String)
    case rootChanged(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path): "\(path) is not a plain project-relative path"
        case let .tooLarge(bytes): "the content is \(bytes) bytes, over the confined writer's limit"
        case let .symlink(path): "\(path) is a symbolic link; it is not written through"
        case let .notAFile(path): "\(path) is not a regular file"
        case let .notADirectory(path): "\(path) is not a directory"
        case let .alreadyExists(path): "\(path) already exists"
        case let .gitDirectory(path): "\(path) is in a git directory; the file tools do not write there"
        case let .rootChanged(path): "\(path) changed while the write was going; nothing was written"
        case let .io(message): message
        }
    }
}

public struct ConfinedWriter: Sendable {
    /// The project's canonical root.
    public let rootPath: String
    /// As large as one file may be written; the host checks the same figure.
    public static let maximumBytes = 32 * 1024 * 1024

    /// A test's seam: called once, after the walk and before the root and the
    /// parent are read again, so a check can move a directory away at exactly
    /// that point. Nil in the worker, where nothing calls it.
    var betweenWalkAndCommit: (@Sendable () -> Void)?

    public init(rootPath: String) {
        self.rootPath = rootPath
    }

    /// Writes `data` to the project-relative `path`. `exclusive` creates a
    /// file that must not exist yet; otherwise an existing regular file is
    /// replaced atomically and keeps its mode. On any error nothing at
    /// `path` changes.
    public func write(_ data: Data, to path: String, exclusive: Bool) throws {
        guard data.count <= Self.maximumBytes else { throw ConfinedWriteError.tooLarge(data.count) }
        let components = try Self.components(of: path)
        guard let name = components.last else { throw ConfinedWriteError.invalidPath(path) }
        // The root as the kernel names it: `NSTemporaryDirectory` and a home
        // folder are links themselves on iOS, so the path is resolved once
        // and every descriptor is opened from the resolved one.
        guard let realRoot = Self.canonical(rootPath) else {
            throw ConfinedWriteError.rootChanged(path)
        }

        let rootFD = open(realRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else {
            throw ConfinedWriteError.io("could not open the project root: \(String(cString: strerror(errno)))")
        }
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0 else {
            throw ConfinedWriteError.io("could not read the project root")
        }

        var directoryFD = rootFD
        var opened: [Int32] = []
        defer { for fd in opened.reversed() { close(fd) } }
        for component in components.dropLast() {
            var childFD = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if childFD < 0, errno == ENOENT {
                if mkdirat(directoryFD, component, 0o755) != 0, errno != EEXIST {
                    throw ConfinedWriteError.io("could not create \(component): \(String(cString: strerror(errno)))")
                }
                childFD = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard childFD >= 0 else {
                switch errno {
                case ELOOP: throw ConfinedWriteError.symlink(path)
                case ENOTDIR: throw ConfinedWriteError.notADirectory(path)
                default: throw ConfinedWriteError.io("could not open \(component): \(String(cString: strerror(errno)))")
                }
            }
            opened.append(childFD)
            directoryFD = childFD
        }

        // The root and the parent are read again by path: a directory that
        // was replaced or moved since it was opened is not written into.
        betweenWalkAndCommit?()
        try verify(realRoot: realRoot, rootInfo: rootInfo, directoryFD: directoryFD,
                   components: Array(components.dropLast()), path: path)

        var existing = stat()
        let found = fstatat(directoryFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0
        var mode: mode_t = 0o644
        if found {
            if exclusive { throw ConfinedWriteError.alreadyExists(path) }
            switch existing.st_mode & S_IFMT {
            case S_IFLNK: throw ConfinedWriteError.symlink(path)
            case S_IFREG: mode = existing.st_mode & 0o7777
            default: throw ConfinedWriteError.notAFile(path)
            }
        }

        let temporary = ".\(name).apelin-\(UUID().uuidString)"
        let fd = openat(
            directoryFD,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode,
        )
        guard fd >= 0 else {
            throw ConfinedWriteError.io("could not write \(path): \(String(cString: strerror(errno)))")
        }
        var placed = false
        defer {
            if !placed { unlinkat(directoryFD, temporary, 0) }
        }
        do {
            try Self.writeAll(fd, data)
            if fchmod(fd, mode) != 0 {
                throw ConfinedWriteError.io("could not set the mode of \(path)")
            }
            fsync(fd)
        } catch {
            close(fd)
            throw error
        }
        close(fd)

        if exclusive {
            // link(2) fails when the name exists, so creation stays exclusive.
            if linkat(directoryFD, temporary, directoryFD, name, 0) != 0 {
                let number = errno
                if number == EEXIST { throw ConfinedWriteError.alreadyExists(path) }
                throw ConfinedWriteError.io("could not create \(path): \(String(cString: strerror(number)))")
            }
            unlinkat(directoryFD, temporary, 0)
        } else if renameat(directoryFD, temporary, directoryFD, name) != 0 {
            throw ConfinedWriteError.io("could not replace \(path): \(String(cString: strerror(errno)))")
        }
        placed = true
    }

    // MARK: - Steps

    /// The path as plain components: no absolute path, no `.` or `..`, no
    /// `.git`, no empty component, no NUL.
    static func components(of path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 4096,
              !path.contains("\0"), !path.hasPrefix("/") else {
            throw ConfinedWriteError.invalidPath(path)
        }
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != "..",
                  component != ".git", component.utf8.count <= 255 else {
                if component == ".git" { throw ConfinedWriteError.gitDirectory(path) }
                throw ConfinedWriteError.invalidPath(path)
            }
            components.append(String(component))
        }
        guard !components.isEmpty else { throw ConfinedWriteError.invalidPath(path) }
        return components
    }

    /// Opens the root and the parent again by path and compares their
    /// identities with the descriptors held.
    private func verify(realRoot: String, rootInfo: stat, directoryFD: Int32, components: [String], path: String) throws {
        guard let real = Self.canonical(rootPath), real == realRoot else {
            throw ConfinedWriteError.rootChanged(path)
        }
        let fresh = open(realRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fresh >= 0 else { throw ConfinedWriteError.rootChanged(path) }
        defer { close(fresh) }
        var freshRoot = stat()
        guard fstat(fresh, &freshRoot) == 0,
              freshRoot.st_dev == rootInfo.st_dev, freshRoot.st_ino == rootInfo.st_ino else {
            throw ConfinedWriteError.rootChanged(path)
        }
        var current = fresh
        var opened: [Int32] = []
        defer { for fd in opened.reversed() { close(fd) } }
        for component in components {
            let child = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ConfinedWriteError.rootChanged(path) }
            opened.append(child)
            current = child
        }
        var held = stat()
        var reached = stat()
        guard fstat(directoryFD, &held) == 0, fstat(current, &reached) == 0,
              held.st_dev == reached.st_dev, held.st_ino == reached.st_ino else {
            throw ConfinedWriteError.rootChanged(path)
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 {
                    throw ConfinedWriteError.io("could not write the file: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
    }

    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
