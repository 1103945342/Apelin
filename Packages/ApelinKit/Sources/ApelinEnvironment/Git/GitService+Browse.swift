import ApelinCore
import ApelinGit
import ApelinProtocol
import Foundation

/// The git page's own operations, all of them the app's
/// (`AppOperation.gitBranches` through `gitStashClear`): the repository's
/// refs, its history, the work tree's changes taken back, a reset and the
/// stashes. Each one names a project, resolves it as every git call does,
/// and turns a libgit2 refusal into the wire's error with the reason a
/// screen acts on.
public extension GitService {
    // MARK: Refs

    func branches(_ request: GitBranchesRequest) throws -> GitBranchesResponse {
        let repository = try open(request.projectID).repository
        let branches = try mapped { try repository.branches() }
        return GitBranchesResponse(
            local: branches.local.map { Self.row($0) },
            remote: branches.remote.map { Self.row($0) },
            tags: branches.tags.map { GitTagRow(name: $0.name, commit: $0.commit, isAnnotated: $0.isAnnotated) },
            current: branches.current,
            isDetached: branches.isDetached,
        )
    }

    func createBranch(_ request: GitBranchCreateRequest) throws -> GitBranchCreateResponse {
        let repository = try open(request.projectID).repository
        try Self.checkBranchName(request.name)
        let name = try mapped {
            try repository.createBranch(request.name, startPoint: request.startPoint, checkout: request.checkout)
        }
        return GitBranchCreateResponse(name: name)
    }

    func checkoutBranch(_ request: GitBranchCheckoutRequest) throws -> GitBranchCheckoutResponse {
        let repository = try open(request.projectID).repository
        try Self.checkBranchName(request.name)
        if let remote = request.remote {
            try Self.checkRemoteName(remote)
        }
        let branch = try mapped { try repository.checkoutBranch(request.name, remote: request.remote) }
        return GitBranchCheckoutResponse(branch: branch)
    }

    func deleteBranch(_ request: GitBranchDeleteRequest) throws -> GitBranchDeleteResponse {
        let repository = try open(request.projectID).repository
        try Self.checkBranchName(request.name)
        if let remote = request.remote {
            try Self.checkRemoteName(remote)
            // A deletion on a remote goes where a push does, so its address
            // is held to the same rule before anything is sent.
            guard let url = repository.remoteURL(remote) else {
                throw ApelinError(.notFound, "no remote \(remote.debugDescription)", reason: .noSuchRemote)
            }
            try checkRemoteURL(url)
            try mapped {
                try repository.deleteRemoteBranch(request.name, remote: remote, credentials: credentialLookup)
            }
        } else {
            try mapped { try repository.deleteBranch(request.name, force: request.force ?? true) }
        }
        return GitBranchDeleteResponse()
    }

    func renameBranch(_ request: GitBranchRenameRequest) throws -> GitBranchRenameResponse {
        let repository = try open(request.projectID).repository
        try Self.checkBranchName(request.from)
        try Self.checkBranchName(request.to)
        let name = try mapped { try repository.renameBranch(request.from, to: request.to) }
        return GitBranchRenameResponse(name: name)
    }

    func merge(_ request: GitMergeRequest) throws -> GitMergeResponse {
        let repository = try open(request.projectID).repository
        guard !request.branch.isEmpty else { throw ApelinError(.badRequest, "name the branch to merge") }
        // Only a merge commit needs an identity, so a fast-forward is not
        // refused for a missing one; the repository asks when it needs one.
        let author = try? author(name: nil, email: nil, repository: repository)
        let result = try mapped {
            try repository.merge(request.branch, noFastForward: request.noFastForward, author: author)
        }
        switch result.outcome {
        case .upToDate:
            return GitMergeResponse(outcome: .upToDate)
        case .fastForward:
            return GitMergeResponse(outcome: .fastForward, commit: result.commit)
        case .merged:
            return GitMergeResponse(outcome: .merged, commit: result.commit)
        case .conflict:
            return GitMergeResponse(outcome: .conflict, conflicts: result.conflicts)
        }
    }

    func abortMerge(_ request: GitMergeAbortRequest) throws -> GitMergeAbortResponse {
        let repository = try open(request.projectID).repository
        try mapped { try repository.abortMerge() }
        return GitMergeAbortResponse()
    }

    func createTag(_ request: GitTagCreateRequest) throws -> GitTagCreateResponse {
        let repository = try open(request.projectID).repository
        if let problem = GitBranchName.problem(request.name) {
            throw ApelinError(.badRequest, problem)
        }
        // An annotated tag records who made it; a lightweight one records
        // nothing, so only the annotated kind asks for an identity.
        let tagger: GitSignature?
        if request.message == nil {
            tagger = nil
        } else {
            tagger = try author(name: nil, email: nil, repository: repository)
        }
        let name = try mapped {
            try repository.createTag(request.name, commit: request.commit, message: request.message, author: tagger)
        }
        return GitTagCreateResponse(name: name)
    }

    func deleteTag(_ request: GitTagDeleteRequest) throws -> GitTagDeleteResponse {
        let repository = try open(request.projectID).repository
        if let problem = GitBranchName.problem(request.name) {
            throw ApelinError(.badRequest, problem)
        }
        try mapped { try repository.deleteTag(request.name) }
        return GitTagDeleteResponse()
    }

    // MARK: History

    func log(_ request: GitLogRequest) throws -> GitLogResponse {
        let repository = try open(request.projectID).repository
        // A page larger than this is not a page the graph can draw, and a
        // walk longer than it is work nobody asked for.
        let limit = min(max(request.limit, 0), 1000)
        let page = try mapped { try repository.log(limit: limit, skip: max(request.skip, 0)) }
        return GitLogResponse(commits: page.commits.map { Self.row($0) }, hasMore: page.hasMore)
    }

    func commitDetail(_ request: GitCommitDetailRequest) throws -> GitCommitDetailResponse {
        let repository = try open(request.projectID).repository
        let detail = try mapped { try repository.commitDetail(request.commit) }
        return GitCommitDetailResponse(
            id: detail.id,
            message: detail.message,
            authorName: detail.authorName,
            authorEmail: detail.authorEmail,
            authoredAt: detail.authoredAt,
            files: detail.files.map { GitChangedFile(path: $0.path, status: $0.status, oldPath: $0.oldPath) },
        )
    }

    func commitFileDiff(_ request: GitCommitFileDiffRequest) throws -> GitCommitFileDiffResponse {
        let (project, repository) = try open(request.projectID)
        let path = try projects.checkRelative(request.path, in: project)
        return try GitCommitFileDiffResponse(diff: mapped { try repository.diff(of: request.commit, path: path) })
    }

    func fileVersions(_ request: GitFileVersionsRequest) throws -> GitFileVersionsResponse {
        let (project, repository) = try open(request.projectID)
        let path = try projects.checkRelative(request.path, in: project)
        let versions = try mapped { try repository.fileVersions(path, staged: request.staged) }
        return GitFileVersionsResponse(
            old: versions.old,
            new: versions.new,
            isBinary: versions.isBinary,
            truncated: versions.truncated,
        )
    }

    // MARK: Work tree

    func restore(_ request: GitRestoreRequest) throws -> GitRestoreResponse {
        let (project, repository) = try open(request.projectID)
        let paths = try browsePaths(request.paths, in: project)
        let source: GitRestoreSource = request.source == .head ? .head : .index
        try mapped { try repository.restore(paths, from: source) }
        return GitRestoreResponse()
    }

    func deletePaths(_ request: GitDeletePathsRequest) throws -> GitDeletePathsResponse {
        let (project, repository) = try open(request.projectID)
        let paths = try browsePaths(request.paths, in: project)
        try mapped { try repository.deleteUntracked(paths) }
        return GitDeletePathsResponse()
    }

    func appendIgnore(_ request: GitIgnoreAppendRequest) throws -> GitIgnoreAppendResponse {
        let repository = try open(request.projectID).repository
        return GitIgnoreAppendResponse(added: try mapped { try repository.appendIgnore(request.pattern) })
    }

    func reset(_ request: GitResetRequest) throws -> GitResetResponse {
        let repository = try open(request.projectID).repository
        let mode: GitResetMode = request.mode == .soft ? .soft : .mixed
        return GitResetResponse(commit: try mapped { try repository.reset(to: request.commit, mode: mode) })
    }

    // MARK: Stashes

    func stashList(_ request: GitStashListRequest) throws -> GitStashListResponse {
        let repository = try open(request.projectID).repository
        let stashes = try mapped { try repository.stashList() }
        return GitStashListResponse(stashes: stashes.map {
            GitStashRow(index: $0.index, message: $0.message, branch: $0.branch, commit: $0.commit)
        })
    }

    func stashSave(_ request: GitStashSaveRequest) throws -> GitStashSaveResponse {
        let repository = try open(request.projectID).repository
        let stasher = try author(name: nil, email: nil, repository: repository)
        let message = request.message.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        return GitStashSaveResponse(saved: try mapped {
            try repository.stashSave(message: message, includeUntracked: request.includeUntracked, author: stasher)
        })
    }

    func stashApply(_ request: GitStashApplyRequest) throws -> GitStashApplyResponse {
        let repository = try open(request.projectID).repository
        return GitStashApplyResponse(conflicts: try mapped {
            try repository.stashApply(request.index, pop: request.pop)
        })
    }

    func stashDrop(_ request: GitStashDropRequest) throws -> GitStashDropResponse {
        let repository = try open(request.projectID).repository
        try mapped { try repository.stashDrop(request.index) }
        return GitStashDropResponse()
    }

    func stashClear(_ request: GitStashClearRequest) throws -> GitStashClearResponse {
        let repository = try open(request.projectID).repository
        try mapped { try repository.stashClear() }
        return GitStashClearResponse()
    }

    // MARK: Helpers

    /// A branch name the page may act on: `GitBranchName`'s rules, then
    /// libgit2's own.
    static func checkBranchName(_ name: String) throws {
        if let problem = GitBranchName.problem(name) {
            throw ApelinError(.badRequest, problem)
        }
        guard GitRepository.isValidBranchName(name) else {
            throw ApelinError(.badRequest, "\(name.debugDescription) is not a branch name")
        }
    }

    /// The request's paths, each checked against the project as every git
    /// call checks one.
    private func browsePaths(_ paths: [String], in project: ProjectLocator.Project) throws -> [String] {
        guard !paths.isEmpty else { throw ApelinError(.badRequest, "no paths") }
        return try paths.map { try projects.checkRelative($0, in: project) }
    }

    private static func row(_ branch: GitBranch) -> GitBranchRow {
        GitBranchRow(
            name: branch.name,
            isRemote: branch.isRemote,
            upstream: branch.upstream,
            ahead: branch.ahead,
            behind: branch.behind,
            isCurrent: branch.isCurrent,
            commit: branch.commit,
            isGone: branch.isGone,
        )
    }

    private static func row(_ commit: GitCommit) -> GitCommitRow {
        GitCommitRow(
            id: commit.id,
            shortID: commit.shortID,
            parents: commit.parents,
            summary: commit.summary,
            authorName: commit.authorName,
            authorEmail: commit.authorEmail,
            authoredAt: commit.authoredAt,
            refs: commit.refs.map { GitRefRow(name: $0.name, kind: kind($0.kind)) },
        )
    }

    private static func kind(_ kind: GitCommitRef.Kind) -> GitRefRow.Kind {
        switch kind {
        case .local: return .local
        case .remote: return .remote
        case .tag: return .tag
        case .head: return .head
        }
    }
}

/// What a git refusal names beyond its code, for the status page to act on
/// rather than to repeat in words. `notARepository` and the remote ones are
/// `Operations/Git.swift`'s, `notFastForward` and `rejected` `GitService`'s.
extension ApelinError.Reason {
    /// `conflict`: a checkout or a merge would overwrite uncommitted work.
    static let dirtyTree = Self(rawValue: "dirtyTree")
    /// `notFound`: the path is not in the index, so no version of it is
    /// committed to bring back.
    static let notTracked = Self(rawValue: "notTracked")
    /// `notFound`: the path is in the index, so a deletion would take what
    /// git is keeping.
    static let tracked = Self(rawValue: "tracked")
}
