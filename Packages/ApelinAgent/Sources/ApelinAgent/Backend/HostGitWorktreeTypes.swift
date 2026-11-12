import ApelinProtocol
import Foundation

/// Typed calls on the session's project for the refs and the work tree the
/// agent may change: a tag, a stash, a path's changes discarded, and the
/// untracked files a clean takes away. The worker supplies its own project ID.
public struct GitTagToolRequest: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Hashable, Codable {
        case create
        case delete
    }

    public var context: HostCallContext
    public var action: Action
    public var name: String
    /// The commit or ref the tag points at; nil is HEAD.
    public var commit: String?
    /// The message an annotated tag carries.
    public var message: String?
    /// With create: the remote the new tag is pushed to. With delete: the
    /// remote whose tag goes; the local one stays.
    public var remote: String?
    public init(
        context: HostCallContext,
        action: Action,
        name: String,
        commit: String? = nil,
        message: String? = nil,
        remote: String? = nil,
    ) {
        self.context = context
        self.action = action
        self.name = name
        self.commit = commit
        self.message = message
        self.remote = remote
    }
}

public struct GitTagToolResponse: Sendable, Hashable, Codable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct GitStashToolRequest: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Hashable, Codable {
        case list
        case save
        case apply
        case drop
        case clear
    }

    public var context: HostCallContext
    public var action: Action
    /// For save: what the stash is called.
    public var message: String?
    /// For save: untracked files go in with it.
    public var includeUntracked: Bool
    /// For apply: the stash's index; the newest is 0.
    public var index: Int
    /// For apply: pop it, dropping the stash once it applied.
    public var pop: Bool
    public init(
        context: HostCallContext,
        action: Action,
        message: String? = nil,
        includeUntracked: Bool = false,
        index: Int = 0,
        pop: Bool = false,
    ) {
        self.context = context
        self.action = action
        self.message = message
        self.includeUntracked = includeUntracked
        self.index = index
        self.pop = pop
    }
}

public struct GitStashToolResponse: Sendable, Hashable, Codable {
    public var stashes: [GitStashRow]
    /// What apply answered as conflicts, path by path.
    public var conflicts: [String]
    public var saved: Bool
    public init(stashes: [GitStashRow] = [], conflicts: [String] = [], saved: Bool = false) {
        self.stashes = stashes
        self.conflicts = conflicts
        self.saved = saved
    }
}

public struct GitRestoreToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// From where the paths are taken back: the index, or HEAD.
    public var source: GitRestoreRequest.Source
    public var paths: [String]
    public init(context: HostCallContext, source: GitRestoreRequest.Source, paths: [String]) {
        self.context = context
        self.source = source
        self.paths = paths
    }
}

public struct GitCleanToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// The untracked files and empty folders the clean takes away.
    public var paths: [String]
    public init(context: HostCallContext, paths: [String]) {
        self.context = context
        self.paths = paths
    }
}

/// Test and offline backends may have no repository behind them.
public extension AgentHostBackend {
    func gitTag(_: GitTagToolRequest) async throws -> GitTagToolResponse {
        throw ToolDeniedError(message: "tags are not available here")
    }

    func gitStash(_: GitStashToolRequest) async throws -> GitStashToolResponse {
        throw ToolDeniedError(message: "stashes are not available here")
    }

    func gitRestore(_: GitRestoreToolRequest) async throws -> GitRestoreResponse {
        throw ToolDeniedError(message: "restoring paths is not available here")
    }

    func gitClean(_: GitCleanToolRequest) async throws -> GitDeletePathsResponse {
        throw ToolDeniedError(message: "cleaning untracked files is not available here")
    }
}
