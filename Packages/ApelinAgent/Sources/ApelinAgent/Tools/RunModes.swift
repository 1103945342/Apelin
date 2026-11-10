import enum ApelinProtocol.AgentRunMode
import enum ApelinProtocol.AgentRunModeRules
import struct ApelinProtocol.AgentRunModeRequest
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI

/// `apelin_run_mode` (2026-11-11): the conversation changing its own run mode,
/// as the composer's pill would.
///
/// A switch to `plan` is the agent's to make and asks nobody: a plan run can
/// only read, so stopping to ask would leave a task too large for one step
/// unthought-through — which is exactly when a plan is worth taking. A switch
/// to `build` hands the run the work the plan refused, so it is the reader's
/// decision: it rides the approval path as `detail.runMode`, the card showing
/// the agent's own reason, and the answer decides.
///
/// Either way a `runModeChanged` event tells the app, whose pill and whose
/// next prompt follow it: the mode outlives the run that changed it.
enum RunModes {
    /// The switch the arguments ask for, plain and within the rules, or why
    /// not, in words the model can act on.
    static func request(_ arguments: JSONValue) throws -> AgentRunModeRequest {
        let raw = arguments.argString("mode")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let raw else {
            throw ToolArgumentError("mode is plan or build")
        }
        if raw == AgentRunMode.auto.rawValue {
            throw ToolArgumentError(
                "mode auto is the reader's own setting, not something a run changes: ask for plan or build.",
            )
        }
        guard let mode = AgentRunMode(rawValue: raw), AgentRunModeRules.requestable.contains(mode) else {
            throw ToolArgumentError("mode is plan or build")
        }
        guard let reason = UserQuestions.plain(arguments.argString("why")) else {
            throw ToolArgumentError(
                "why is empty: say in one or two sentences why this conversation should go the other way",
            )
        }
        guard reason.count <= AgentRunModeRules.maximumReasonLength else {
            throw ToolArgumentError(
                "why is \(reason.count) characters; keep it to \(AgentRunModeRules.maximumReasonLength)",
            )
        }
        return AgentRunModeRequest(mode: mode, reason: reason)
    }

    /// What the model reads once the mode changed.
    static func changed(_ request: AgentRunModeRequest) -> String {
        switch request.mode {
        case .plan:
            """
            This conversation is a plan now: read what you need, work out what you would \
            change, then write the steps to apelin_todo_write. A plan edits, creates, \
            builds and installs nothing. When the plan is ready, call apelin_run_mode with \
            mode build and the reason it should start, and wait for the reader's answer \
            before you touch a file — or answer with the plan if they keep it a plan.
            """
        case .build:
            """
            This conversation is a build now: the work the plan described may start, as the \
            approval mode allows. Keep the todo list as you go, marking each step done as \
            you finish it.
            """
        case .auto:
            "This conversation is automatic now."
        }
    }

    /// What the model reads when the reader kept the conversation a plan.
    static let declined = """
    The user did not switch this conversation to a build. Do not make the change: answer \
    with the plan you have, what you would do first, and what you would need changed \
    about it, and ask in your reply if you cannot go on without it.
    """
}

extension ToolRunner {
    /// Changes the run mode: at once for a plan, on the reader's decision for
    /// a build. The call's result is what the model reads about the new mode.
    func changeRunMode(
        _ arguments: JSONValue,
        toolCallID: String,
        cancellation: CancellationHandle?,
    ) async throws -> AgentToolResult {
        let asked = try RunModes.request(arguments)
        guard let record else {
            throw ToolDeniedError(message: "Run mode changes are unavailable.")
        }
        if asked.mode == .plan {
            setRunMode(.plan)
            try await record(.runModeChanged(runMode: .plan, reason: asked.reason))
            return AgentToolResult(content: [.text(TextContent(text: RunModes.changed(asked)))])
        }
        let name = AgentToolName.runMode.rawValue
        let request = ApprovalRequest(
            id: UUID().uuidString,
            toolCallID: toolCallID,
            tool: name,
            arguments: arguments.canonicalJSON,
            workingDirectory: ".",
            projectID: project.id,
            fingerprint: ApprovalFingerprint.make(
                tool: name,
                arguments: arguments,
                workingDirectory: ".",
                projectID: project.id,
                digest: nil,
            ),
            // What the host's banner and the card say under the title: the
            // agent's own words, why the plan is ready to build.
            reason: asked.reason,
            detail: .runMode(asked),
            allowsSessionScope: false,
        )
        let decision = await gate.request(request, cancellation: cancellation)
        try cancellation?.throwIfCancelled()
        try Task.checkCancellation()
        guard case .approve = decision else {
            journal?.note(ToolCallOutcome(.denied, "the user kept this conversation a plan"), for: toolCallID)
            return AgentToolResult(content: [.text(TextContent(text: RunModes.declined))])
        }
        setRunMode(.build)
        try await record(.runModeChanged(runMode: .build, reason: asked.reason))
        return AgentToolResult(content: [.text(TextContent(text: RunModes.changed(asked)))])
    }
}
