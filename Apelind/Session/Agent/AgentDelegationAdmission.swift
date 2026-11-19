import ApelinProtocol
import Foundation

/// Checked before approval handling. The socket's worker identity, not a
/// session ID in a model argument, identifies the constrained caller.
enum AgentDelegationAdmission {
    static func refusal(_ request: HostRequest, host: SessionHost) async -> HostReply? {
        guard case let .worker(.agent, instance?) = request.caller else { return nil }
        do {
            guard let saved = try await host.delegations.record(instance) else {
                if let entry = await AgentSessionTable.shared.entry(instance), entry.parentSessionID != nil {
                    throw AgentDelegationViolation(stepID: "brief", title: "Assignment", rule: "This child has no saved authority. Start a new structured assignment; no mutation is authorised.")
                }
                return nil
            }
            try check(request.operation, promptTarget: request.operation == .agentPrompt
                      ? request.decode(AgentPromptRequest.self).sessionID : nil,
                      planTarget: request.operation == .agentDelegation
                      ? request.decode(AgentDelegationRequest.self).sessionID : nil,
                      saved: saved)
            return nil
        } catch {
            return request.fail(ApelinError(.denied, error.localizedDescription))
        }
    }

    /// Host effects are narrower than tool labels. `confirmLoaded` can respring,
    /// git previews can fetch, and an opaque worker/plugin can execute code, so
    /// none gets a blanket read exemption from its UI name.
    static func check(_ operation: AppOperation, promptTarget: String? = nil,
                      planTarget: String? = nil, saved: AgentDelegationStore.Record) throws {
        let plan = saved.plan
        try plan.validate()
        switch operation {
        case .agentDelegation:
            guard planTarget == saved.child else { throw refusal(plan, "A constrained child may operate only on its own brief.") }
        case .agentPrompt:
            guard promptTarget == saved.opener else {
                throw refusal(plan, "A constrained child can report only to its opener, not delegate through another conversation.")
            }
        case .agentList, .agentAttach, .fileRead, .toolchainStatus, .toolchainCatalog,
             .sdkList, .extensionList, .projectCheck, .installationList,
             .gitStatus, .gitDiff, .gitBranches, .gitLog, .gitCommitDetail,
             .gitRemoteList, .gitSettings, .crashList, .crashOpen, .logStream,
             .captureScreen, .readUITree, .feedbackRead, .approvalDigestState:
            break
        default:
            throw refusal(plan, "\(operation.rawValue) has no confined execution adapter. Approval does not widen this step.")
        }
    }

    private static func refusal(_ plan: AgentDelegationPlan, _ rule: String) -> AgentDelegationViolation {
        .init(stepID: plan.currentStep?.id ?? "end", title: plan.currentStep?.title ?? "Assignment", rule: rule)
    }
}
