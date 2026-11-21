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
        /// A comment added to one issue.
        case comment
        /// One issue closed.
        case close
        /// One issue reopened.
        case reopen
    }

    /// `owner/name`, as the user named it.
    public var repository: String
    public var action: Action
    /// `read`, `comment`, `close` and `reopen`: the issue's number.
    public var number: Int?
    /// `list`: open, closed or all. Default open.
    public var state: String?
    /// `list`: at most this many, from 1 to 100. Default 20.
    public var limit: Int?
    /// `comment`: the comment's text, which GitHub takes as Markdown.
    public var body: String?

    public init(
        repository: String,
        action: Action,
        number: Int? = nil,
        state: String? = nil,
        limit: Int? = nil,
        body: String? = nil,
    ) {
        self.repository = repository
        self.action = action
        self.number = number
        self.state = state
        self.limit = limit
        self.body = body
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
        case .read, .close, .reopen:
            guard let number, number > 0 else {
                return "Name the issue by its number."
            }
        case .comment:
            guard let number, number > 0 else {
                return "Name the issue by its number."
            }
            let text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                return "A comment needs its text."
            }
            guard text.utf8.count <= 65536 else {
                return "A comment is at most 64 KB of text."
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
    /// `read`, `comment`, `close` and `reopen`: the issue as it stands.
    public var issue: IssueSummary?
    /// `comment`: the comment's page on GitHub.
    public var commentURL: String?

    public init(
        repository: String,
        issues: [IssueSummary]? = nil,
        issue: IssueSummary? = nil,
        commentURL: String? = nil,
    ) {
        self.repository = repository
        self.issues = issues
        self.issue = issue
        self.commentURL = commentURL
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
        /// A pull request from `head` into `base`.
        case create
        /// One pull request merged on GitHub.
        case merge
    }

    /// `owner/name`, as the user named it.
    public var repository: String
    public var action: Action
    /// `read` and `merge`: the pull request's number.
    public var number: Int?
    /// `list`: open, closed or all. Default open.
    public var state: String?
    /// `list`: at most this many, from 1 to 100. Default 20.
    public var limit: Int?
    /// `create`: its title.
    public var title: String?
    /// `create`: its body, Markdown.
    public var body: String?
    /// `create`: the branch it comes from, `owner:branch` for a fork.
    public var head: String?
    /// `create`: the branch it merges into.
    public var base: String?
    /// `create`: opened as a draft.
    public var draft: Bool?
    /// `merge`: merge, squash or rebase. Default merge.
    public var method: String?

    public init(
        repository: String,
        action: Action,
        number: Int? = nil,
        state: String? = nil,
        limit: Int? = nil,
        title: String? = nil,
        body: String? = nil,
        head: String? = nil,
        base: String? = nil,
        draft: Bool? = nil,
        method: String? = nil,
    ) {
        self.repository = repository
        self.action = action
        self.number = number
        self.state = state
        self.limit = limit
        self.title = title
        self.body = body
        self.head = head
        self.base = base
        self.draft = draft
        self.method = method
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
                return "Name the pull request by its number."
            }
        case .create:
            for (value, name) in [(title, "A title"), (head, "A head branch"), (base, "A base branch")] {
                guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return "\(name) is needed to open a pull request."
                }
            }
        case .merge:
            guard let number, number > 0 else {
                return "Name the pull request by its number."
            }
            if let method, !["merge", "squash", "rebase"].contains(method) {
                return "method is merge, squash or rebase."
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
    /// `read`, `create` and `merge`: the pull request as it stands.
    public var pullRequest: PullRequestSummary?
    /// `merge`: whether GitHub merged it.
    public var merged: Bool?
    /// `merge`: GitHub's own words about the merge.
    public var message: String?

    public init(
        repository: String,
        pullRequests: [PullRequestSummary]? = nil,
        pullRequest: PullRequestSummary? = nil,
        merged: Bool? = nil,
        message: String? = nil,
    ) {
        self.repository = repository
        self.pullRequests = pullRequests
        self.pullRequest = pullRequest
        self.merged = merged
        self.message = message
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
