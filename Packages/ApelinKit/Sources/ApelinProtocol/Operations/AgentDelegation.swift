import Foundation

/// Delegation authority is kept by the host, not in a worker's todo list.
public struct AgentDelegationRequest: OperationRequest {
    public typealias Response = AgentDelegationResponse
    public static let operation = AppOperation.agentDelegation
    public enum Action: String, Codable, Sendable {
        case read, admit, blocked, review, accept, amend, check
        case acceptAssignment, cancelAssignment, failAssignment, seal
    }
    public var sessionID: String
    public var action: Action
    public var expectedRevision: UInt64?
    public var tool: String?
    public var path: String?
    public var step: AgentDelegationBrief.Step?
    public var note: String?
    /// What the child says it produced, on `review` and `blocked`: its own
    /// claim, never a check receipt. Nil leaves the ledger's claims alone.
    public var outputs: [AgentAssignment.Output]?
    /// On `amend`: what the assignment is now measured against. A step that
    /// changes what "done" means restates it here, and the member's old
    /// receipts stop counting. Nil keeps the acceptance as it was.
    public var acceptance: [String]?

    public init(sessionID: String, action: Action, expectedRevision: UInt64? = nil,
                tool: String? = nil, path: String? = nil, step: AgentDelegationBrief.Step? = nil,
                note: String? = nil, outputs: [AgentAssignment.Output]? = nil,
                acceptance: [String]? = nil) {
        self.sessionID = sessionID
        self.action = action
        self.expectedRevision = expectedRevision
        self.tool = tool
        self.path = path
        self.step = step
        self.note = note
        self.outputs = outputs
        self.acceptance = acceptance
    }
}

public struct AgentDelegationResponse: Codable, Sendable {
    /// Nil only for a session with no delegated assignment. Missing or corrupt
    /// state of a constrained session is an error, never an unrestricted plan.
    public var plan: AgentDelegationPlan?
    /// The opener's complete account; turn completion never implies acceptance.
    public var ledger: AgentAssignmentLedger?
    public init(plan: AgentDelegationPlan?, ledger: AgentAssignmentLedger? = nil) {
        self.plan = plan
        self.ledger = ledger
    }
}

public extension ApelinService {
    func agentDelegation(_ request: AgentDelegationRequest) async throws -> AgentDelegationResponse {
        try await send(request)
    }
}

/// A deliberately closed first set. A capability in the brief does NOT make
/// an opaque executable safe. Every unclassified tool, including extensions,
/// is denied until it has a reviewed, bounded execution adapter.
public enum AgentDelegationToolPolicy {
    public enum Effect: Sendable, Equatable { case read, bookkeeping, fileWrite, unsupported }

    public static func effect(of tool: String) -> Effect {
        switch tool {
        // file_show materializes managed Attachments/ inside the workspace;
        // without a scoped export adapter it is not a read-only operation.
        case "file_read", "file_list", "file_find", "file_grep",
             "apelin_sdk_analyze_framework", "apelin_sdk_read_header",
             "apelin_memory_list", "apelin_skill_list", "apelin_skill_read",
             "apelin_template_list", "apelin_project_list", "apelin_project_check_distribution",
             "apelin_package_list", "apelin_toolchain_list", "apelin_sdk_list",
             "git_status", "git_diff", "git_branches", "git_log", "git_commit_detail",
             "git_remote_list", "apelin_git_read_settings",
             "apelin_conversation_list", "apelin_conversation_read",
             "apelin_todo_list", "apelin_crash_list", "apelin_crash_read", "apelin_log_read",
             "apelin_screen_read_tree", "apelin_screen_capture", "apelin_feedback_read",
             "web_search", "apelin_web_fetch": return .read
        case "apelin_todo_write", "apelin_notification_send", "apelin_question_ask",
             "apelin_run_mode", "apelin_conversation_plan", "apelin_conversation_send":
            return .bookkeeping
        case "file_write", "file_create", "file_edit": return .fileWrite
        default: return .unsupported
        }
    }

    public static func authorize(tool: String, path: String?, plan: AgentDelegationPlan,
                                 expectedRevision: UInt64) throws {
        try plan.validate()
        let current = plan.currentStep
        func refuse(_ rule: String) -> AgentDelegationViolation {
            .init(stepID: current?.id ?? "end", title: current?.title ?? "Assignment", rule: rule)
        }
        guard plan.revision == expectedRevision else {
            throw refuse("The brief changed. Read its current revision before another operation.")
        }
        switch effect(of: tool) {
        case .read, .bookkeeping: return
        case .fileWrite:
            try plan.authorize(.fileWrite, canonicalRelativePath: path, expectedRevision: expectedRevision)
        case .unsupported:
            throw refuse("\(tool) has no confined execution adapter. Commands (including argv), builds, git mutations, installation, publishing, subdelegation and opaque extensions are not allowed in a constrained assignment.")
        }
    }
}
