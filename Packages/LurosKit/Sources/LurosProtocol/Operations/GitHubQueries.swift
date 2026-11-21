import Foundation

/// A repository's issues, as the agent reads them (`git_issue`).
///
/// Issues and pull requests are not git: nothing about them crosses the git
/// protocol libgit2 speaks, so these operations go to GitHub's REST API with
/// the github.com sign-in from Settings ▸ Git (`GitHubAPI`). Reading changes
/// nothing, so there is no approval to spend; what a request must carry is
/// checked here, before GitHub is asked (`problem`).
public struct IssueQueryRequest: OperationRequest {
    public typealias Response = IssueQueryResponse
    public static let operation = AppOperation.gitIssue

    public enum Action: String, Codable, Sendable, CaseIterable {
        /// The repository's issues, most recently updated first.
        case list
        /// One issue by its number.
        case read
    }

    /// `owner/name`, as the user named it.
    public var repository: String
    public var action: Action
    /// `read`: the issue's number.
    public var number: Int?
    /// `list`: open, closed or all. Default open.
    public var state: String?
    /// `list`: at most this many, from 1 to 100. Default 20.
    public var limit: Int?

    public init(
        repository: String,
        action: Action,
        number: Int? = nil,
        state: String? = nil,
        limit: Int? = nil,
    ) {
        self.repository = repository
        self.action = action
        self.number = number
        self.state = state
        self.limit = limit
    }

    /// Nil when the request is one GitHub could answer, else why not.
    public var problem: String? {
        guard GitHubName.isFullName(repository) else {
            return "Name the repository as owner/name, its owner's login and its name as GitHub spells them, such as octocat/hello-world."
        }
        switch action {
        case .list:
            if let state, !["open", "closed", "all"].contains(state) {
                return "state is open, closed or all."
            }
            if let limit, !(1 ... 100).contains(limit) {
                return "limit is a whole number from 1 to 100."
            }
        case .read:
            guard let number, number > 0 else {
                return "Reading one issue takes its number."
            }
        }
        return nil
    }
}

/// One issue, without its comments.
public struct IssueSummary: Codable, Sendable, Hashable, Equatable {
    public var number: Int
    public var title: String
    /// open or closed.
    public var state: String
    /// Its page on GitHub.
    public var url: String
    /// The login that opened it; nil once that account is gone.
    public var author: String?
    /// Its body; present for a read, absent in a list.
    public var body: String?
    /// To GitHub a pull request is an issue too, which this marks.
    public var isPullRequest: Bool
    /// How many comments it has.
    public var comments: Int?

    public init(
        number: Int,
        title: String,
        state: String,
        url: String,
        author: String? = nil,
        body: String? = nil,
        isPullRequest: Bool = false,
        comments: Int? = nil,
    ) {
        self.number = number
        self.title = title
        self.state = state
        self.url = url
        self.author = author
        self.body = body
        self.isPullRequest = isPullRequest
        self.comments = comments
    }
}

public struct IssueQueryResponse: Codable, Sendable, Equatable {
    /// `owner/name`, as the request named it.
    public var repository: String
    /// `list`: the issues, newest first.
    public var issues: [IssueSummary]?
    /// `read`: the issue.
    public var issue: IssueSummary?

    public init(repository: String, issues: [IssueSummary]? = nil, issue: IssueSummary? = nil) {
        self.repository = repository
        self.issues = issues
        self.issue = issue
    }
}

/// A repository's pull requests, as the agent reads them
/// (`git_pull_request`). Reading changes nothing; a merge, a review or a
/// close is not here, and never through libgit2 either.
public struct PullRequestQueryRequest: OperationRequest {
    public typealias Response = PullRequestQueryResponse
    public static let operation = AppOperation.gitPullRequest

    public enum Action: String, Codable, Sendable, CaseIterable {
        /// The repository's pull requests, most recently updated first.
        case list
        /// One pull request by its number.
        case read
    }

    /// `owner/name`, as the user named it.
    public var repository: String
    public var action: Action
    /// `read`: the pull request's number.
    public var number: Int?
    /// `list`: open, closed or all. Default open.
    public var state: String?
    /// `list`: at most this many, from 1 to 100. Default 20.
    public var limit: Int?

    public init(
        repository: String,
        action: Action,
        number: Int? = nil,
        state: String? = nil,
        limit: Int? = nil,
    ) {
        self.repository = repository
        self.action = action
        self.number = number
        self.state = state
        self.limit = limit
    }

    /// Nil when the request is one GitHub could answer, else why not.
    public var problem: String? {
        guard GitHubName.isFullName(repository) else {
            return "Name the repository as owner/name, its owner's login and its name as GitHub spells them, such as octocat/hello-world."
        }
        switch action {
        case .list:
            if let state, !["open", "closed", "all"].contains(state) {
                return "state is open, closed or all."
            }
            if let limit, !(1 ... 100).contains(limit) {
                return "limit is a whole number from 1 to 100."
            }
        case .read:
            guard let number, number > 0 else {
                return "Reading one pull request takes its number."
            }
        }
        return nil
    }
}

/// One pull request's shape and state, never its diff.
public struct PullRequestSummary: Codable, Sendable, Hashable, Equatable {
    public var number: Int
    public var title: String
    /// open, closed or merged.
    public var state: String
    /// Its page on GitHub.
    public var url: String
    /// The login that opened it; nil once that account is gone.
    public var author: String?
    /// Its body; present for a read, absent in a list.
    public var body: String?
    /// The branch it would merge: `owner:branch` for one from a fork.
    public var head: String
    /// The branch it merges into.
    public var base: String
    public var draft: Bool
    public var merged: Bool

    public init(
        number: Int,
        title: String,
        state: String,
        url: String,
        author: String? = nil,
        body: String? = nil,
        head: String,
        base: String,
        draft: Bool = false,
        merged: Bool = false,
    ) {
        self.number = number
        self.title = title
        self.state = state
        self.url = url
        self.author = author
        self.body = body
        self.head = head
        self.base = base
        self.draft = draft
        self.merged = merged
    }
}

public struct PullRequestQueryResponse: Codable, Sendable, Equatable {
    /// `owner/name`, as the request named it.
    public var repository: String
    /// `list`: the pull requests, newest first.
    public var pullRequests: [PullRequestSummary]?
    /// `read`: the pull request.
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

public extension LurosService {
    func gitIssue(_ request: IssueQueryRequest) async throws -> IssueQueryResponse {
        try await send(request)
    }

    func gitPullRequest(_ request: PullRequestQueryRequest) async throws -> PullRequestQueryResponse {
        try await send(request)
    }
}
