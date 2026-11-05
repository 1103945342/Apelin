internal import GitKit
import Darwin
import Foundation

/// What a checkpoint's restore did.
public struct GitCheckpointRestore: Sendable, Equatable {
    /// The branch the work tree was saved on before it changed; nil when it
    /// already was the checkpoint's.
    public var backupBranch: String?
    public var written: Int
    public var removed: Int

    public init(backupBranch: String?, written: Int, removed: Int) {
        self.backupBranch = backupBranch
        self.written = written
        self.removed = removed
    }
}

/// The work tree kept as a commit under a ref of its own, and put back.
///
/// A checkpoint holds every file the repository does not ignore, as it is
/// on disk: what the index has for each file the status calls unchanged,
/// and the work tree's bytes for each it calls changed or new. The index,
/// HEAD and the branches are never touched; the commit's parent is HEAD's
/// commit, so its diff reads against what was committed.
public extension GitRepository {
    /// Saves the work tree as a commit at `reference`, replacing what was
    /// there. Nil, and nothing saved, when more than `maximumFiles` files
    /// or `maximumBytes` bytes would have to be read from the work tree.
    func saveCheckpoint(
        at reference: String,
        message: String,
        author: GitSignature,
        maximumFiles: Int,
        maximumBytes: Int64,
    ) throws -> String? {
        guard let index = try workTreeIndex(maximumFiles: maximumFiles, maximumBytes: maximumBytes) else { return nil }
        defer { git_index_free(index) }
        var commitID = try commitCheckpointIndex(index, message: message, author: author)
        var created: OpaquePointer?
        try GitError.check(
            git_reference_create(&created, pointer, reference, &commitID, 1, "checkpoint"),
            "save the checkpoint",
        )
        git_reference_free(created)
        return Self.hex(&commitID)
    }

    /// Makes the work tree the checkpoint at `reference`: each file it
    /// holds written back, each file it does not hold removed, folders that
    /// are left empty removed with them. Ignored files stay. What the work
    /// tree held first is committed on a new branch
    /// `apelin-backup/checkpoint-<time>`, before anything changes.
    func restoreCheckpoint(at reference: String, author: GitSignature, now: Date = Date()) throws -> GitCheckpointRestore {
        var targetID = git_oid()
        let found = git_reference_name_to_id(&targetID, pointer, reference)
        if found == GIT_ENOTFOUND.rawValue {
            throw GitError(.notFound, "no code was saved before this message")
        }
        try GitError.check(found, "read the checkpoint")
        let target = try checkpointFiles(ofCommit: &targetID)
        guard let index = try workTreeIndex(maximumFiles: .max, maximumBytes: .max) else {
            throw GitError(.failed, "the work tree could not be read")
        }
        defer { git_index_free(index) }
        let current = Self.files(of: index)
        let removed = current.keys.filter { target[$0] == nil }.sorted()
        let written = target.filter { current[$0.key] != $0.value }.map { $0.key }.sorted()
        guard !removed.isEmpty || !written.isEmpty else {
            return GitCheckpointRestore(backupBranch: nil, written: 0, removed: 0)
        }
        var backupID = try commitCheckpointIndex(
            index,
            message: "Saved by Apelin before restoring a checkpoint\n\nThe work tree as it was, every file the repository does not ignore.\n",
            author: author,
        )
        let branch = try makeCheckpointBackupBranch(Self.hex(&backupID), now: now)
        for path in removed {
            try removeCheckpointPath(path)
        }
        for path in written {
            if let file = target[path] {
                try writeCheckpointFile(path, file)
            }
        }
        return GitCheckpointRestore(backupBranch: branch, written: written.count, removed: removed.count)
    }

    // MARK: Reading the work tree

    /// An index of the work tree in memory, the caller's to free; nil when
    /// the files to read from the work tree pass either bound.
    private func workTreeIndex(maximumFiles: Int, maximumBytes: Int64) throws -> OpaquePointer? {
        var options = git_status_options()
        git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_EXCLUDE_SUBMODULES.rawValue
        var list: OpaquePointer?
        try GitError.check(git_status_list_new(&list, pointer, &options), "read the status")
        defer { git_status_list_free(list) }

        // Every path the status names, on either side of a rename: the work
        // tree says what each one is now, or that it is gone.
        var fromWorkTree: Set<String> = []
        for position in 0 ..< git_status_list_entrycount(list) {
            guard let entry = git_status_byindex(list, position)?.pointee else { continue }
            if entry.status.rawValue & GIT_STATUS_IGNORED.rawValue != 0 {
                continue
            }
            for delta in [entry.head_to_index, entry.index_to_workdir] {
                guard let delta else { continue }
                if let path = delta.pointee.old_file.path {
                    fromWorkTree.insert(String(cString: path))
                }
                if let path = delta.pointee.new_file.path {
                    fromWorkTree.insert(String(cString: path))
                }
            }
        }
        if fromWorkTree.count > maximumFiles {
            return nil
        }
        var bytes: Int64 = 0
        for path in fromWorkTree {
            var metadata = stat()
            if lstat(workdir.appendingPathComponent(path).path, &metadata) == 0 {
                bytes += Int64(metadata.st_size)
            }
        }
        if bytes > maximumBytes {
            return nil
        }

        var current: OpaquePointer?
        try GitError.check(git_repository_index(&current, pointer), "open the index")
        defer { git_index_free(current) }
        var saved: OpaquePointer?
        try GitError.check(git_index_new(&saved), "make the checkpoint's index")
        do {
            for position in 0 ..< git_index_entrycount(current) {
                guard var entry = git_index_get_byindex(current, position)?.pointee,
                      !fromWorkTree.contains(String(cString: entry.path)),
                      (entry.flags & UInt16(GIT_INDEX_ENTRY_STAGEMASK)) == 0
                else { continue }
                try GitError.check(git_index_add(saved, &entry), "save the index")
            }
            for path in fromWorkTree.sorted() {
                try addCheckpointFile(path, to: saved)
            }
        } catch {
            git_index_free(saved)
            throw error
        }
        return saved
    }

    /// Adds the work tree's file or link at `path`; one that is gone, or a
    /// folder now, is left out.
    private func addCheckpointFile(_ path: String, to index: OpaquePointer?) throws {
        var metadata = stat()
        guard lstat(workdir.appendingPathComponent(path).path, &metadata) == 0 else { return }
        let kind = metadata.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFLNK else { return }
        var blob = git_oid()
        try GitError.check(git_blob_create_from_workdir(&blob, pointer, path), "save \(path)")
        var entry = git_index_entry()
        entry.mode = kind == S_IFLNK ? 0o120000 : (metadata.st_mode & 0o111 != 0 ? 0o100755 : 0o100644)
        entry.id = blob
        entry.file_size = UInt32(truncatingIfNeeded: metadata.st_size)
        try path.withCString { name in
            entry.path = name
            try GitError.check(git_index_add(index, &entry), "save \(path)")
        }
    }

    /// A commit of `index`'s tree on top of HEAD's commit, or of none on a
    /// branch with no commit yet. It is on no branch.
    private func commitCheckpointIndex(_ index: OpaquePointer?, message: String, author: GitSignature) throws -> git_oid {
        var treeID = git_oid()
        try GitError.check(git_index_write_tree_to(&treeID, index, pointer), "save the work tree")
        var tree: OpaquePointer?
        try GitError.check(git_tree_lookup(&tree, pointer, &treeID), "save the work tree")
        defer { git_tree_free(tree) }
        var parent: OpaquePointer?
        if let head = head().commit {
            var headID = git_oid()
            try GitError.check(git_oid_fromstr(&headID, head), "read HEAD")
            try GitError.check(git_commit_lookup(&parent, pointer, &headID), "read HEAD's commit")
        }
        defer { git_commit_free(parent) }
        var signature: UnsafeMutablePointer<git_signature>?
        try GitError.check(git_signature_now(&signature, author.name, author.email), "make the signature")
        defer { git_signature_free(signature) }
        var commitID = git_oid()
        var parents: [OpaquePointer?] = parent.map { [$0] } ?? []
        let code = parents.withUnsafeMutableBufferPointer { buffer in
            git_commit_create(&commitID, pointer, nil, signature, signature, nil, message, tree, buffer.count, buffer.baseAddress)
        }
        try GitError.check(code, "save the work tree")
        return commitID
    }

    /// Each file of an index, by path: its blob and mode. A submodule's
    /// commit is no file of the work tree's and is left out.
    private static func files(of index: OpaquePointer?) -> [String: CheckpointFile] {
        var files: [String: CheckpointFile] = [:]
        for position in 0 ..< git_index_entrycount(index) {
            guard var entry = git_index_get_byindex(index, position)?.pointee, entry.mode != 0o160000 else { continue }
            files[String(cString: entry.path)] = CheckpointFile(id: hex(&entry.id), mode: entry.mode)
        }
        return files
    }

    /// Each file and link of a commit's tree, by path.
    private func checkpointFiles(ofCommit commit: inout git_oid) throws -> [String: CheckpointFile] {
        var object: OpaquePointer?
        try GitError.check(git_commit_lookup(&object, pointer, &commit), "read the checkpoint")
        defer { git_commit_free(object) }
        var tree: OpaquePointer?
        try GitError.check(git_commit_tree(&tree, object), "read the checkpoint's tree")
        defer { git_tree_free(tree) }
        let files = CheckpointFiles()
        let code = withExtendedLifetime(files) {
            git_tree_walk(tree, GIT_TREEWALK_PRE, { root, entry, payload in
                guard let root, let entry, let payload, git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return 0 }
                let path = String(cString: root) + String(cString: git_tree_entry_name(entry))
                let mode = UInt32(truncatingIfNeeded: git_tree_entry_filemode(entry).rawValue)
                Unmanaged<CheckpointFiles>.fromOpaque(payload).takeUnretainedValue().all[path] = CheckpointFile(
                    id: GitRepository.hex(git_tree_entry_id(entry)),
                    mode: mode,
                )
                return 0
            }, Unmanaged.passUnretained(files).toOpaque())
        }
        try GitError.check(code, "read the checkpoint's tree")
        return files.all
    }

    // MARK: Changing the work tree

    /// Removes the file or link at `path`, then each folder above it the
    /// removal left empty. Nothing is removed through a link, nor in `.git`.
    private func removeCheckpointPath(_ path: String) throws {
        let path = try Self.checked([path])[0]
        guard Self.isWorkTreePath(path), try parentsAreFolders(of: path, making: false) else { return }
        let url = workdir.appendingPathComponent(path)
        if unlink(url.path) != 0, errno != ENOENT {
            throw GitError(.failed, "could not remove \(path): \(String(cString: strerror(errno)))")
        }
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            // rmdir takes only an empty folder, and never a link
            if rmdir(workdir.appendingPathComponent(folder).path) != 0 {
                break
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// Writes the checkpoint's bytes for `path`: a regular file put in place
    /// whole, or a link made again.
    private func writeCheckpointFile(_ path: String, _ file: CheckpointFile) throws {
        let path = try Self.checked([path])[0]
        guard Self.isWorkTreePath(path) else { return }
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, file.id), "read \(path)")
        var blob: OpaquePointer?
        try GitError.check(git_blob_lookup(&blob, pointer, &oid), "read \(path)")
        defer { git_blob_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        var data = Data()
        if size > 0, let bytes = git_blob_rawcontent(blob) {
            data = Data(bytes: bytes, count: size)
        }
        guard try parentsAreFolders(of: path, making: true) else {
            throw GitError(.conflict, "\(path) could not be written: a folder above it is a file or a link")
        }
        let url = workdir.appendingPathComponent(path)
        var metadata = stat()
        if lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR {
            throw GitError(.conflict, "\(path) could not be written: it is a folder now")
        }
        if file.mode == 0o120000 {
            if unlink(url.path) != 0, errno != ENOENT {
                throw GitError(.failed, "could not replace \(path): \(String(cString: strerror(errno)))")
            }
            guard symlink(String(decoding: data, as: UTF8.self), url.path) == 0 else {
                throw GitError(.failed, "could not write \(path): \(String(cString: strerror(errno)))")
            }
            return
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".apelin-checkpoint-" + UUID().uuidString)
        let permissions = file.mode == 0o100755 ? 0o755 : 0o644
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw GitError(.failed, "could not write \(path)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw GitError(.failed, "could not write \(path): \(reason)")
        }
    }

    /// Whether every folder above `path` is a real folder, not a link; with
    /// `making`, a missing one is made. False when one is a file or a link.
    private func parentsAreFolders(of path: String, making: Bool) throws -> Bool {
        var folder = ""
        for component in path.split(separator: "/").dropLast() {
            folder = folder.isEmpty ? String(component) : folder + "/" + component
            let url = workdir.appendingPathComponent(folder)
            var metadata = stat()
            if lstat(url.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else { return false }
                continue
            }
            guard errno == ENOENT else { return false }
            guard making else { return true }
            guard mkdir(url.path, 0o755) == 0 || errno == EEXIST else {
                throw GitError(.failed, "could not make \(folder): \(String(cString: strerror(errno)))")
            }
        }
        return true
    }

    /// A path a checkpoint may write or remove: none inside `.git`.
    private static func isWorkTreePath(_ path: String) -> Bool {
        !path.split(separator: "/").contains { $0.lowercased() == ".git" }
    }

    /// `refs/heads/apelin-backup/checkpoint-<yyyyMMdd-HHmmss>` at `commit`,
    /// a number after it when that is taken.
    private func makeCheckpointBackupBranch(_ commit: String, now: Date) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = "apelin-backup/checkpoint-" + formatter.string(from: now)
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, commit), "read the backup")
        for attempt in 1 ... 100 {
            let name = attempt == 1 ? stamp : "\(stamp)-\(attempt)"
            var reference: OpaquePointer?
            let code = git_reference_create(&reference, pointer, "refs/heads/" + name, &oid, 0, "checkpoint restore: saved before it")
            git_reference_free(reference)
            if code == 0 {
                return name
            }
            guard code == GIT_EEXISTS.rawValue else { throw GitError.last(code, "make the backup branch") }
        }
        throw GitError(.conflict, "no free name for the backup branch \(stamp)")
    }
}

/// A file as a checkpoint or the work tree has it.
struct CheckpointFile: Equatable {
    var id: String
    var mode: UInt32
}

/// The files a tree walk collects.
private final class CheckpointFiles {
    var all: [String: CheckpointFile] = [:]
}
