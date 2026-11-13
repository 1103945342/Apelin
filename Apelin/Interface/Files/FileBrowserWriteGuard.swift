import ApelinCore
import CryptoKit
import Darwin
import Foundation

/// The guard the browser hands the editor it opened a file with.
///
/// It holds no page: what it knows is the policy and the file as it was when
/// the editor opened it — where the path led, which file was there and what
/// bytes it held. That is why it is a value of its own rather than a call back
/// into the browser: a guard that answered nil because its page was closed
/// would let the write through.
///
/// It is asked twice: on the page, before the pencil turns the file writable,
/// and again inside the editor's write itself, immediately before the atomic
/// replace — where the answer and the write are one step apart. Every refusal
/// is a refusal to write: the reader's typing stays in the editor.
///
/// What it cannot do is make the check part of the write. `ProjectFileContent`
/// replaces the file by renaming a temporary over it, and between the check and
/// that rename there is an interval only the operating system could close —
/// this is a last-moment check, not descriptor-level isolation, and it is not
/// offered as one. What it does close is everything a page could otherwise
/// miss: a link re-aimed, a file replaced, a path that now leads into one of
/// Apelin's records, and an edit written in place — of any length, even one
/// whose modification time was put back afterwards, because the bytes
/// themselves are compared.
///
/// It is asked off the main thread by the editor's writer, and updated on the
/// main thread after its own save, so its two pieces of state are read and
/// written under a lock.
final class FileBrowserWriteGuard: @unchecked Sendable {
    /// Which file a path led to, at one moment, and how big it was then.
    struct Identity: Equatable {
        /// Where `realpath` answered: a link is known by its target.
        var path: String
        var device: UInt64
        var inode: UInt64
        var byteCount: Int64
        /// Modification time in nanoseconds.
        var modified: Int64
    }

    /// Past this a file is not hashed: the editor does not open one this large,
    /// and a digest it cannot take is treated as a change it cannot account
    /// for.
    private static let maximumDigestByteCount = 8 * 1024 * 1024

    private let url: URL
    private let policy: FileBrowserPolicy
    private let lock = NSLock()
    /// The file as the editor found it, and as the editor's own last save left
    /// it: a save replaces the file, and the one to expect is the one just
    /// written.
    private var expected: Identity?
    /// The bytes it held at that moment, kept so a save compares content and
    /// not merely statistics.
    private var expectedDigest: String?

    init(url: URL, policy: FileBrowserPolicy) {
        self.url = url
        self.policy = policy
        let identity = Self.identity(of: url.path)
        expected = identity
        expectedDigest = identity.flatMap { Self.digest(of: $0.path, byteCount: $0.byteCount) }
    }

    /// Nil when the editor may write, the sentence to show when it may not.
    func refusal() -> String? {
        let expected = snapshot()
        // Where it leads now, and whether it is still the file that was opened.
        guard let current = Self.identity(of: url.path) else {
            // A link that leads nowhere says so; a name with nothing at it is
            // the file having gone since the editor opened it.
            return FileBrowserPolicy.isSymbolicLink(url.path)
                ? FileBrowserReadOnly.brokenLink.sentence
                : String(localized: "This file is no longer there.")
        }
        if let sentence = policy.access(toWriteFile: url).refusal {
            return sentence
        }
        guard let expected else {
            // Nothing was there to open, and a file is now: the name was
            // pointed at one since.
            return String(localized: "This file now leads somewhere else.")
        }
        guard current.path == expected.identity.path else {
            return String(localized: "This file now leads somewhere else.")
        }
        guard current.device == expected.identity.device, current.inode == expected.identity.inode else {
            return String(localized: "This file was replaced by another.")
        }
        // Always the bytes, never only the statistics: an in-place write of the
        // same length with its modification time put back leaves size, time,
        // device and inode exactly as they were, and only content says so.
        guard let digest = Self.digest(of: current.path), digest == expected.digest else {
            return String(localized: "This file changed since it was opened.")
        }
        return nil
    }

    /// The editor's own save finished: what is on disk now is what the next
    /// save expects, or every second save would be refused for the file the
    /// editor itself had just replaced.
    func didSave() {
        let identity = Self.identity(of: url.path)
        let digest = identity.flatMap { Self.digest(of: $0.path, byteCount: $0.byteCount) }
        lock.lock()
        expected = identity
        expectedDigest = digest
        lock.unlock()
    }

    /// The two pieces a check compares against, read together so a save on the
    /// writer's thread and a save that just finished on the main one cannot
    /// interleave into a mix of both.
    private func snapshot() -> (identity: Identity, digest: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let expected else { return nil }
        return (expected, expectedDigest)
    }

    /// The file a path leads to, when it is a regular file. A link is followed
    /// once, and the file behind it is what is named.
    static func identity(of path: String) -> Identity? {
        guard !CanonicalPath.containsNUL(path), let resolved = CanonicalPath.resolve(path) else { return nil }
        var metadata = stat()
        guard stat(resolved, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return Identity(
            path: resolved,
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            byteCount: Int64(metadata.st_size),
            modified: Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_mtimespec.tv_nsec)
        )
    }

    /// The bytes at a path, as a digest; nil for a file too large to read here
    /// or one that cannot be read, which the caller treats as a change it
    /// cannot account for.
    static func digest(of path: String, byteCount: Int64? = nil) -> String? {
        guard let resolved = CanonicalPath.resolve(path) else { return nil }
        let size = byteCount ?? (try? URL(fileURLWithPath: resolved).resourceValues(forKeys: [.fileSizeKey]))?
            .fileSize.map(Int64.init)
        guard let size, size <= maximumDigestByteCount,
              let data = try? Data(contentsOf: URL(fileURLWithPath: resolved), options: .mappedIfSafe),
              data.count <= maximumDigestByteCount
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
