internal import GitKit
import Foundation

/// One branch, local or on a remote, as the branches page lists it.
public struct GitBranch: Sendable, Equatable {
    /// `main`, or `origin/main` for a remote-tracking one.
    public var name: String
    /// Whether it lives on a remote.
    public var isRemote: Bool
    /// The local branch's upstream, `origin/main`; nil when it tracks none.
    public var upstream: String?
    /// Commits the local branch has that its upstream lacks.
    public var ahead: Int
    /// Commits the upstream has that the local branch lacks.
    public var behind: Int
    /// Whether this is the branch HEAD is on.
    public var isCurrent: Bool
    /// The commit it points at.
    public var commit: String
    /// Its upstream is configured but no longer advertised (`[gone]`).
    public var isGone: Bool

    public init(
        name: String,
        isRemote: Bool,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        isCurrent: Bool = false,
        commit: String,
        isGone: Bool = false
    ) {
        self.name = name
        self.isRemote = isRemote
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isCurrent = isCurrent
        self.commit = commit
        self.isGone = isGone
    }
}

/// One tag, with the commit it points at.
public struct GitTag: Sendable, Equatable {
    public var name: String
    /// Peeled when the tag is annotated.
    public var commit: String
    public var isAnnotated: Bool

    public init(name: String, commit: String, isAnnotated: Bool) {
        self.name = name
        self.commit = commit
        self.isAnnotated = isAnnotated
    }
}

/// Every ref of a repository, as one page reads them.
public struct GitBranches: Sendable, Equatable {
    public var local: [GitBranch]
    public var remote: [GitBranch]
    public var tags: [GitTag]
    /// The branch HEAD is on; nil on an unborn branch (`git init` with no
    /// commit) and on a detached HEAD.
    public var current: String?
    /// HEAD is on no branch.
    public var isDetached: Bool

    public init(
        local: [GitBranch] = [],
        remote: [GitBranch] = [],
        tags: [GitTag] = [],
        current: String? = nil,
        isDetached: Bool = false
    ) {
        self.local = local
        self.remote = remote
        self.tags = tags
        self.current = current
        self.isDetached = isDetached
    }
}

/// How a local branch stands beside what it tracks.
public struct GitUpstream: Sendable, Equatable {
    /// `origin/main`, or a local branch's name when it tracks one of those.
    public var name: String
    /// Commits the local branch has that the upstream lacks.
    public var ahead: Int
    /// Commits the upstream has that the local branch lacks.
    public var behind: Int
    /// Configured, but the ref it names is gone.
    public var isGone: Bool

    public init(name: String, ahead: Int = 0, behind: Int = 0, isGone: Bool = false) {
        self.name = name
        self.ahead = ahead
        self.behind = behind
        self.isGone = isGone
    }
}

/// What a merge did to the checked-out branch.
public struct GitMergeResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Already contained; nothing moved.
        case upToDate
        /// The branch moved onto the other one; no commit was made.
        case fastForward
        /// A merge commit was made.
        case merged
        /// Conflicts are in the index and the merge is left in progress.
        case conflict
    }

    public var outcome: Outcome
    /// The paths that conflict, when `outcome` is `conflict`.
    public var conflicts: [String]
    /// The commit HEAD is at afterwards; nil when it did not move.
    public var commit: String?

    public init(outcome: Outcome, conflicts: [String] = [], commit: String? = nil) {
        self.outcome = outcome
        self.conflicts = conflicts
        self.commit = commit
    }
}

/// The repository's refs — branches, tags — and the two operations that move
/// one without a commit of its own: a merge and an abort. Every name is
/// checked before it reaches libgit2, and no path here ever leaves the work
/// tree.
public extension GitRepository {
    // MARK: Reading

    /// Every local and remote-tracking branch, and every tag. A local
    /// branch carries what it tracks and how far the two have drifted; a
    /// remote one carries its commit only, and is never `isCurrent`.
    func branches() throws -> GitBranches {
        let current = head()
        var local: [GitBranch] = []
        var remote: [GitBranch] = []
        var iterator: OpaquePointer?
        try GitError.check(git_branch_iterator_new(&iterator, pointer, GIT_BRANCH_ALL), "list the branches")
        if let iterator {
            defer { git_branch_iterator_free(iterator) }
            while true {
                var reference: OpaquePointer?
                var type = git_branch_t(rawValue: 0)
                let code = git_branch_next(&reference, &type, iterator)
                if code == GIT_ITEROVER.rawValue { break }
                if code == GIT_ENOTFOUND.rawValue { continue }
                try GitError.check(code, "read a branch")
                guard let reference else { continue }
                // A reference that vanishes mid-listing is one a concurrent
                // git call removed; it is not a change to list.
                defer { git_reference_free(reference) }
                var nameOut: UnsafePointer<CChar>?
                guard git_branch_name(&nameOut, reference) == 0, let nameOut,
                      let target = git_reference_target(reference)
                else { continue }
                let name = String(cString: nameOut)
                if type == GIT_BRANCH_REMOTE {
                    remote.append(GitBranch(name: name, isRemote: true, commit: Self.hex(target)))
                    continue
                }
                var branch = GitBranch(
                    name: name,
                    isRemote: false,
                    isCurrent: git_branch_is_head(reference) != 0,
                    commit: Self.hex(target)
                )
                if let upstream = try upstream(of: name) {
                    branch.upstream = upstream.name
                    branch.ahead = upstream.ahead
                    branch.behind = upstream.behind
                    branch.isGone = upstream.isGone
                }
                local.append(branch)
            }
        }
        return GitBranches(
            local: local.sorted { $0.name < $1.name },
            remote: remote.sorted { $0.name < $1.name },
            tags: try tags(),
            current: current.commit == nil ? nil : current.branch,
            isDetached: git_repository_head_detached(pointer) == 1
        )
    }

    /// The branch `branch` tracks, from `branch.<name>.remote` and `.merge`,
    /// beside the commits the two have apart; nil when it tracks none.
    func upstream(of branch: String) throws -> GitUpstream? {
        try Self.checkBranchName(branch)
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        let code = git_branch_upstream_name(&buffer, pointer, "refs/heads/" + branch)
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try GitError.check(code, "read what \(branch) tracks")
        guard let reference = buffer.ptr.map({ String(cString: $0) }) else { return nil }
        let name = Self.shortReference(reference)
        var target = git_oid()
        // Configured but never fetched, or deleted on the remote: there is
        // nothing to count against, and the row says `[gone]`.
        guard git_reference_name_to_id(&target, pointer, reference) == 0 else {
            return GitUpstream(name: name, isGone: true)
        }
        var ahead = 0
        var behind = 0
        if let local = commit(ofBranch: branch) {
            var localOID = git_oid()
            git_oid_fromstr(&localOID, local)
            var localAhead = 0
            var localBehind = 0
            if git_graph_ahead_behind(&localAhead, &localBehind, pointer, &localOID, &target) == 0 {
                ahead = localAhead
                behind = localBehind
            }
        }
        return GitUpstream(name: name, ahead: ahead, behind: behind)
    }

    /// Every tag, peeled to its commit. A tag that points at no commit at
    /// all — git allows one on a blob — is left out.
    func tags() throws -> [GitTag] {
        var names = git_strarray()
        try GitError.check(git_tag_list(&names, pointer), "list the tags")
        defer { git_strarray_dispose(&names) }
        var tags: [GitTag] = []
        for position in 0 ..< names.count {
            guard let raw = names.strings[position] else { continue }
            let name = String(cString: raw)
            guard let target = try tagTarget(name) else { continue }
            tags.append(GitTag(name: name, commit: target.commit, isAnnotated: target.isAnnotated))
        }
        return tags.sorted { $0.name < $1.name }
    }

    /// The commit `spec` names — a branch, a tag, a remote-tracking branch, a
    /// commit ID, HEAD — with an annotated tag peeled to what it points at.
    func commitID(_ spec: String) throws -> String {
        guard !spec.isEmpty, !spec.utf8.contains(0), !spec.hasPrefix("-") else {
            throw GitError(.invalid, "\(spec.debugDescription) is not a commit, a branch or a tag")
        }
        var object: OpaquePointer?
        let code = git_revparse_single(&object, pointer, spec)
        if code == GIT_ENOTFOUND.rawValue || (code == 0 && object == nil) {
            throw GitError(.notFound, "no commit, branch or tag \(spec.debugDescription)")
        }
        try GitError.check(code, "read \(spec)")
        guard let object else { throw GitError(.notFound, "no commit, branch or tag \(spec.debugDescription)") }
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        // A path, or a tag of a blob, is no commit to move a branch to.
        guard git_object_peel(&commit, object, GIT_OBJECT_COMMIT) == 0, let commit,
              let id = git_object_id(commit)
        else {
            throw GitError(.invalid, "\(spec.debugDescription) names no commit")
        }
        defer { git_object_free(commit) }
        return Self.hex(id)
    }

    // MARK: Writing

    /// Makes `name` at `startPoint` (nil: HEAD), and switches to it when
    /// `checkout`. Throws `conflict` when the name is taken, and `dirtyTree`
    /// when the switch would overwrite uncommitted changes.
    @discardableResult
    func createBranch(_ name: String, startPoint: String? = nil, checkout: Bool = false) throws -> String {
        try Self.checkBranchName(name)
        let target: String?
        if let startPoint {
            target = try commitID(startPoint)
        } else {
            target = head().commit
        }
        guard let target else {
            throw GitError(.invalid, "HEAD has no commit yet: name the commit \(name) starts at")
        }
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, target), "read \(target)")
        var commit: OpaquePointer?
        try GitError.check(git_commit_lookup(&commit, pointer, &oid), "read \(target)")
        guard let commit else { throw GitError(.notFound, "no commit \(target)") }
        defer { git_commit_free(commit) }
        var branch: OpaquePointer?
        try GitError.check(git_branch_create(&branch, pointer, name, commit, 0), "make the branch \(name)")
        git_reference_free(branch)
        if checkout {
            try self.checkoutBranch(name)
        }
        return name
    }

    /// Switches to a local branch. With `remote`, the local branch of that
    /// name is made from `<remote>/<name>` first — at its commit, tracking
    /// it — unless one of that name already exists, which keeps its commit.
    ///
    /// The work tree is checked out before HEAD moves, so a checkout the
    /// uncommitted changes are in the way of throws `dirtyTree` and leaves
    /// HEAD where it was.
    @discardableResult
    func checkoutBranch(_ name: String, remote: String? = nil) throws -> String {
        try Self.checkBranchName(name)
        guard let remote else {
            try switchToLocalBranch(name)
            return name
        }
        guard !remote.utf8.contains(0), !remote.hasPrefix("-") else {
            throw GitError(.invalid, "\(remote.debugDescription) is not a remote name")
        }
        var target = git_oid()
        guard git_reference_name_to_id(&target, pointer, "refs/remotes/\(remote)/\(name)") == 0 else {
            throw GitError(.notFound, "\(remote) has no branch \(name)")
        }
        if commit(ofBranch: name) != nil {
            try switchToLocalBranch(name)
            return name
        }
        var commit: OpaquePointer?
        try GitError.check(git_commit_lookup(&commit, pointer, &target), "read \(remote)/\(name)")
        guard let commit else { throw GitError(.notFound, "no commit on \(remote)/\(name)") }
        defer { git_commit_free(commit) }
        let checkout = CheckoutRecord()
        let code = checkout.run { options in git_checkout_tree(pointer, commit, &options) }
        guard code == 0 else { throw Self.refusedCheckout(checkout.failure(code, "switch to \(name)")) }
        var branch: OpaquePointer?
        try GitError.check(git_branch_create(&branch, pointer, name, commit, 0), "make the branch \(name)")
        defer { git_reference_free(branch) }
        try GitError.check(git_branch_set_upstream(branch, "\(remote)/\(name)"), "set \(name)'s upstream")
        try GitError.check(git_repository_set_head(pointer, "refs/heads/" + name), "point HEAD at \(name)")
        return name
    }

    /// Deletes a local branch. The checked-out one is refused: HEAD would
    /// name nothing.
    func deleteBranch(_ name: String) throws {
        try Self.checkBranchName(name)
        var reference: OpaquePointer?
        try GitError.check(git_branch_lookup(&reference, pointer, name, GIT_BRANCH_LOCAL), "read \(name)")
        guard let reference else { throw GitError(.notFound, "no branch \(name)") }
        defer { git_reference_free(reference) }
        guard git_branch_is_head(reference) == 0 else {
            throw GitError(.conflict, "\(name) is the checked-out branch: switch to another branch first")
        }
        try GitError.check(git_branch_delete(reference), "delete \(name)")
    }

    /// Deletes `name` on `remote`, as `git push <remote> --delete <name>`
    /// does, and takes away the remote-tracking branch the last fetch left.
    /// A remote that refuses throws `rejected`; one that asks for a sign-in,
    /// `authenticationFailed`.
    func deleteRemoteBranch(_ name: String, remote: String, credentials: GitCredentialLookup? = nil) throws {
        try Self.checkBranchName(name)
        let handle = try lookupRemote(remote)
        defer { git_remote_free(handle) }
        let callbacks = RemoteCallbacks(credentials: credentials)
        var options = git_push_options()
        git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
        callbacks.install(&options.callbacks)
        // The empty source side is git's spelling of a deletion.
        let refspec = ":refs/heads/\(name)"
        let code = withExtendedLifetime(callbacks) {
            Self.withStrings([refspec]) { refspecs in
                var refspecs = refspecs
                return git_remote_push(handle, &refspecs, &options)
            }
        }
        if code == GIT_ENONFASTFORWARD.rawValue {
            throw GitError(.rejected, "\(remote) refused to delete \(name)")
        }
        guard code == 0 else { throw callbacks.failure(code, "delete \(name) on \(remote)") }
        if let rejected = callbacks.rejections.first {
            throw GitError(.rejected, "\(remote) refused to delete \(rejected.ref): \(rejected.status)")
        }
        // The deletion stands even when the stale tracking ref cannot be
        // taken away; it then shows as a branch whose upstream is gone.
        var tracking: OpaquePointer?
        if git_reference_lookup(&tracking, pointer, "refs/remotes/\(remote)/\(name)") == 0, let tracking {
            _ = git_reference_delete(tracking)
            git_reference_free(tracking)
        }
    }

    /// Renames a local branch, and moves its upstream configuration to the
    /// new name with it.
    @discardableResult
    func renameBranch(_ from: String, to: String) throws -> String {
        try Self.checkBranchName(from)
        try Self.checkBranchName(to)
        var reference: OpaquePointer?
        try GitError.check(git_branch_lookup(&reference, pointer, from, GIT_BRANCH_LOCAL), "read \(from)")
        guard let reference else { throw GitError(.notFound, "no branch \(from)") }
        defer { git_reference_free(reference) }
        let remote = localConfigValue("branch.\(from).remote")
        let merge = localConfigValue("branch.\(from).merge")
        var moved: OpaquePointer?
        try GitError.check(git_branch_move(&moved, reference, to, 0), "rename \(from) to \(to)")
        git_reference_free(moved)
        if let remote {
            try setLocalConfigValue(remote, for: "branch.\(to).remote")
        }
        if let merge {
            try setLocalConfigValue(merge, for: "branch.\(to).merge")
        }
        try dropLocalConfigValue("branch.\(from).remote")
        try dropLocalConfigValue("branch.\(from).merge")
        return to
    }

    // MARK: Merging

    /// Merges `branch` — a branch, a tag or a commit — into HEAD. A
    /// fast-forward unless `noFastForward` asks for a commit of its own;
    /// conflicts are left in the index and the work tree, the merge in
    /// progress, and answered with their paths.
    ///
    /// `author` writes the merge commit, and is only needed for one: a
    /// branch with no identity set still fast-forwards.
    func merge(_ branch: String, noFastForward: Bool = false, author: GitSignature? = nil) throws -> GitMergeResult {
        let theirsID = try commitID(branch)
        var theirsOID = git_oid()
        try GitError.check(git_oid_fromstr(&theirsOID, theirsID), "read \(branch)")
        var theirs: OpaquePointer?
        try GitError.check(git_commit_lookup(&theirs, pointer, &theirsOID), "read \(branch)")
        guard let theirs else { throw GitError(.notFound, "no commit \(branch)") }
        defer { git_commit_free(theirs) }

        var annotated: OpaquePointer?
        try GitError.check(git_annotated_commit_lookup(&annotated, pointer, &theirsOID), "read \(branch)")
        defer { git_annotated_commit_free(annotated) }
        var analysis = git_merge_analysis_t(rawValue: 0)
        var preference = git_merge_preference_t(rawValue: 0)
        var heads: [OpaquePointer?] = [annotated]
        try GitError.check(
            git_merge_analysis(&analysis, &preference, pointer, &heads, 1),
            "compare HEAD with \(branch)"
        )
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return GitMergeResult(outcome: .upToDate)
        }

        let current = head()
        let canFastForward = analysis.rawValue
            & (GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue | GIT_MERGE_ANALYSIS_UNBORN.rawValue) != 0
        // An unborn HEAD has no commit to merge into, so even a no-fast-forward
        // merge is a fast-forward there, as it is in git.
        if canFastForward, !noFastForward || current.commit == nil {
            let checkout = CheckoutRecord()
            let code = checkout.run { options in git_checkout_tree(pointer, theirs, &options) }
            guard code == 0 else { throw Self.refusedCheckout(checkout.failure(code, "merge \(branch)")) }
            if let name = current.branch {
                var moved: OpaquePointer?
                if let from = current.commit {
                    var fromOID = git_oid()
                    try GitError.check(git_oid_fromstr(&fromOID, from), "read \(name)")
                    try GitError.check(
                        git_reference_create_matching(
                            &moved,
                            pointer,
                            "refs/heads/" + name,
                            &theirsOID,
                            1,
                            &fromOID,
                            "merge \(branch): fast-forward"
                        ),
                        "move \(name)"
                    )
                } else {
                    try GitError.check(
                        git_reference_create(&moved, pointer, "refs/heads/" + name, &theirsOID, 0, "merge \(branch)"),
                        "make \(name)"
                    )
                }
                git_reference_free(moved)
                try GitError.check(git_repository_set_head(pointer, "refs/heads/" + name), "point HEAD at \(name)")
            } else {
                try GitError.check(git_repository_set_head_detached(pointer, &theirsOID), "detach HEAD at \(theirsID)")
            }
            return GitMergeResult(outcome: .fastForward, commit: theirsID)
        }

        guard let author else {
            throw GitError(.invalid, "a merge commit needs an author: set one in Settings ▸ Git")
        }
        var signature: UnsafeMutablePointer<git_signature>?
        try GitError.check(git_signature_now(&signature, author.name, author.email), "make the signature")
        defer { git_signature_free(signature) }

        if canFastForward {
            // A no-fast-forward merge of a branch that could have moved the
            // branch without one: the merge's tree is theirs, and the commit
            // records both sides.
            let checkout = CheckoutRecord()
            let code = checkout.run { options in git_checkout_tree(pointer, theirs, &options) }
            guard code == 0 else { throw Self.refusedCheckout(checkout.failure(code, "merge \(branch)")) }
            return try mergeCommit(branch: branch, parents: [current.commit, theirsID], signature: signature)
        }

        let record = CheckoutRecord()
        var mergeOptions = git_merge_options()
        git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION))
        mergeOptions.flags = GIT_MERGE_FIND_RENAMES.rawValue
        var theirHeads: [OpaquePointer?] = [annotated]
        let code = record.run { options in
            options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
                | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
                | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue
            return git_merge(pointer, &theirHeads, 1, &mergeOptions, &options)
        }
        guard code == 0 else { throw Self.refusedCheckout(record.failure(code, "merge \(branch)")) }

        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, pointer), "read the index")
        guard let index else { throw GitError(.failed, "the repository has no index") }
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) == 1 {
            // git_merge wrote MERGE_HEAD and left the conflicts in the index
            // and the work tree: the reader resolves them and commits, or
            // aborts.
            return GitMergeResult(outcome: .conflict, conflicts: Self.conflictPaths(index))
        }
        return try mergeCommit(branch: branch, parents: [current.commit, theirsID], signature: signature)
    }

    /// Aborts a merge in progress: HEAD's commit back into the index and the
    /// work tree, the merge state cleared. With no merge in progress at all
    /// it is `invalid`.
    func abortMerge() throws {
        guard git_repository_state(pointer) == Int32(GIT_REPOSITORY_STATE_MERGE.rawValue) else {
            throw GitError(.invalid, "no merge is in progress")
        }
        guard let commit = head().commit else {
            git_repository_state_cleanup(pointer)
            throw GitError(.invalid, "HEAD has no commit to go back to")
        }
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, commit), "read HEAD")
        var object: OpaquePointer?
        try GitError.check(git_object_lookup(&object, pointer, &oid, GIT_OBJECT_COMMIT), "read HEAD")
        guard let object else { throw GitError(.notFound, "no commit \(commit)") }
        defer { git_object_free(object) }
        // `git merge --abort` takes the index and the work tree back to
        // HEAD; a local change the merge did not touch is dropped with it,
        // as it is in git.
        try GitError.check(git_reset(pointer, object, GIT_RESET_HARD, nil), "abort the merge")
        git_repository_state_cleanup(pointer)
    }

    // MARK: Tags

    /// Tags the commit `commit` names (nil: HEAD) with `name`. A message
    /// makes it annotated, with `author` as the tagger; without one it is a
    /// lightweight tag.
    @discardableResult
    func createTag(_ name: String, commit: String? = nil, message: String? = nil, author: GitSignature? = nil) throws -> String {
        guard !name.isEmpty, !name.utf8.contains(0), !name.hasPrefix("-") else {
            throw GitError(.invalid, "\(name.debugDescription) is not a tag name")
        }
        let target: String?
        if let commit {
            target = try commitID(commit)
        } else {
            target = head().commit
        }
        guard let target else { throw GitError(.invalid, "HEAD has no commit yet: name the commit to tag") }
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, target), "read \(target)")
        var object: OpaquePointer?
        try GitError.check(git_object_lookup(&object, pointer, &oid, GIT_OBJECT_COMMIT), "read \(target)")
        guard let object else { throw GitError(.notFound, "no commit \(target)") }
        defer { git_object_free(object) }
        var tagID = git_oid()
        if let message {
            guard let author else {
                throw GitError(.invalid, "an annotated tag needs a tagger: set an author in Settings ▸ Git")
            }
            var signature: UnsafeMutablePointer<git_signature>?
            try GitError.check(git_signature_now(&signature, author.name, author.email), "make the signature")
            defer { git_signature_free(signature) }
            try GitError.check(
                git_tag_create(&tagID, pointer, name, object, signature, message, 0),
                "make the tag \(name)"
            )
        } else {
            try GitError.check(
                git_tag_create_lightweight(&tagID, pointer, name, object, 0),
                "make the tag \(name)"
            )
        }
        return name
    }

    /// Deletes the tag `name`.
    func deleteTag(_ name: String) throws {
        guard !name.isEmpty, !name.utf8.contains(0), !name.hasPrefix("-") else {
            throw GitError(.invalid, "\(name.debugDescription) is not a tag name")
        }
        let code = git_tag_delete(pointer, name)
        if code == GIT_ENOTFOUND.rawValue {
            throw GitError(.notFound, "no tag \(name.debugDescription)")
        }
        try GitError.check(code, "delete the tag \(name)")
    }

    // MARK: Helpers

    /// Switches to a branch that has a commit, checking the work tree out
    /// over the old one before HEAD moves.
    private func switchToLocalBranch(_ name: String) throws {
        guard let target = commit(ofBranch: name) else {
            throw GitError(.notFound, "no branch \(name) with a commit")
        }
        var oid = git_oid()
        try GitError.check(git_oid_fromstr(&oid, target), "read \(name)")
        var commit: OpaquePointer?
        try GitError.check(git_commit_lookup(&commit, pointer, &oid), "read \(name)")
        guard let commit else { throw GitError(.notFound, "no commit on \(name)") }
        defer { git_commit_free(commit) }
        let checkout = CheckoutRecord()
        let code = checkout.run { options in git_checkout_tree(pointer, commit, &options) }
        guard code == 0 else { throw Self.refusedCheckout(checkout.failure(code, "switch to \(name)")) }
        try GitError.check(git_repository_set_head(pointer, "refs/heads/" + name), "point HEAD at \(name)")
    }

    /// A checkout the uncommitted changes are in the way of, as the page's
    /// own refusal; anything else stands as libgit2 reported it.
    static func refusedCheckout(_ error: GitError) -> GitError {
        error.kind == .conflict ? GitError(.dirtyTree, error.message) : error
    }

    /// The paths an index holds conflicts for, each once.
    static func conflictPaths(_ index: OpaquePointer) -> [String] {
        var iterator: OpaquePointer?
        guard git_index_conflict_iterator_new(&iterator, index) == 0, let iterator else { return [] }
        defer { git_index_conflict_iterator_free(iterator) }
        var paths: [String] = []
        while true {
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            let code = git_index_conflict_next(&ancestor, &ours, &theirs, iterator)
            if code == GIT_ITEROVER.rawValue { break }
            guard code == 0 else { break }
            guard let path = (theirs ?? ours ?? ancestor)?.pointee.path else { continue }
            let text = String(cString: path)
            if paths.last != text {
                paths.append(text)
            }
        }
        return paths
    }

    /// The merge commit on HEAD's branch, with the two parents, the index as
    /// the merge left it, and the message git writes for a merge of `branch`.
    private func mergeCommit(
        branch: String,
        parents: [String?],
        signature: UnsafeMutablePointer<git_signature>?
    ) throws -> GitMergeResult {
        var index: OpaquePointer?
        try GitError.check(git_repository_index(&index, pointer), "read the index")
        guard let index else { throw GitError(.failed, "the repository has no index") }
        defer { git_index_free(index) }
        var treeID = git_oid()
        try GitError.check(git_index_write_tree(&treeID, index), "write the merge's tree")
        var tree: OpaquePointer?
        try GitError.check(git_tree_lookup(&tree, pointer, &treeID), "read the merge's tree")
        guard let tree else { throw GitError(.failed, "the merge has no tree") }
        defer { git_tree_free(tree) }
        var parentObjects: [OpaquePointer?] = []
        let present = parents.compactMap(\.self)
        for parent in present {
            var oid = git_oid()
            try GitError.check(git_oid_fromstr(&oid, parent), "read \(parent)")
            var object: OpaquePointer?
            try GitError.check(git_commit_lookup(&object, pointer, &oid), "read \(parent)")
            parentObjects.append(object)
        }
        defer { parentObjects.forEach { git_commit_free($0) } }
        guard parentObjects.count >= 2 else {
            throw GitError(.invalid, "a merge commit needs both commits")
        }
        var commitID = git_oid()
        let message = "Merge branch '\(branch)'\n"
        let code = parentObjects.withUnsafeMutableBufferPointer { buffer in
            git_commit_create(
                &commitID,
                pointer,
                "HEAD",
                signature,
                signature,
                nil,
                message,
                tree,
                buffer.count,
                buffer.baseAddress
            )
        }
        try GitError.check(code, "commit the merge")
        git_repository_state_cleanup(pointer)
        return GitMergeResult(outcome: .merged, commit: Self.hex(&commitID))
    }

    /// The tag `name` a repository holds: its commit and whether it is
    /// annotated. Nil for a tag that points at no commit.
    private func tagTarget(_ name: String) throws -> (commit: String, isAnnotated: Bool)? {
        var reference: OpaquePointer?
        let code = git_reference_lookup(&reference, pointer, "refs/tags/" + name)
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try GitError.check(code, "read the tag \(name)")
        guard let reference else { return nil }
        defer { git_reference_free(reference) }
        var annotation: OpaquePointer?
        let isAnnotated = git_reference_peel(&annotation, reference, GIT_OBJECT_TAG) == 0
        git_object_free(annotation)
        var commit: OpaquePointer?
        guard git_reference_peel(&commit, reference, GIT_OBJECT_COMMIT) == 0, let commit,
              let id = git_object_id(commit)
        else { return nil }
        defer { git_object_free(commit) }
        return (Self.hex(id), isAnnotated)
    }

    /// `reference` without the namespace it lives in: `origin/main` for a
    /// remote-tracking one, a local branch's own name for one it tracks
    /// locally.
    static func shortReference(_ reference: String) -> String {
        for prefix in ["refs/remotes/", "refs/heads/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference
    }

    /// Drops `key` from the repository's own configuration; one that is not
    /// there is no error.
    private func dropLocalConfigValue(_ key: String) throws {
        guard !key.utf8.contains(0) else { throw GitError(.invalid, "bad configuration key") }
        var config: OpaquePointer?
        try GitError.check(git_repository_config(&config, pointer), "read the configuration")
        defer { git_config_free(config) }
        var local: OpaquePointer?
        try GitError.check(
            git_config_open_level(&local, config, GIT_CONFIG_LEVEL_LOCAL),
            "read the local configuration"
        )
        guard let local else { return }
        defer { git_config_free(local) }
        let code = git_config_delete_entry(local, key)
        if code != 0, code != GIT_ENOTFOUND.rawValue {
            throw GitError.last(code, "drop \(key)")
        }
    }
}
