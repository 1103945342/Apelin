import ApelinCore
import Darwin
import Foundation

/// What the page does to the file system.
///
/// Every step asks the policy again on the paths as they are now — the page's
/// own state is never taken as permission, and a symbolic link is judged by
/// where it leads at the moment of the change. Nothing here recurses on its
/// own or follows a path it did not build.
enum FileBrowserOperations {
    // MARK: - Names

    /// The name a row or a typed name may have: one component, nothing that
    /// leaves the folder, nothing that names nothing at all.
    static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !CanonicalPath.containsNUL(trimmed),
              !trimmed.contains("/"), !trimmed.contains(":"),
              trimmed != ".", trimmed != ".."
        else { throw FileBrowserFailure.invalidName }
        return trimmed
    }

    /// Why the name cannot be used in `directory`, nil when it can. The place
    /// is asked too, so a record says where it is managed before anything is
    /// typed.
    static func check(name: String, in directory: URL, policy: FileBrowserPolicy) -> FileBrowserFailure? {
        do {
            _ = try destination(named: name, in: directory, policy: policy)
            return nil
        } catch let failure as FileBrowserFailure {
            return failure
        } catch {
            return FileBrowserListing.failure(error)
        }
    }

    /// `name 2`, `name 3`… for a name the folder already holds, as Finder
    /// does. A hidden file keeps its name and takes the number: `.env` becomes
    /// `.env 2`.
    static func uniqueName(for name: String, in directory: URL) -> String {
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        guard existing.contains(name) else { return name }
        let pathExtension = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for index in 2 ... 10000 {
            let candidate = pathExtension.isEmpty ? "\(name) \(index)" : "\(stem) \(index).\(pathExtension)"
            if !existing.contains(candidate) { return candidate }
        }
        return name
    }

    // MARK: - Making

    @discardableResult
    static func createFile(named name: String, in directory: URL, policy: FileBrowserPolicy) throws -> URL {
        let target = try destination(named: name, in: directory, policy: policy)
        do {
            try Data().write(to: target, options: .withoutOverwriting)
        } catch { throw FileBrowserListing.failure(error) }
        return target
    }

    @discardableResult
    static func createFolder(named name: String, in directory: URL, policy: FileBrowserPolicy) throws -> URL {
        let target = try destination(named: name, in: directory, policy: policy)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch { throw FileBrowserListing.failure(error) }
        return target
    }

    // MARK: - Changing

    /// Renames an entry where it sits. A link is renamed as the name in its
    /// folder; what it leads to never moves, and is not written through.
    @discardableResult
    static func rename(_ url: URL, to name: String, policy: FileBrowserPolicy) throws -> URL {
        let source = url.path
        guard !CanonicalPath.containsNUL(source) else { throw FileBrowserFailure.invalidName }
        // A link that leads nowhere is still a name here, and one a new name
        // must not be allowed to take.
        guard FileBrowserPolicy.exists(source) else { throw FileBrowserFailure.missing }
        let holder = URL(fileURLWithPath: (source as NSString).deletingLastPathComponent, isDirectory: true)
        let folder = try canonical(holder)
        let trimmed = try validName(name)
        // Three places are asked: the entry itself, judged by where it leads;
        // the folder it sits in; and the folder the new name lands in — the
        // same one, asked on the resolved path so a link in the way is not
        // followed on trust.
        try require(policy.access(to: URL(fileURLWithPath: source)))
        try require(policy.access(toCreateIn: holder))
        try require(policy.access(toCreateIn: folder))
        let target = folder.appendingPathComponent(trimmed)
        guard target.path != source else { return url }
        guard !FileBrowserPolicy.exists(target.path) else { throw FileBrowserFailure.exists }
        do {
            try FileManager.default.moveItem(atPath: source, toPath: target.path)
        } catch { throw FileBrowserListing.failure(error) }
        return target
    }

    @discardableResult
    static func copy(_ url: URL, into directory: URL, policy: FileBrowserPolicy) throws -> URL {
        try transfer(url, into: directory, moving: false, policy: policy)
    }

    @discardableResult
    static func move(_ url: URL, into directory: URL, policy: FileBrowserPolicy) throws -> URL {
        try transfer(url, into: directory, moving: true, policy: policy)
    }

    /// Removes the entry itself: a symbolic link goes, and what it pointed at
    /// stays.
    static func remove(_ url: URL, policy: FileBrowserPolicy) throws {
        guard !CanonicalPath.containsNUL(url.path) else { throw FileBrowserFailure.invalidName }
        guard let effective = FileBrowserPolicy.effectivePath(of: url) else { throw FileBrowserFailure.missing }
        guard effective.path != "/" else { throw FileBrowserFailure.atRoot }
        try require(policy.access(to: url))
        do {
            try FileManager.default.removeItem(atPath: url.path)
        } catch { throw FileBrowserListing.failure(error) }
    }

    // MARK: - Behind them

    private static func transfer(
        _ url: URL,
        into directory: URL,
        moving: Bool,
        policy: FileBrowserPolicy
    ) throws -> URL {
        guard let effective = FileBrowserPolicy.effectivePath(of: url) else { throw FileBrowserFailure.missing }
        let folder = try canonical(directory)
        if moving {
            // Moving changes where the entry came from, so that place has to
            // allow it. Copying only reads: a record's file, or one mobile may
            // not write, is still the reader's to copy out.
            try require(policy.access(to: url))
        }
        try require(policy.access(toCreateIn: folder))
        // A folder cannot go inside itself: the move would delete its own new
        // home as it went.
        if CanonicalPath.isCanonical(folder.path, inside: effective.path) {
            throw FileBrowserFailure.insideItself
        }
        let name = uniqueName(for: (url.path as NSString).lastPathComponent, in: folder)
        let target = folder.appendingPathComponent(name)
        do {
            if moving {
                try FileManager.default.moveItem(at: url, to: target)
            } else {
                try FileManager.default.copyItem(at: url, to: target)
            }
        } catch { throw FileBrowserListing.failure(error) }
        return target
    }

    /// The folder a change lands in: it must be a folder, and it must be the
    /// one it resolves to, so a link is followed once and the change is made
    /// where the reader sees it.
    private static func canonical(_ directory: URL) throws -> URL {
        guard !CanonicalPath.containsNUL(directory.path) else { throw FileBrowserFailure.invalidName }
        var metadata = stat()
        guard stat(directory.path, &metadata) == 0 else { throw FileBrowserListing.failure(errno) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw FileBrowserFailure.notADirectory }
        guard let resolved = CanonicalPath.resolve(directory.path) else { throw FileBrowserFailure.notPermitted }
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    /// A place that takes no new entry gets a target only after it was asked.
    private static func destination(
        named name: String,
        in directory: URL,
        policy: FileBrowserPolicy
    ) throws -> URL {
        let folder = try canonical(directory)
        let trimmed = try validName(name)
        try require(policy.access(toCreateIn: folder))
        let target = folder.appendingPathComponent(trimmed)
        // `lstat`, so a link that leads nowhere still holds its name.
        guard !FileBrowserPolicy.exists(target.path) else { throw FileBrowserFailure.exists }
        return target
    }

    private static func require(_ access: FileBrowserAccess) throws {
        switch access {
        case .writable: return
        case let .readOnly(reason): throw FileBrowserFailure.readOnly(reason)
        case let .record(record): throw FileBrowserFailure.record(record)
        }
    }
}
