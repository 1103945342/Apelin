import LurosAgent
import LurosProtocol
import Foundation

/// git_issue and git_pull_request → GitHub's REST API, through the session
/// host and the github.com sign-in the user made in Settings ▸ Git. Both
/// only read: no approval is spent, and nothing on GitHub changes.
public extension ChannelHostBackend {
    func gitIssue(_ request: IssueQueryToolRequest) async throws -> IssueQueryToolResponse {
        guard let action = IssueQueryRequest.Action(rawValue: request.action) else {
            throw GitToolFailure(message: "action is list or read")
        }
        let response: IssueQueryResponse
        do {
            response = try await service.gitIssue(IssueQueryRequest(
                repository: request.repository,
                action: action,
                number: request.number,
                state: request.state,
                limit: request.limit,
                body: request.body,
                title: request.title,
            ))
        } catch let error as LurosError where error.reason == .authenticationRequired {
            throw GitToolFailure(message: Self.issueSignInNeededToRead)
        } catch let error as LurosError {
            throw GitToolFailure(message: error.message)
        }
        return IssueQueryToolResponse(
            repository: response.repository,
            issues: response.issues,
            issue: response.issue,
            commentURL: response.commentURL,
        )
    }

    func gitPullRequest(_ request: PullRequestQueryToolRequest) async throws -> PullRequestQueryToolResponse {
        guard let action = PullRequestQueryRequest.Action(rawValue: request.action) else {
            throw GitToolFailure(message: "action is list or read")
        }
        let response: PullRequestQueryResponse
        do {
            response = try await service.gitPullRequest(PullRequestQueryRequest(
                repository: request.repository,
                action: action,
                number: request.number,
                state: request.state,
                limit: request.limit,
                title: request.title,
                body: request.body,
                head: request.head,
                base: request.base,
                draft: request.draft,
                method: request.method,
                verdict: request.verdict,
            ))
        } catch let error as LurosError where error.reason == .authenticationRequired {
            throw GitToolFailure(message: Self.issueSignInNeededToRead)
        } catch let error as LurosError {
            throw GitToolFailure(message: error.message)
        }
        return PullRequestQueryToolResponse(
            repository: response.repository,
            pullRequests: response.pullRequests,
            pullRequest: response.pullRequest,
            merged: response.merged,
            message: response.message,
        )
    }

    static let issueSignInNeededToRead = "GitHub authorization is needed. Ask the user to Sign In with GitHub in Settings ▸ Git, then try again."
}
