internal import GitKit
import Darwin
import Foundation

/// Where a restore takes a file's contents from.
public enum GitRestoreSource: Sendable, Equatable {
    /// HEAD's version, which also drops what the index holds for the path.
    case head
    /// The index's version: the work-tree change goes, the staged one stays.
    case index
}

/// How far a reset moves.
public enum GitResetMode: Sendable, Equatable {
    /// The branch moves; the index and the work tree stay as they are.
    case soft
    /// The branch and the index move; the work tree stays.
    case mixed
}

/// One stash, as the stash list shows it.
public struct GitStashEntry: Sendable, Equatable {
    /// `0` for `stash@{0}`, the newest.
    public var index: Int
    /// The reader's message, or the subject git wrote for it.
    public var message: String
    /// The branch it was saved on.
    public var branch: String
    public var commit: String

    public init(index: Int, message: String, branch: String, commit: String) {
        self.index = index
        self.message = message
        self.branch = branch
        self.commit = commit
    }
}

/// The four ways the status page takes a change back — restore a file from
/// HEAD or the index, delete what git is not tracking yet, add a pattern to
/// the repository's own ignore rules — and the two that move a branch:
/// a reset and a stash.
///
/// None of them touches what a commit holds. A restore is refused for a path
/// git is not tracking, and a delete for one it is.
public extension GitRepository {
    // MARK: Restore and delete

    /// Puts each path back to `source`, matched literally and overwriting
    /// what is there; a path the index does not hold at all is `notTracked`.
    func restore(_ paths: [String], from source: GitRestoreSource) throws {
        let paths = try Self.checked(paths)
        guard !paths.isEmpty else { throw GitError(.invalid, "no paths") }
        try requireTracked(paths)
        let commit = try headCommitObject()
        defer { git_commit_free(commit) }
        switch source {
        case .head:
            if let commit {
                try Self.withStrings(paths) { pathspec in
                    var options = git_checkout_options()
                    git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
                    options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
                        | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
                    options.paths = pathspec
                    try GitError.check(git_checkout_tree(pointer, commit, &options), "restore")
                }
            }
            // The index goes back to HEAD's version of the paths too, so the
            // restore is not left half of it: a path HEAD has never held is
            // taken out of the index, and shows as untracked.
            try Self.withStrings(paths) { pathspec in
                var spec = pathspec
                try GitError.check(git_reset_default(pointer, commit, &spec), "unstage the restored paths")
            }
        case .index:
            var index: OpaquePointer?
            try GitError.check(git_repository_index(&index, pointer), "read the index")
            guard let index else { throw GitError(.failed, "the repository has no index") }
            defer { git_index_free(index) }
            try Self.withStrings(paths) { pathspec in
                var options = git_checkout_options()
                git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
                options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
                    | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
                options.paths = pathspec
                try GitError.check(git_checkout_index(pointer, index, &options), "restore from the index")
            }
        }
    }

    /// Removes each path from the work tree, a folder with everything below
    /// it, without following a link out of the project. A path the index
    /// holds — or one above a path it holds — is `tracked`: a deletion is
    /// only ever of what git is not keeping.
    func deleteUntracked(_ paths: [String]) throws {
        let paths = try Self.checked(paths)
        guard !paths.isEmpty else { throw GitError(.invalid, "no paths") }
        try requireUntracked(paths)
        var removed: [String] = []
        // A path below another of them goes with it.
        for path in paths.sorted(by: { $0.count < $1.count }) {
            if removed.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            try removeFromWorkTree(path)
            removed.append(path)
        }
    }

    // MARK: Ignore rules

    /// Appends `pattern` as one line of the work tree's `.gitignore`,
    /// making the file when it is not there; answers whether it was added,
    /// which it is not when the line is already one of them.
    func appendIgnore(_ pattern: String) throws -> Bool {
        guard !pattern.isEmpty else { throw GitError(.invalid, "the pattern is empty") }
        guard !pattern.hasPrefix("/") else {
            throw GitError(.invalid, "\(pattern.debugDescription) is an absolute path: give a pattern")
        }
        guard !pattern.contains("\n"), !pattern.contains("\r"), !pattern.utf8.contains(0) else {
            throw GitError(.invalid, "a pattern is one line")
        }
        let file = workdir.appendingPathComponent(".gitignore")
        var text = ""
        if let existing = FileManager.default.contents(atPath: file.path) {
            guard let decoded = String(data: existing, encoding: .utf8) else {
                throw GitError(.invalid, ".gitignore is not text")
            }
            text = decoded
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.contains(pattern) else { return false }
        if !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        text += pattern + "\n"
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw GitError(.failed, "write .gitignore: \(error)")
        }
        return true
    }

    // MARK: Reset

    /// Moves HEAD's branch to `commit`, matched as `git commitID` resolves
    /// it: `soft` leaves the index and the work tree, `mixed` sets the index
    /// to the commit's tree. Answers the commit the branch now points at.
    @discardableResult
    func reset(to commit: String, mode: GitResetMode) throws -> String {
        let id = try commitID(commit)
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, id), "read \(commit)")
        var object: OpaquePointer?
        try GitError.check(git_object_lookup(&object, pointer, &oid, GIT_OBJECT_COMMIT), "read \(commit)")
        guard let object else { throw GitError(.notFound, "no commit \(commit)") }
        defer { git_object_free(object) }
        try GitError.check(
            git_reset(pointer, object, mode == .soft ? GIT_RESET_SOFT : GIT_RESET_MIXED, nil),
            "reset to \(commit)"
        )
        return id
    }

    // MARK: Stashes

    /// Every stash, newest first, each with what it was saved with and the
    /// branch it was saved on.
    func stashList() throws -> [GitStashEntry] {
        let collector = StashCollector()
        let code = withExtendedLifetime(collector) {
            git_stash_foreach(pointer, { index, _, oid, payload in
                guard let payload, let oid else { return 0 }
                let collector = Unmanaged<StashCollector>.fromOpaque(payload).takeUnretainedValue()
                collector.add(index: Int(index), commit: GitRepository.hex(oid))
                return 0
            }, Unmanaged.passUnretained(collector).toOpaque())
        }
        try GitError.check(code, "list the stashes")
        return try collector.entries.map { entry in
            try stashEntry(index: entry.index, commit: entry.commit)
        }
    }

    /// Puts the work tree's and the index's changes aside as a new stash,
    /// named by `message` when there is one. Answers whether there was
    /// anything to save.
    func stashSave(message: String?, includeUntracked: Bool, author: GitSignature?) throws -> Bool {
        guard let author else {
            throw GitError(.invalid, "a stash needs an author: set one in Settings ▸ Git")
        }
        var signature: UnsafeMutablePointer<git_signature>?
        try GitError.check(git_signature_now(&signature, author.name, author.email), "make the signature")
        defer { git_signature_free(signature) }
        let flags = includeUntracked ? GIT_STASH_INCLUDE_UNTRACKED.rawValue : 0
        var oid = git_oid()
        let code: Int32
        if let message {
            code = message.withCString { git_stash_save(&oid, pointer, signature, $0, flags) }
        } else {
            code = git_stash_save(&oid, pointer, signature, nil, flags)
        }
        // Nothing to put aside is no failure, and no stash either.
        if code == GIT_ENOTFOUND.rawValue { return false }
        try GitError.check(code, "save the stash")
        return true
    }

    /// Applies one stash. Answers the paths it conflicted on; with `pop`,
    /// drops it once it went on cleanly — a conflicted one is kept, as git
    /// keeps it.
    func stashApply(_ index: Int, pop: Bool) throws -> [String] {
        guard index >= 0 else { throw GitError(.notFound, "no stash@{\(index)}") }
        let code = git_stash_apply(pointer, index, nil)
        if code == GIT_ENOTFOUND.rawValue {
            throw GitError(.notFound, "no stash@{\(index)}")
        }
        if code != 0, code != GIT_EMERGECONFLICT.rawValue {
            throw GitError.last(code, "apply stash@{\(index)}")
        }
        var conflicts: [String] = []
        var handle: OpaquePointer?
        if git_repository_index(&handle, pointer) == 0, let handle {
            conflicts = Self.conflictPaths(handle)
            git_index_free(handle)
        }
        if code == GIT_EMERGECONFLICT.rawValue, conflicts.isEmpty {
            throw GitError(.conflict, "stash@{\(index)} does not apply cleanly: what is in the way would be lost")
        }
        if pop, conflicts.isEmpty {
            try stashDrop(index)
        }
        return conflicts
    }

    /// Drops one stash from the list.
    func stashDrop(_ index: Int) throws {
        guard index >= 0 else { throw GitError(.notFound, "no stash@{\(index)}") }
        let code = git_stash_drop(pointer, index)
        if code == GIT_ENOTFOUND.rawValue {
            throw GitError(.notFound, "no stash@{\(index)}")
        }
        try GitError.check(code, "drop stash@{\(index)}")
    }

    /// Drops every stash.
    func stashClear() throws {
        while true {
            let code = git_stash_drop(pointer, 0)
            if code == GIT_ENOTFOUND.rawValue { return }
            try GitError.check(code, "clear the stashes")
        }
    }

    // MARK: Helpers

    /// HEAD's commit for a caller that frees it; nil on an unborn branch.
    private func headCommitObject() throws -> OpaquePointer? {
        guard let commit = head().commit else { return nil }
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, commit), "read HEAD")
        var object: OpaquePointer?
        try GitError.check(git_commit_lookup(&object, pointer, &oid), "read HEAD")
        return object
    }

    /// Refuses a path the index does not hold, or holds nothing below: a
    /// restore needs something committed to restore.
    private func requireTracked(_ paths: [String]) throws {
        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, pointer), "read the index")
        guard let index else { throw GitError(.failed, "the repository has no index") }
        defer { git_index_free(index) }
        for path in paths {
            if git_index_find(nil, index, path) == 0 { continue }
            if git_index_find_prefix(nil, index, path + "/") == 0 { continue }
            throw GitError(.notTracked, "\(path) is not tracked: there is nothing committed to bring back")
        }
    }

    /// Refuses a path the index holds, or holds anything below.
    private func requireUntracked(_ paths: [String]) throws {
        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, pointer), "read the index")
        guard let index else { throw GitError(.failed, "the repository has no index") }
        defer { git_index_free(index) }
        for path in paths {
            if git_index_find(nil, index, path) == 0 {
                throw GitError(.tracked, "\(path) is tracked: only what git leaves alone is deleted")
            }
            if git_index_find_prefix(nil, index, path + "/") == 0 {
                throw GitError(.tracked, "\(path) holds tracked files: only what git leaves alone is deleted")
            }
        }
    }

    /// Removes one path from the work tree: a link itself, never what it
    /// points at, and a folder bottom up.
    private func removeFromWorkTree(_ path: String) throws {
        let url = workdir.appendingPathComponent(path)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return }
        if metadata.st_mode & S_IFMT == S_IFDIR {
            let entries = try FileManager.default.contentsOfDirectory(atPath: url.path)
            for entry in entries {
                try removeFromWorkTree(path + "/" + entry)
            }
            guard rmdir(url.path) == 0 else {
                throw GitError(.failed, "remove \(path): \(String(cString: strerror(errno)))")
            }
            return
        }
        guard unlink(url.path) == 0 else {
            throw GitError(.failed, "remove \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// One stash as the list shows it, its branch read off the subject git
    /// writes: `WIP on <branch>: …`, or `On <branch>: <message>`.
    private func stashEntry(index: Int, commit: String) throws -> GitStashEntry {
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, commit), "read stash@{\(index)}")
        var object: OpaquePointer?
        try GitError.check(git_commit_lookup(&object, pointer, &oid), "read stash@{\(index)}")
        guard let object else { throw GitError(.notFound, "no stash@{\(index)}") }
        defer { git_commit_free(object) }
        let subject = git_commit_summary(object).map { String(cString: $0) } ?? ""
        let parsed = Self.stashSubject(subject)
        return GitStashEntry(index: index, message: parsed.message, branch: parsed.branch, commit: commit)
    }

    /// A stash subject split into what the reader saved it with and the
    /// branch it was saved on; the branch is empty when the subject is not
    /// git's own.
    static func stashSubject(_ subject: String) -> (message: String, branch: String) {
        for prefix in ["WIP on ", "On "] where subject.hasPrefix(prefix) {
            let rest = subject.dropFirst(prefix.count)
            guard let colon = rest.range(of: ": ") else { continue }
            let branch = String(rest[rest.startIndex ..< colon.lowerBound])
            // A WIP subject names the commit it was made on, which is git's
            // own summary; a message is the reader's.
            let message = prefix == "On " ? String(rest[colon.upperBound...]) : subject
            return (message, branch)
        }
        return (subject, "")
    }
}

/// The stashes one `git_stash_foreach` walks, in the order libgit2 hands
/// them over: newest first.
private final class StashCollector {
    var entries: [(index: Int, commit: String)] = []

    func add(index: Int, commit: String) {
        entries.append((index, commit))
    }
}
