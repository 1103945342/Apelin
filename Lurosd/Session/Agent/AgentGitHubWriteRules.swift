import LurosCore
import LurosProtocol
import Foundation

/// An agent's `gitIssue` and `gitPullRequest` when the action changes GitHub
/// — a comment, an edit, a close or reopen of an issue, or a pull request
/// made, merged, closed or reviewed: what it changes, everyone who can see
/// the repository reads. So, as an issue opened is, each one asks under
/// Confirm and spends only the approval whose own `approvalRequested` named
/// exactly the same call (`detail.githubWrite`), once, never for the
/// session. Relaxed and Full let it through. The reads of the same
/// operations ask nobody and never reach here.
enum AgentGitHubWriteRules {
    /// What an issue edit's approval carries, rebuilt the same way
    /// `ToolRunner.githubWrite` builds it: the new title's mark, then the
    /// body's.
    private static func editText(title: String?, body: String?) -> String {
        (title ?? "") + "\n\n" + (body ?? "")
    }

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this issue request.
    static func covers(_ issue: IssueQueryRequest, asked: JSONValue) -> Bool {
        guard let write = asked["detail"]?["githubWrite"] else { return false }
        let text: String?
        switch issue.action {
        case .comment: text = issue.body
        case .edit: text = editText(title: issue.title, body: issue.body)
        default: text = nil
        }
        return matches(
            write,
            action: issue.action.rawValue,
            repository: issue.repository,
            number: issue.number,
            text: text,
            head: nil,
            base: nil,
            method: nil,
            verdict: nil,
        )
    }

    /// Whether `asked` approves exactly this pull request request.
    static func covers(_ pull: PullRequestQueryRequest, asked: JSONValue) -> Bool {
        guard let write = asked["detail"]?["githubWrite"] else { return false }
        return matches(
            write,
            action: pull.action.rawValue,
            repository: pull.repository,
            number: pull.number,
            text: pull.action == .create ? editText(title: pull.title, body: pull.body) : pull.body,
            head: pull.head,
            base: pull.base,
            method: pull.method,
            verdict: pull.verdict,
        )
    }

    private static func matches(
        _ write: JSONValue,
        action: String,
        repository: String,
        number: Int?,
        text: String?,
        head: String?,
        base: String?,
        method: String?,
        verdict: String?,
    ) -> Bool {
        write["action"]?.stringValue == action
            && write["repository"]?.stringValue == repository
            && write["number"]?.doubleValue == number.map(Double.init)
            && write["text"]?.stringValue == text
            && write["head"]?.stringValue == head
            && write["base"]?.stringValue == base
            && write["method"]?.stringValue == method
            && write["verdict"]?.stringValue == verdict
    }

    /// Nil when the session may make the call, else why not; under Confirm
    /// the approval that covers it is spent.
    static func authorize(_ issue: IssueQueryRequest, session: String?, registry: TaskRegistry) async -> LurosError? {
        guard isWrite(issue) else { return nil }
        return await spend(session: session, registry: registry) { covers(issue, asked: $0) } ?? nil
    }

    /// As above, for a pull request request.
    static func authorize(_ pull: PullRequestQueryRequest, session: String?, registry: TaskRegistry) async -> LurosError? {
        guard isWrite(pull) else { return nil }
        return await spend(session: session, registry: registry) { covers(pull, asked: $0) } ?? nil
    }

    static func isWrite(_ issue: IssueQueryRequest) -> Bool {
        [.comment, .close, .reopen, .edit].contains(issue.action)
    }

    static func isWrite(_ pull: PullRequestQueryRequest) -> Bool {
        [.create, .merge, .close, .review].contains(pull.action)
    }

    private static func spend(
        session: String?,
        registry: TaskRegistry,
        covers: (JSONValue) -> Bool,
    ) async -> LurosError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return LurosError(.denied, "no agent session for this worker")
        }
        guard entry.mode.asks else { return nil }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: covers) else {
            return LurosError(
                .denied,
                "approval required: the user has not approved this change on GitHub",
            )
        }
        return nil
    }
}
