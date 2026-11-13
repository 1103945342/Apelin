import ApelinCore
import Darwin
import Foundation

/// One row: a folder, a file, or a link and where it leads.
struct FileBrowserEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case file
        /// A symbolic link, resolved: nil when its target does not resolve.
        case link(target: String?)
    }

    /// The entry as it sits in the folder that was read.
    var url: URL
    var name: String
    var kind: Kind
    /// A file's size; nil for a folder and for a link.
    var byteCount: Int64?
    var modified: Date?

    var isLink: Bool {
        if case .link = kind { return true }
        return false
    }

    /// Whether opening it lands in a folder. A link is followed to its target,
    /// which is what a tap on it does too.
    var opensAsDirectory: Bool {
        switch kind {
        case .directory:
            return true
        case .file:
            return false
        case let .link(target):
            guard let target else { return false }
            var metadata = stat()
            return stat(target, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR
        }
    }

    /// A name the page shows as hidden, as every file browser does — and shows
    /// all the same: what is here is here.
    var isHidden: Bool {
        name.hasPrefix(".")
    }
}

/// A folder, read a directory at a time.
///
/// Never a walk: what a page shows is what one folder holds, and a project can
/// hold a `node_modules` or a build folder with more entries than anything
/// should read to draw a screen. The listing runs off the main thread; the disk
/// is asked once per place the reader opens.
enum FileBrowserListing {
    /// The rows of one folder, sorted the way every file browser sorts:
    /// folders first, then by name.
    static func list(_ directory: URL) -> Result<[FileBrowserEntry], FileBrowserFailure> {
        let path = directory.path
        guard !CanonicalPath.containsNUL(path) else { return .failure(.invalidName) }
        var metadata = stat()
        guard stat(path, &metadata) == 0 else { return .failure(failure(errno)) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return .failure(.notADirectory) }

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            return .failure(failure(error))
        }
        var entries: [FileBrowserEntry] = []
        for name in names {
            // A name that would leave the folder is never one: it came from
            // the file system, and nothing here follows a path it did not
            // build itself.
            guard name != ".", name != "..", !name.contains("/"), !CanonicalPath.containsNUL(name) else { continue }
            let url = directory.appendingPathComponent(name)
            var info = stat()
            // Gone since the listing was made: one entry fewer, not a broken
            // page.
            guard lstat(url.path, &info) == 0 else { continue }
            let modified = Date(
                timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                    + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            if info.st_mode & S_IFMT == S_IFLNK {
                entries.append(FileBrowserEntry(
                    url: url,
                    name: name,
                    kind: .link(target: CanonicalPath.resolve(url.path)),
                    byteCount: nil,
                    modified: modified
                ))
                continue
            }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            entries.append(FileBrowserEntry(
                url: url,
                name: name,
                kind: isDirectory ? .directory : .file,
                byteCount: isDirectory ? nil : Int64(info.st_size),
                modified: modified
            ))
        }
        return .success(entries.sorted { left, right in
            if left.opensAsDirectory != right.opensAsDirectory { return left.opensAsDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        })
    }

    /// Why a path that looked like a folder cannot be opened as one: a link
    /// that leads nowhere, a name nothing is at, or a refusal the kernel made.
    /// A link is followed first, because what the reader tapped is where it
    /// leads.
    static func openReason(for url: URL) -> FileBrowserFailure {
        if FileBrowserPolicy.isSymbolicLink(url.path), CanonicalPath.resolve(url.path) == nil {
            return .brokenLink
        }
        var metadata = stat()
        guard stat(url.path, &metadata) == 0 else { return failure(errno) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return .notADirectory }
        // It is a folder and it would not open: the kernel's own refusal.
        return .notPermitted
    }

    /// A POSIX error as the page names it.
    static func failure(_ code: Int32) -> FileBrowserFailure {
        switch code {
        case ENOENT: .missing
        case ENOTDIR: .notADirectory
        case EACCES, EPERM: .notPermitted
        case ELOOP: .brokenLink
        case ENAMETOOLONG, EINVAL: .invalidName
        default: .failed(String(cString: strerror(code)))
        }
    }

    /// Foundation's error as the page names it. The codes it carries for the
    /// two answers a reader meets every day are mapped; anything else keeps
    /// the system's own sentence.
    static func failure(_ error: Error) -> FileBrowserFailure {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return .missing
            case .fileReadNoPermission, .fileWriteNoPermission: return .notPermitted
            default: break
            }
        }
        return .failed((error as NSError).localizedDescription)
    }
}
