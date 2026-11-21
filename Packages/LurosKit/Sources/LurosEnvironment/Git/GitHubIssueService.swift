import LurosProtocol
import Foundation

/// An issue opened on a GitHub repository the user chose
/// (`GitIssueCreateRequest`; owner, 2026-10-30) with the github.com sign-in
/// the user made in Settings ▸ Git: the repository's shape is checked, and
/// the title and body as every public issue's are (`IssueReport`), before
/// the sign-in is read, so a refused one reaches nobody; the footer below
/// the body is `IssueReport`'s. Only the repository the request names is
/// asked, and GitHub's refusals say what blocks it (`GitHubAPI.createIssue`).
public struct GitHubIssueService: Sendable {
    let credentials: any GitCredentialStore
    /// GitHub's API; a test answers for it.
    var exchange: GitHubAPI.Exchange = GitHubAPI.live
    /// The checks and the footer; a test sets the host name and iOS version.
    var report: IssueReport

    public init(layout: EnvironmentLayout, credentials: any GitCredentialStore) {
        self.credentials = credentials
        report = IssueReport(layout: layout)
    }

    public func create(_ request: GitIssueCreateRequest) async throws -> GitIssueCreateResponse {
        if let problem = request.problem {
            throw LurosError(.badRequest, problem)
        }
        let title = request.title.trimmingCharacters(in: .whitespaces)
        if let problem = report.problem(title: title, body: request.body) {
            throw LurosError(.badRequest, problem)
        }
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        let issue = try await api.createIssue(
            request.repository,
            title: title,
            body: FeedbackRules.issueBody(request.body, footer: report.footer()),
        )
        return GitIssueCreateResponse(number: issue.number, url: issue.htmlURL, repository: request.repository)
    }

    /// The repository's issues, or one of them, as the agent reads them
    /// (`git_issue`). Reading changes nothing, so no approval is spent; the
    /// request is checked before the sign-in is read.
    public func query(_ request: IssueQueryRequest) async throws -> IssueQueryResponse {
        if let problem = request.problem {
            throw LurosError(.badRequest, problem)
        }
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        switch request.action {
        case .list:
            let rows = try await api.listIssues(
                request.repository,
                state: request.state ?? "open",
                limit: request.limit ?? 20,
            )
            return IssueQueryResponse(repository: request.repository, issues: rows.map(Self.summary))
        case .read:
            guard let number = request.number else {
                throw LurosError(.badRequest, "Reading one issue takes its number.")
            }
            let detail = try await api.issue(request.repository, number: number)
            return IssueQueryResponse(
                repository: request.repository,
                issue: IssueSummary(
                    number: detail.number,
                    title: detail.title,
                    state: detail.state,
                    url: detail.htmlURL,
                    author: detail.user?.login,
                    body: detail.body,
                    isPullRequest: detail.pullRequest != nil,
                ),
            )
        }
    }

    /// The repository's pull requests, or one of them (`git_pull_request`).
    /// A pull request's code is a ref libgit2 can fetch; the request itself,
    /// its reviews and its merge are GitHub's and only GitHub's.
    public func query(_ request: PullRequestQueryRequest) async throws -> PullRequestQueryResponse {
        if let problem = request.problem {
            throw LurosError(.badRequest, problem)
        }
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        switch request.action {
        case .list:
            let rows = try await api.listPulls(
                request.repository,
                state: request.state ?? "open",
                limit: request.limit ?? 20,
            )
            return PullRequestQueryResponse(repository: request.repository, pullRequests: rows.map(Self.summary))
        case .read:
            guard let number = request.number else {
                throw LurosError(.badRequest, "Reading one pull request takes its number.")
            }
            return PullRequestQueryResponse(
                repository: request.repository,
                pullRequest: Self.summary(try await api.pull(request.repository, number: number)),
            )
        }
    }

    private static func summary(_ row: GitHubAPI.IssueRow) -> IssueSummary {
        IssueSummary(
            number: row.number,
            title: row.title,
            state: row.state,
            url: row.htmlURL,
            author: row.user?.login,
            body: row.body,
            isPullRequest: row.pullRequest != nil,
            comments: row.comments,
        )
    }

    private static func summary(_ row: GitHubAPI.PullRow) -> PullRequestSummary {
        PullRequestSummary(
            number: row.number,
            title: row.title,
            state: row.merged == true ? "merged" : row.state,
            url: row.htmlURL,
            author: row.user?.login,
            body: row.body,
            head: row.head.label ?? row.head.ref,
            base: row.base.ref,
            draft: row.draft ?? false,
            merged: row.merged ?? false,
        )
    }
}
