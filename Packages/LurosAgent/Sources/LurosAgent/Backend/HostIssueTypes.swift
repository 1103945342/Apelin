import LurosProtocol
import Foundation

// MARK: - GitHub issues and pull requests, read

/// git_issue: the issues of one GitHub repository, or one of them.
public struct IssueQueryToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// `owner/name`, as the user named it.
    public var repository: String
    /// list or read.
    public var action: String
    public var number: Int?
    public var state: String?
    public var limit: Int?

    public init(
        context: HostCallContext,
        repository: String,
        action: String,
        number: Int? = nil,
        state: String? = nil,
        limit: Int? = nil,
    ) {
        self.context = context
        self.repository = repository
        self.action = action
        self.number = number
        self.state = state
        self.limit = limit
    }
}

public struct IssueQueryToolResponse: Sendable, Hashable, Codable {
    public var repository: String
    public var issues: [IssueSummary]?
    public var issue: IssueSummary?

    public init(repository: String, issues: [IssueSummary]? = nil, issue: IssueSummary? = nil) {
        self.repository = repository
        self.issues = issues
        self.issue = issue
    }
}

/// git_pull_request: the pull requests of one GitHub repository, or one of
/// them.
public struct PullRequestQueryToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// `owner/name`, as the user named it.
    public var repository: String
    /// list or read.
    public var action: String
    public var number: Int?
    public var state: String?
    public var limit: Int?

    public init(
        context: HostCallContext,
        repository: String,
        action: String,
        number: Int? = nil,
        state: String? = nil,
        limit: Int? = nil,
    ) {
        self.context = context
        self.repository = repository
        self.action = action
        self.number = number
        self.state = state
        self.limit = limit
    }
}

public struct PullRequestQueryToolResponse: Sendable, Hashable, Codable {
    public var repository: String
    public var pullRequests: [PullRequestSummary]?
    public var pullRequest: PullRequestSummary?

    public init(
        repository: String,
        pullRequests: [PullRequestSummary]? = nil,
        pullRequest: PullRequestSummary? = nil,
    ) {
        self.repository = repository
        self.pullRequests = pullRequests
        self.pullRequest = pullRequest
    }
}

/// A backend without GitHub behind it (a test double, a live test).
public extension AgentHostBackend {
    func gitIssue(_: IssueQueryToolRequest) async throws -> IssueQueryToolResponse {
        throw ToolDeniedError(message: "GitHub's issues are not available here")
    }

    func gitPullRequest(_: PullRequestQueryToolRequest) async throws -> PullRequestQueryToolResponse {
        throw ToolDeniedError(message: "GitHub's pull requests are not available here")
    }
}
