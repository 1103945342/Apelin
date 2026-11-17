import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI

/// Delegation as a worker uses it (`AgentDelegation`): the host owns the plan
/// and every move it allows. The worker reads the snapshot, puts each call
/// through the closed tool policy, asks the host's admission at that
/// revision, and never builds a plan of its own.
///
/// The brief a conversation was opened with is not authority: it says what
/// the assignment is. Only the host's answer to `read` and `admit` is.
///
/// Two known limits are recorded here rather than hidden:
/// - A project write goes through `ConfinedWriter`, whose every step is
///   relative to a descriptor it opened (`openat`/`mkdirat`/`linkat`/
///   `renameat`), and which re-reads the root and the parent before the move.
///   What it cannot prove: another process that moves the opened directory
///   itself out of the project while the write is going makes the file land
///   in that directory wherever it now is. The window is the move's own two
///   syscalls, the identities are checked just before them, and every error
///   writes nothing.
/// - `file_show` is not a read here. It materialises its copy under the
///   workspace's `Attachments/`, which is a write outside the open step's
///   write roots, so the closed tool policy classifies it as unsupported
///   until a scoped export adapter exists. Nothing in this file may treat it
///   as a managed artifact that bypasses the roots.

/// `apelin_conversation_create`'s `brief` and `apelin_conversation_plan`'s
/// `step`, in the snake_case the tools take.
struct DelegationStepArguments: Decodable {
    var id: String?
    var title: String?
    var writeRoots: [String]?
    var capabilities: [String]?
    var checkID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, capabilities
        case writeRoots = "write_roots"
        case checkID = "check_id"
    }

    /// The step as the brief spells it, with every capability a known one.
    func step() throws -> AgentDelegationBrief.Step {
        let id = (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ToolArgumentError("a step needs an id") }
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolArgumentError("step \(id) needs a title")
        }
        var mapped: [AgentDelegationBrief.Capability] = []
        for name in capabilities ?? [] {
            guard let capability = AgentDelegationBrief.Capability(rawValue: name) else {
                let allowed = AgentDelegationBrief.Capability.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolArgumentError("step \(id) names the unknown capability '\(name)'; one of \(allowed)")
            }
            mapped.append(capability)
        }
        return AgentDelegationBrief.Step(
            id: id,
            title: title,
            writeRoots: writeRoots ?? [],
            capabilities: mapped,
            checkID: checkID,
        )
    }

    /// One step out of a tool argument, decoded from its JSON.
    static func read(_ value: KWWKAI.JSONValue) throws -> DelegationStepArguments {
        do {
            return try JSONDecoder().decode(DelegationStepArguments.self, from: Data(value.canonicalJSON.utf8))
        } catch {
            throw ToolArgumentError("the step could not be read: id, title, write_roots and capabilities of the brief's shape")
        }
    }
}

/// A whole brief, as `apelin_conversation_create` takes it.
struct DelegationBriefArguments: Decodable {
    var objective: String?
    var acceptance: [String]?
    var gates: String?
    var steps: [DelegationStepArguments]?

    enum CodingKeys: String, CodingKey { case objective, acceptance, gates, steps }

    /// The brief, validated by the protocol's own rules before it is sent: a
    /// brief that does not hold is refused here, not discovered by the host.
    func brief() throws -> AgentDelegationBrief {
        let gates = gates ?? AgentDelegationBrief.Gates.each.rawValue
        guard let parsedGates = AgentDelegationBrief.Gates(rawValue: gates) else {
            throw ToolArgumentError("gates must be each or end")
        }
        let brief = AgentDelegationBrief(
            objective: objective ?? "",
            acceptance: acceptance ?? [],
            gates: parsedGates,
            steps: try (steps ?? []).map { try $0.step() },
        )
        do {
            try brief.validate()
        } catch {
            throw ToolArgumentError(error.localizedDescription)
        }
        return brief
    }

    static func read(_ value: KWWKAI.JSONValue) throws -> AgentDelegationBrief {
        do {
            return try JSONDecoder()
                .decode(DelegationBriefArguments.self, from: Data(value.canonicalJSON.utf8))
                .brief()
        } catch let error as ToolArgumentError {
            throw error
        } catch {
            throw ToolArgumentError("the brief could not be read: objective, acceptance, gates and steps")
        }
    }
}

/// One call's admission: the revision the host admitted it at.
struct DelegationTicket: Sendable, Equatable {
    var revision: UInt64
}

/// `apelin_conversation_plan` as the agent may call it: the action, the
/// revision it is based on, and the step or the reason that goes with it.
///
/// The revision is not one thing: a step action carries the plan's revision,
/// an assignment action the ledger's member revision, and `seal` the group's.
/// The host checks all of it; this refuses a call that cannot be checked.
struct DelegationPlanCall {
    var action: AgentDelegationRequest.Action
    var sessionID: String
    var revision: UInt64?
    var note: String?
    var step: AgentDelegationBrief.Step?
    /// What the child says it produced, on `review` and `blocked` only.
    var outputs: [AgentAssignment.Output]?
    /// On `amend`: what the assignment is now measured against.
    var acceptance: [String]?

    /// The actions a tool call may name. `admit` is the host's own, and the
    /// tool never asks for it.
    static let actions: [AgentDelegationRequest.Action] = [
        .read, .blocked, .review, .accept, .amend, .check,
        .acceptAssignment, .cancelAssignment, .failAssignment, .seal,
    ]

    static func read(_ arguments: KWWKAI.JSONValue, sessionID: String) throws -> DelegationPlanCall {
        let name = try arguments.requireString("action")
        guard let action = AgentDelegationRequest.Action(rawValue: name), action != .admit else {
            let allowed = actions.map(\.rawValue).joined(separator: ", ")
            throw ToolArgumentError("action must be one of \(allowed)")
        }
        let target = arguments.argNonEmptyString("session_id") ?? sessionID
        let revision = arguments.argInt("expected_revision").flatMap { $0 >= 0 ? UInt64($0) : nil }
        guard action == .read || revision != nil else {
            throw ToolArgumentError(
                "give expected_revision: the plan's revision for a step action, the ledger member's for an assignment action, the group's for seal",
            )
        }
        var note = arguments.argNonEmptyString("note")
        switch action {
        case .cancelAssignment, .failAssignment:
            guard note != nil else {
                throw ToolArgumentError("\(name) must say why the assignment ends with note")
            }
        default:
            note = nil
        }
        var step: AgentDelegationBrief.Step?
        if case let .object(object) = arguments, let value = object["step"] {
            step = try DelegationStepArguments.read(value).step()
        }
        if action == .amend {
            guard step != nil else {
                throw ToolArgumentError("amend needs the whole step it amends, with its id and title unchanged")
            }
        } else {
            step = nil
        }
        // Claims belong to the moves that end a step's work. Any other action
        // drops them rather than recording them under a different verb.
        var outputs: [AgentAssignment.Output]?
        if action == .review || action == .blocked,
           case let .object(object) = arguments,
           case let .array(values)? = object["outputs"] {
            outputs = try values.map { value -> AgentAssignment.Output in
                guard case let .object(fields) = value,
                      case let .string(summary)? = fields["summary"],
                      !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolArgumentError("each output says what it is in summary")
                }
                var path: String?
                if case let .string(candidate)? = fields["path"], !candidate.isEmpty {
                    path = candidate
                }
                return AgentAssignment.Output(id: UUID().uuidString, summary: summary, path: path)
            }
            if outputs?.isEmpty == true { outputs = nil }
        }
        // A new step may change what "done" means, so an amendment may restate
        // the acceptance in the same move; no other action does.
        let acceptance = action == .amend ? arguments.argStrings("acceptance") : nil
        return DelegationPlanCall(action: action, sessionID: target, revision: revision, note: note,
                                  step: step, outputs: outputs, acceptance: acceptance)
    }

    var request: AgentDelegationRequest {
        AgentDelegationRequest(
            sessionID: sessionID,
            action: action,
            expectedRevision: revision,
            step: step,
            note: note,
            outputs: outputs,
            acceptance: acceptance,
        )
    }
}

extension ToolRunner {
    /// The `brief` argument of a create, if it carried one.
    nonisolated static func delegationBriefArgument(_ arguments: KWWKAI.JSONValue) throws -> AgentDelegationBrief? {
        guard case let .object(object) = arguments, let value = object["brief"] else { return nil }
        return try DelegationBriefArguments.read(value)
    }

    /// The plan tool carries its own action to the host; it is not admitted
    /// like the tools that act on the project.
    nonisolated static func isDelegationPlan(_ tool: InvocationFacts.Tool) -> Bool {
        if case .local(.conversationPlan) = tool { return true }
        return false
    }

    /// The plan the host keeps for this conversation; nil when the host says
    /// the conversation has no delegated assignment.
    func delegationSnapshot() async throws -> AgentDelegationPlan? {
        let response = try await backend.delegation(
            AgentDelegationRequest(sessionID: sessionID, action: .read),
        )
        return response.plan
    }

    /// The figure a message's `<system-state>` carries, read at the input
    /// boundary so the agent always speaks from the plan as it is now. Nil
    /// when this conversation was opened without a brief.
    func delegationLine() async -> String? {
        guard delegationBrief != nil else { return nil }
        let snapshot: AgentDelegationPlan?
        do {
            snapshot = try await delegationSnapshot()
        } catch {
            return "- Delegation: the host could not be asked for this conversation's plan (\(error.localizedDescription)). Nothing that changes the project may run until it can be read."
        }
        guard let plan = snapshot else {
            return "- Delegation: the host keeps no plan for this conversation, though it was opened with a brief. Report the blocker; nothing that changes the project may run."
        }
        let total = plan.brief.steps.count
        let current = min(plan.currentIndex + 1, total)
        var line = "- Delegation: step \(current)/\(total)"
        if let step = plan.currentStep {
            line += " \"\(step.title)\""
        }
        line += ", revision \(plan.revision), gates \(plan.brief.gates.rawValue)."
        if let step = plan.currentStep {
            let roots = step.writeRoots.isEmpty ? "nothing" : step.writeRoots.joined(separator: ", ")
            let capabilities = step.capabilities.isEmpty
                ? "no capability"
                : step.capabilities.map(\.rawValue).joined(separator: ", ")
            line += " It may write \(roots) and \(capabilities)."
        }
        line += " The host admits every call; a call it does not admit is refused here."
        return line
    }

    /// What a constrained conversation owes before any call: the host's
    /// snapshot, the closed tool policy, then the host's own admission at
    /// that revision. Nil for a conversation opened without a brief. A write
    /// is admitted with the canonical path the confined writer will use, and
    /// that path is checked against the open step's write roots.
    func delegationAdmission(tool: String, path: String?) async throws -> DelegationTicket? {
        guard delegationBrief != nil else { return nil }
        guard let plan = try await delegationSnapshot() else {
            throw ToolDeniedError(
                message: "refused: this conversation was opened with a delegation brief, but the host keeps no plan for it. Report the blocker; nothing that changes the project may run.",
            )
        }
        do {
            try AgentDelegationToolPolicy.authorize(
                tool: tool,
                path: path,
                plan: plan,
                expectedRevision: plan.revision,
            )
        } catch {
            throw ToolDeniedError(message: "refused: \(error.localizedDescription)")
        }
        _ = try await backend.delegation(AgentDelegationRequest(
            sessionID: sessionID,
            action: .admit,
            expectedRevision: plan.revision,
            tool: tool,
            path: path,
        ))
        return DelegationTicket(revision: plan.revision)
    }

    /// An approval the user gave belongs to the revision the call was
    /// admitted at: if the plan moved while they were asked, the call does
    /// not run, and the host says so.
    func readmit(_ ticket: DelegationTicket, tool: String, path: String?) async throws {
        _ = try await backend.delegation(AgentDelegationRequest(
            sessionID: sessionID,
            action: .admit,
            expectedRevision: ticket.revision,
            tool: tool,
            path: path,
        ))
    }

    /// The canonical project-relative path a write tool names, or nil when
    /// the tool writes nothing. Every existing component is canonicalised and
    /// a link refused here, and the host checks the same path again. It does
    /// not make the write confined by itself: `ScopedRoot.commit` creates its
    /// temporary file with `O_NOFOLLOW` but links or renames it into place by
    /// absolute path after that check, so a parent directory swapped for a
    /// link in between still redirects it (`delegationAdmission` refuses every
    /// such write until a `*at`-descriptor writer exists).
    func delegationWritePath(_ tool: InvocationFacts.Tool, arguments: KWWKAI.JSONValue) throws -> String? {
        guard case let .local(name) = tool,
              AgentDelegationToolPolicy.effect(of: name.rawValue) == .fileWrite
        else { return nil }
        guard let raw = arguments.argNonEmptyString("path") else {
            throw ToolArgumentError("the call names no path")
        }
        do {
            return root.relative(try root.resolveForWrite(raw).finalPath)
        } catch {
            throw ToolDeniedError(message: "refused: \(error.localizedDescription)")
        }
    }
}
