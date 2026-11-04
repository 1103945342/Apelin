import Foundation

// The repository's refs — branches and tags — and the two things that move
// them without a commit of their own: a merge and an abort.
//
// Read by the app's Git page (Apelin/Interface/Git), served by
// Apelind/Dispatch/GitHandler.swift from ApelinEnvironment's GitService over
// libgit2. Every path and name here is the app's to spell, never a command:
// the worker validates each one before it reaches libgit2.

/// One branch, local or on a remote.
public struct GitBranchRow: Codable, Sendable, Equatable, Hashable {
    /// The short name: `main`, or `origin/main` for a remote-tracking one.
    public var name: String
    /// Whether it lives on a remote.
    public var isRemote: Bool
    /// The local branch's upstream, `origin/main`; absent on a remote row and
    /// on a local branch that tracks nothing.
    public var upstream: String?
    /// Commits the local branch has that its upstream lacks.
    public var ahead: Int
    /// Commits the upstream has that the local branch lacks.
    public var behind: Int
    /// Whether this is the branch HEAD is on.
    public var isCurrent: Bool
    /// The commit it points at.
    public var commit: String
    /// The upstream is configured but no longer advertised (`[gone]`).
    public var isGone: Bool

    public init(
        name: String,
        isRemote: Bool,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        isCurrent: Bool = false,
        commit: String,
        isGone: Bool = false,
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

/// One tag.
public struct GitTagRow: Codable, Sendable, Equatable, Hashable {
    public var name: String
    /// The commit it points at, peeled when it is an annotated tag.
    public var commit: String
    public var isAnnotated: Bool

    public init(name: String, commit: String, isAnnotated: Bool) {
        self.name = name
        self.commit = commit
        self.isAnnotated = isAnnotated
    }
}

public struct GitBranchesRequest: OperationRequest {
    public typealias Response = GitBranchesResponse
    public static let operation = AppOperation.gitBranches
    public var projectID: String
    public init(projectID: String) {
        self.projectID = projectID
    }
}

public struct GitBranchesResponse: Codable, Sendable, Equatable {
    public var local: [GitBranchRow]
    public var remote: [GitBranchRow]
    public var tags: [GitTagRow]
    /// Nil on an unborn branch (`git init` with no commit yet).
    public var current: String?
    /// HEAD is on no branch.
    public var isDetached: Bool

    public init(
        local: [GitBranchRow] = [],
        remote: [GitBranchRow] = [],
        tags: [GitTagRow] = [],
        current: String? = nil,
        isDetached: Bool = false,
    ) {
        self.local = local
        self.remote = remote
        self.tags = tags
        self.current = current
        self.isDetached = isDetached
    }
}

public struct GitBranchCreateRequest: OperationRequest {
    public typealias Response = GitBranchCreateResponse
    public static let operation = AppOperation.gitBranchCreate
    public var projectID: String
    /// A name `GitBranchName` accepts.
    public var name: String
    /// Where it starts: a branch, a tag or a commit; nil is HEAD.
    public var startPoint: String?
    /// Checks it out, which is what the app's dialog offers.
    public var checkout: Bool
    public init(projectID: String, name: String, startPoint: String? = nil, checkout: Bool = false) {
        self.projectID = projectID
        self.name = name
        self.startPoint = startPoint
        self.checkout = checkout
    }
}

public struct GitBranchCreateResponse: Codable, Sendable, Equatable {
    public var name: String
    public init(name: String) {
        self.name = name
    }
}

public struct GitBranchCheckoutRequest: OperationRequest {
    public typealias Response = GitBranchCheckoutResponse
    public static let operation = AppOperation.gitBranchCheckout
    public var projectID: String
    /// A local branch's name, or a remote one's when `remote` is set.
    public var name: String
    /// The remote a remote-tracking branch is checked out from
    /// (`origin/main` → `origin` + `main`), which creates the local branch
    /// that tracks it.
    public var remote: String?
    public init(projectID: String, name: String, remote: String? = nil) {
        self.projectID = projectID
        self.name = name
        self.remote = remote
    }
}

public struct GitBranchCheckoutResponse: Codable, Sendable, Equatable {
    public var branch: String
    public init(branch: String) {
        self.branch = branch
    }
}

public struct GitBranchDeleteRequest: OperationRequest {
    public typealias Response = GitBranchDeleteResponse
    public static let operation = AppOperation.gitBranchDelete
    public var projectID: String
    public var name: String
    /// Deletes the branch on the remote (`origin/main` → `origin` + `main`).
    public var remote: String?
    public init(projectID: String, name: String, remote: String? = nil) {
        self.projectID = projectID
        self.name = name
        self.remote = remote
    }
}

public struct GitBranchDeleteResponse: Codable, Sendable, Equatable {
    public init() {}
}

public struct GitBranchRenameRequest: OperationRequest {
    public typealias Response = GitBranchRenameResponse
    public static let operation = AppOperation.gitBranchRename
    public var projectID: String
    public var from: String
    public var to: String
    public init(projectID: String, from: String, to: String) {
        self.projectID = projectID
        self.from = from
        self.to = to
    }
}

public struct GitBranchRenameResponse: Codable, Sendable, Equatable {
    public var name: String
    public init(name: String) {
        self.name = name
    }
}

public struct GitMergeRequest: OperationRequest {
    public typealias Response = GitMergeResponse
    public static let operation = AppOperation.gitMerge
    public var projectID: String
    /// The branch, tag or commit merged into the checked-out branch.
    public var branch: String
    /// A merge commit even when a fast-forward is possible.
    public var noFastForward: Bool
    public init(projectID: String, branch: String, noFastForward: Bool = false) {
        self.projectID = projectID
        self.branch = branch
        self.noFastForward = noFastForward
    }
}

public struct GitMergeResponse: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// Already up to date; nothing moved.
        case upToDate
        case fastForward
        case merged
        /// Conflicts left in the index, the merge still in progress.
        case conflict
    }
    public var outcome: Outcome
    /// The paths that conflict, when `outcome` is `conflict`.
    public var conflicts: [String]
    public var commit: String?
    public init(outcome: Outcome, conflicts: [String] = [], commit: String? = nil) {
        self.outcome = outcome
        self.conflicts = conflicts
        self.commit = commit
    }
}

public struct GitMergeAbortRequest: OperationRequest {
    public typealias Response = GitMergeAbortResponse
    public static let operation = AppOperation.gitMergeAbort
    public var projectID: String
    public init(projectID: String) {
        self.projectID = projectID
    }
}

public struct GitMergeAbortResponse: Codable, Sendable, Equatable {
    public init() {}
}

public struct GitTagCreateRequest: OperationRequest {
    public typealias Response = GitTagCreateResponse
    public static let operation = AppOperation.gitTagCreate
    public var projectID: String
    public var name: String
    /// The commit or ref the tag points at; nil is HEAD.
    public var commit: String?
    /// Annotated when there is one.
    public var message: String?
    public init(projectID: String, name: String, commit: String? = nil, message: String? = nil) {
        self.projectID = projectID
        self.name = name
        self.commit = commit
        self.message = message
    }
}

public struct GitTagCreateResponse: Codable, Sendable, Equatable {
    public var name: String
    public init(name: String) {
        self.name = name
    }
}

public struct GitTagDeleteRequest: OperationRequest {
    public typealias Response = GitTagDeleteResponse
    public static let operation = AppOperation.gitTagDelete
    public var projectID: String
    public var name: String
    public init(projectID: String, name: String) {
        self.projectID = projectID
        self.name = name
    }
}

public struct GitTagDeleteResponse: Codable, Sendable, Equatable {
    public init() {}
}

/// What a branch, tag or commit may be called: never a path, an option or an
/// address, and never something git itself refuses.
public enum GitBranchName {
    /// The rules `git check-ref-format --branch` applies, minus the ones that
    /// need a repository: no leading `-`, no `..`, no ASCII control, space,
    /// `~^:?*[\`, no trailing `/` or `.lock`, no `@{`, never empty.
    public static func problem(_ name: String) -> String? {
        if name.isEmpty { return "a branch name cannot be empty" }
        if name.count > 200 { return "a branch name cannot be longer than 200 characters" }
        if name.hasPrefix("-") { return "a branch name cannot start with a dash" }
        if name.hasPrefix("/") || name.hasSuffix("/") { return "a branch name cannot start or end with a slash" }
        if name.hasSuffix(".") { return "a branch name cannot end with a dot" }
        if name.contains("..") { return "a branch name cannot hold two dots in a row" }
        if name.contains("@{") { return "a branch name cannot hold @{" }
        if name.contains("//") { return "a branch name cannot hold two slashes in a row" }
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty { return "a branch name cannot hold an empty component" }
            if component.hasPrefix(".") { return "a component of a branch name cannot start with a dot" }
            if component.hasSuffix(".lock") { return "a component of a branch name cannot end with .lock" }
        }
        let forbidden = Set(" ~^:?*[\\\u{7f}")
        if name.contains(where: { $0.isASCII && ($0.asciiValue.map { $0 < 0x20 } ?? false) || forbidden.contains($0) }) {
            return "a branch name cannot hold a space or one of ~^:?*[\\"
        }
        return nil
    }

    /// Whether `name` is one a branch, a tag or a ref may have.
    public static func isValid(_ name: String) -> Bool {
        problem(name) == nil
    }
}

public extension ApelinService {
    func gitBranches(projectID: String) async throws -> GitBranchesResponse {
        try await send(GitBranchesRequest(projectID: projectID))
    }

    func gitBranchCreate(_ request: GitBranchCreateRequest) async throws -> GitBranchCreateResponse {
        try await send(request)
    }

    func gitBranchCheckout(_ request: GitBranchCheckoutRequest) async throws -> GitBranchCheckoutResponse {
        try await send(request)
    }

    func gitBranchDelete(_ request: GitBranchDeleteRequest) async throws {
        _ = try await send(request)
    }

    func gitBranchRename(_ request: GitBranchRenameRequest) async throws -> GitBranchRenameResponse {
        try await send(request)
    }

    func gitMerge(_ request: GitMergeRequest) async throws -> GitMergeResponse {
        try await send(request)
    }

    func gitMergeAbort(projectID: String) async throws {
        _ = try await send(GitMergeAbortRequest(projectID: projectID))
    }

    func gitTagCreate(_ request: GitTagCreateRequest) async throws -> GitTagCreateResponse {
        try await send(request)
    }

    func gitTagDelete(projectID: String, name: String) async throws {
        _ = try await send(GitTagDeleteRequest(projectID: projectID, name: name))
    }
}
