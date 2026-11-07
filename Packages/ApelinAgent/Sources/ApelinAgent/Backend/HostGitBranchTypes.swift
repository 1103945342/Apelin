import ApelinProtocol
import Foundation

/// Typed calls on the session's project; the worker supplies its own project ID.
public struct GitBranchesToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public init(context: HostCallContext) { self.context = context }
}

public struct GitBranchCreateToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var name: String
    public var startPoint: String?
    public var checkout: Bool
    public init(context: HostCallContext, name: String, startPoint: String? = nil, checkout: Bool = false) {
        self.context = context
        self.name = name
        self.startPoint = startPoint
        self.checkout = checkout
    }
}

public struct GitBranchCheckoutToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var name: String
    public var remote: String?
    public init(context: HostCallContext, name: String, remote: String? = nil) {
        self.context = context
        self.name = name
        self.remote = remote
    }
}

public struct GitBranchRenameToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var from: String
    public var to: String
    public init(context: HostCallContext, from: String, to: String) {
        self.context = context
        self.from = from
        self.to = to
    }
}

public struct GitMergeToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var branch: String
    public var noFastForward: Bool
    public init(context: HostCallContext, branch: String, noFastForward: Bool = false) {
        self.context = context
        self.branch = branch
        self.noFastForward = noFastForward
    }
}

public struct GitMergeAbortToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public init(context: HostCallContext) { self.context = context }
}

public struct GitLogToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var limit: Int
    public var skip: Int
    public init(context: HostCallContext, limit: Int = 50, skip: Int = 0) {
        self.context = context
        self.limit = limit
        self.skip = skip
    }
}

public struct GitCommitDetailToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var commit: String
    public init(context: HostCallContext, commit: String) {
        self.context = context
        self.commit = commit
    }
}

/// Test and offline backends may have no repository behind them.
public extension AgentHostBackend {
    func gitBranches(_: GitBranchesToolRequest) async throws -> GitBranchesResponse {
        throw ToolDeniedError(message: "branches are not available here")
    }

    func gitBranchCreate(_: GitBranchCreateToolRequest) async throws -> GitBranchCreateResponse {
        throw ToolDeniedError(message: "creating branches is not available here")
    }

    func gitBranchCheckout(_: GitBranchCheckoutToolRequest) async throws -> GitBranchCheckoutResponse {
        throw ToolDeniedError(message: "switching branches is not available here")
    }

    func gitBranchRename(_: GitBranchRenameToolRequest) async throws -> GitBranchRenameResponse {
        throw ToolDeniedError(message: "renaming branches is not available here")
    }

    func gitMerge(_: GitMergeToolRequest) async throws -> GitMergeResponse {
        throw ToolDeniedError(message: "merging branches is not available here")
    }

    func gitMergeAbort(_: GitMergeAbortToolRequest) async throws -> GitMergeAbortResponse {
        throw ToolDeniedError(message: "aborting a merge is not available here")
    }

    func gitLog(_: GitLogToolRequest) async throws -> GitLogResponse {
        throw ToolDeniedError(message: "git history is not available here")
    }

    func gitCommitDetail(_: GitCommitDetailToolRequest) async throws -> GitCommitDetailResponse {
        throw ToolDeniedError(message: "commit details are not available here")
    }
}
