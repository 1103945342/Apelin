internal import GitKit
import Foundation

/// One ref pointing at a commit, as the graph's labels show it.
public struct GitCommitRef: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case local
        case remote
        case tag
        /// HEAD points here.
        case head
    }

    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// One commit, as the log lists it.
public struct GitCommit: Sendable, Equatable {
    public var id: String
    /// The first eight characters.
    public var shortID: String
    /// Every parent, first-parent first; more than one is a merge.
    public var parents: [String]
    public var summary: String
    public var authorName: String
    public var authorEmail: String
    /// Seconds since 1970.
    public var authoredAt: Double
    /// The branches, remote-tracking branches and tags pointing at it, and
    /// HEAD when it points here.
    public var refs: [GitCommitRef]

    public init(
        id: String,
        shortID: String,
        parents: [String] = [],
        summary: String,
        authorName: String,
        authorEmail: String,
        authoredAt: Double,
        refs: [GitCommitRef] = []
    ) {
        self.id = id
        self.shortID = shortID
        self.parents = parents
        self.summary = summary
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredAt = authoredAt
        self.refs = refs
    }
}

/// A page of the history.
public struct GitLogPage: Sendable, Equatable {
    public var commits: [GitCommit]
    /// The walk stopped at the limit with more behind it.
    public var hasMore: Bool

    public init(commits: [GitCommit] = [], hasMore: Bool = false) {
        self.commits = commits
        self.hasMore = hasMore
    }
}

/// One file a commit touched, with what happened to it.
public struct GitChangedPath: Sendable, Equatable {
    public var path: String
    /// `A`, `M`, `D`, `R` or `C`.
    public var status: String
    /// The path before a rename or copy.
    public var oldPath: String?

    public init(path: String, status: String, oldPath: String? = nil) {
        self.path = path
        self.status = status
        self.oldPath = oldPath
    }
}

/// One commit opened: its whole message and the files it changed.
public struct GitCommitDetail: Sendable, Equatable {
    public var id: String
    /// The message as it was written, every line of it.
    public var message: String
    public var authorName: String
    public var authorEmail: String
    public var authoredAt: Double
    /// Against the first parent; the whole tree for a root commit.
    public var files: [GitChangedPath]

    public init(
        id: String,
        message: String,
        authorName: String,
        authorEmail: String,
        authoredAt: Double,
        files: [GitChangedPath] = []
    ) {
        self.id = id
        self.message = message
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredAt = authoredAt
        self.files = files
    }
}

/// The two texts of one file, for a line-by-line page.
public struct GitFileVersions: Sendable, Equatable {
    public var old: String
    public var new: String
    /// One side is not text: a NUL among its first bytes.
    public var isBinary: Bool
    /// A side was longer than the cap and was cut.
    public var truncated: Bool

    public init(old: String = "", new: String = "", isBinary: Bool = false, truncated: Bool = false) {
        self.old = old
        self.new = new
        self.isBinary = isBinary
        self.truncated = truncated
    }
}

/// The repository's history: a page of commits with their parents and the
/// refs that label them, one commit opened, one of its files diffed, and the
/// two texts a line-by-line page compares.
public extension GitRepository {
    /// How much of one side of a file the line-by-line page is given: past
    /// this a reader is scrolling through something a phone cannot draw.
    static let fileVersionLimit = 2 << 20

    // MARK: History

    /// A page of the history, newest first, along every parent: the walk git
    /// itself does (topological, then by time), with `skip` commits left out
    /// and `limit` of them answered. One more is read to answer `hasMore`.
    func log(limit: Int, skip: Int) throws -> GitLogPage {
        let limit = max(0, limit)
        let skip = max(0, skip)
        // An unborn HEAD has no history at all, which is no error.
        guard head().commit != nil else { return GitLogPage() }
        let refs = try refsByCommit()
        var walk: OpaquePointer?
        try GitError.check(git_revwalk_new(&walk, pointer), "walk the history")
        guard let walk else { throw GitError(.failed, "the history could not be walked") }
        defer { git_revwalk_free(walk) }
        try GitError.check(
            git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue),
            "walk the history"
        )
        try GitError.check(git_revwalk_push_head(walk), "walk HEAD")
        var commits: [GitCommit] = []
        var skipped = 0
        var hasMore = false
        var next = git_oid()
        while git_revwalk_next(&next, walk) == 0 {
            if skipped < skip {
                skipped += 1
                continue
            }
            guard commits.count < limit else {
                hasMore = true
                break
            }
            commits.append(try row(&next, refs: refs))
        }
        return GitLogPage(commits: commits, hasMore: hasMore)
    }

    /// One commit, its whole message and the files it changed against its
    /// first parent.
    func commitDetail(_ commit: String) throws -> GitCommitDetail {
        let id = try commitID(commit)
        let object = try commitObject(id)
        defer { git_commit_free(object) }
        let author = git_commit_author(object)
        // Not `git_commit_summary`: the page shows the body too, and a
        // subject-only message is the bug this reads past.
        let message = git_commit_message_raw(object).map { String(cString: $0) } ?? ""
        return GitCommitDetail(
            id: id,
            message: message,
            authorName: author.map { String(cString: $0.pointee.name) } ?? "",
            authorEmail: author.map { String(cString: $0.pointee.email) } ?? "",
            authoredAt: Double(git_commit_time(object)),
            files: try changedFiles(of: object)
        )
    }

    /// One commit's diff for one path, matched literally, as a unified patch.
    func diff(of commit: String, path: String) throws -> String {
        let id = try commitID(commit)
        let object = try commitObject(id)
        defer { git_commit_free(object) }
        var diff: OpaquePointer?
        try GitError.check(parentDiff(&diff, of: object, path: path), "diff \(path) in \(commit)")
        defer { git_diff_free(diff) }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try GitError.check(git_diff_to_buf(&buffer, diff, GIT_DIFF_FORMAT_PATCH), "format the diff")
        guard let bytes = buffer.ptr, buffer.size > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: buffer.size), as: UTF8.self)
    }

    // MARK: The two sides of a file

    /// The two texts of one file. `staged` picks the pair: HEAD against the
    /// index — what a commit would take — or the index against the work
    /// tree. An untracked file's old side is empty, and each side is cut at
    /// `fileVersionLimit`.
    func fileVersions(_ path: String, staged: Bool) throws -> GitFileVersions {
        let path = try Self.checked([path])[0]
        let limit = Self.fileVersionLimit
        let old: (bytes: Data, truncated: Bool)
        let new: (bytes: Data, truncated: Bool)
        if staged {
            old = try commitContents(path, inCommit: head().commit, limit: limit)
            new = try indexContents(path, limit: limit)
        } else {
            old = try indexContents(path, limit: limit)
            new = try workTreeContents(path, limit: limit)
        }
        return GitFileVersions(
            old: String(decoding: old.bytes, as: UTF8.self),
            new: String(decoding: new.bytes, as: UTF8.self),
            isBinary: Self.isBinary(old.bytes) || Self.isBinary(new.bytes),
            truncated: old.truncated || new.truncated
        )
    }

    // MARK: Helpers

    /// One commit as the list draws it, with the refs that point at it.
    private func row(_ oid: inout git_oid, refs: [String: [GitCommitRef]]) throws -> GitCommit {
        var object: OpaquePointer?
        try GitError.check(git_commit_lookup(&object, pointer, &oid), "read a commit")
        guard let object else { throw GitError(.notFound, "no commit to read") }
        defer { git_commit_free(object) }
        var parents: [String] = []
        for index in 0 ..< git_commit_parentcount(object) {
            var parent: OpaquePointer?
            guard git_commit_parent(&parent, object, index) == 0, let parent,
                  let id = git_commit_id(parent)
            else { continue }
            parents.append(Self.hex(id))
            git_commit_free(parent)
        }
        let id = Self.hex(git_commit_id(object))
        let author = git_commit_author(object)
        return GitCommit(
            id: id,
            shortID: String(id.prefix(8)),
            parents: parents,
            summary: git_commit_summary(object).map { String(cString: $0) } ?? "",
            authorName: author.map { String(cString: $0.pointee.name) } ?? "",
            authorEmail: author.map { String(cString: $0.pointee.email) } ?? "",
            authoredAt: Double(git_commit_time(object)),
            refs: refs[id] ?? []
        )
    }

    /// Every ref by the commit it points at, each branch's, remote's and
    /// tag's short name, then HEAD.
    private func refsByCommit() throws -> [String: [GitCommitRef]] {
        var names = git_strarray()
        try GitError.check(git_reference_list(&names, pointer), "list the references")
        defer { git_strarray_dispose(&names) }
        var map: [String: [GitCommitRef]] = [:]
        for position in 0 ..< names.count {
            guard let raw = names.strings[position] else { continue }
            let name = String(cString: raw)
            let kind: GitCommitRef.Kind
            let short: String
            if name.hasPrefix("refs/heads/") {
                kind = .local
                short = String(name.dropFirst("refs/heads/".count))
            } else if name.hasPrefix("refs/remotes/") {
                kind = .remote
                short = String(name.dropFirst("refs/remotes/".count))
            } else if name.hasPrefix("refs/tags/") {
                kind = .tag
                short = String(name.dropFirst("refs/tags/".count))
            } else {
                continue
            }
            var reference: OpaquePointer?
            guard git_reference_lookup(&reference, pointer, name) == 0, let reference else { continue }
            var commit: OpaquePointer?
            let peeled = git_reference_peel(&commit, reference, GIT_OBJECT_COMMIT)
            git_reference_free(reference)
            guard peeled == 0, let commit, let id = git_object_id(commit) else { continue }
            git_object_free(commit)
            map[Self.hex(id), default: []].append(GitCommitRef(name: short, kind: kind))
        }
        if let commit = head().commit {
            map[commit, default: []].append(GitCommitRef(name: "HEAD", kind: .head))
        }
        return map.mapValues { refs in
            refs.sorted { left, right in
                let order = Self.refOrder(left.kind)
                let other = Self.refOrder(right.kind)
                return order == other ? left.name < right.name : order < other
            }
        }
    }

    /// The commit `id` as an object, read for a caller that frees it.
    private func commitObject(_ id: String) throws -> OpaquePointer? {
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, id), "read \(id)")
        var object: OpaquePointer?
        try GitError.check(git_commit_lookup(&object, pointer, &oid), "read \(id)")
        guard let object else { throw GitError(.notFound, "no commit \(id)") }
        return object
    }

    /// The files `commit` changed against its first parent, the whole tree
    /// for a root commit, with renames found.
    private func changedFiles(of commit: OpaquePointer?) throws -> [GitChangedPath] {
        var diff: OpaquePointer?
        try GitError.check(parentDiff(&diff, of: commit, path: nil), "diff the commit")
        defer { git_diff_free(diff) }
        var files: [GitChangedPath] = []
        for position in 0 ..< git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, position) else { continue }
            let oldPath = delta.pointee.old_file.path.map { String(cString: $0) }
            let newPath = delta.pointee.new_file.path.map { String(cString: $0) }
            guard let path = newPath ?? oldPath else { continue }
            files.append(GitChangedPath(
                path: path,
                status: Self.statusLetter(delta.pointee.status),
                oldPath: oldPath == path ? nil : oldPath
            ))
        }
        return files
    }

    /// The diff of `commit` against its first parent — the empty tree for a
    /// root commit — with renames found, `path` limiting it literally. The
    /// caller frees it.
    private func parentDiff(_ diff: inout OpaquePointer?, of commit: OpaquePointer?, path: String?) throws -> Int32 {
        var parent: OpaquePointer?
        if git_commit_parentcount(commit) > 0 {
            try GitError.check(git_commit_parent(&parent, commit, 0), "read the parent")
        }
        defer { git_commit_free(parent) }
        var ours: OpaquePointer?
        if let parent {
            try GitError.check(git_commit_tree(&ours, parent), "read the parent's tree")
        }
        defer { git_tree_free(ours) }
        var theirs: OpaquePointer?
        try GitError.check(git_commit_tree(&theirs, commit), "read the commit's tree")
        defer { git_tree_free(theirs) }
        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        options.flags = GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
        let paths = try path.map { try Self.checked([$0]) } ?? []
        var created: OpaquePointer?
        var code: Int32 = 0
        try Self.withStrings(paths) { pathspec in
            options.pathspec = pathspec
            code = git_diff_tree_to_tree(&created, pointer, ours, theirs, &options)
        }
        diff = created
        guard code == 0 else { return code }
        var find = git_diff_find_options()
        git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
        find.flags = GIT_DIFF_FIND_RENAMES.rawValue
        let found = git_diff_find_similar(diff, &find)
        if found < 0 {
            git_diff_free(diff)
            diff = nil
        }
        return found
    }

    /// A delta's one-letter status, as `git log --name-status` spells it.
    private static func statusLetter(_ status: git_delta_t) -> String {
        if status == GIT_DELTA_ADDED { return "A" }
        if status == GIT_DELTA_DELETED { return "D" }
        if status == GIT_DELTA_RENAMED { return "R" }
        if status == GIT_DELTA_COPIED { return "C" }
        return "M"
    }

    /// The ref kinds in the order the graph labels them.
    private static func refOrder(_ kind: GitCommitRef.Kind) -> Int {
        switch kind {
        case .local: 0
        case .remote: 1
        case .tag: 2
        case .head: 3
        }
    }

    /// Whether a side is not text: a NUL among its first bytes.
    private static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    /// The bytes at `path` in HEAD's tree (empty on an unborn branch), cut
    /// at `limit`.
    private func commitContents(_ path: String, inCommit commit: String?, limit: Int) throws -> (bytes: Data, truncated: Bool) {
        guard let commit else { return (Data(), false) }
        let object = try commitObject(commit)
        defer { git_commit_free(object) }
        var tree: OpaquePointer?
        try GitError.check(git_commit_tree(&tree, object), "read \(commit)'s tree")
        guard let tree else { return (Data(), false) }
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        let found = git_tree_entry_bypath(&entry, tree, path)
        if found == GIT_ENOTFOUND.rawValue { return (Data(), false) }
        try GitError.check(found, "find \(path) in \(commit)")
        guard let entry else { return (Data(), false) }
        defer { git_tree_entry_free(entry) }
        guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return (Data(), false) }
        var oid = git_tree_entry_id(entry).pointee
        return try blobContents(&oid, path, limit: limit)
    }

    /// The bytes at `path` in the index, cut at `limit`; empty for a path
    /// the index does not hold.
    private func indexContents(_ path: String, limit: Int) throws -> (bytes: Data, truncated: Bool) {
        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, pointer), "read the index")
        guard let index else { return (Data(), false) }
        defer { git_index_free(index) }
        guard let entry = git_index_get_bypath(index, path, 0) else { return (Data(), false) }
        var oid = entry.pointee.id
        return try blobContents(&oid, path, limit: limit)
    }

    /// The bytes of the file at `path` in the work tree, cut at `limit`;
    /// empty for one that is not a regular file there.
    private func workTreeContents(_ path: String, limit: Int) throws -> (bytes: Data, truncated: Bool) {
        let url = workdir.appendingPathComponent(path)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            return (Data(), false)
        }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw GitError(.notFound, "\(path) could not be read")
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        return (data.count > limit ? data.prefix(limit) : data, data.count > limit)
    }

    /// The bytes of one blob, cut at `limit`.
    private func blobContents(_ oid: inout git_oid, _ path: String, limit: Int) throws -> (bytes: Data, truncated: Bool) {
        var blob: OpaquePointer?
        try GitError.check(git_blob_lookup(&blob, pointer, &oid), "read \(path)")
        guard let blob else { return (Data(), false) }
        defer { git_blob_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        let shown = min(size, limit)
        guard shown > 0, let bytes = git_blob_rawcontent(blob) else { return (Data(), false) }
        return (Data(bytes: bytes, count: shown), size > limit)
    }
}
