import ApelinCore
import ApelinProtocol
import Foundation

/// Matches a branch mutation to the exact tool and arguments the reader saw.
/// The event is read from the host's log, never from worker-supplied evidence.
enum AgentGitBranchRules {
    static func covers(_ request: WireRequest, project: String, asked: JSONValue) -> Bool {
        guard asked["projectID"]?.stringValue == project,
              let text = asked["arguments"]?.stringValue,
              let arguments = try? JSONCoding.decode(JSONValue.self, from: Data(text.utf8))
        else { return false }
        func optional(_ key: String) -> String? {
            guard let value = arguments[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        func tool(_ name: AgentToolName, _ projectID: String) -> Bool {
            asked["tool"]?.stringValue == name.rawValue && projectID == project
        }
        do {
            switch request.operation {
            case .gitBranchCreate:
                let value = try request.decode(GitBranchCreateRequest.self)
                return tool(.gitBranchCreate, value.projectID)
                    && arguments["name"]?.stringValue == value.name
                    && optional("start_point") == value.startPoint
                    && (arguments["checkout"]?.boolValue ?? false) == value.checkout
            case .gitBranchCheckout:
                let value = try request.decode(GitBranchCheckoutRequest.self)
                return tool(.gitBranchCheckout, value.projectID)
                    && arguments["name"]?.stringValue == value.name
                    && optional("remote") == value.remote
            case .gitBranchDelete:
                let value = try request.decode(GitBranchDeleteRequest.self)
                return tool(.gitBranchDelete, value.projectID)
                    && arguments["name"]?.stringValue == value.name
                    && optional("remote") == value.remote
                    && (arguments["force"]?.boolValue ?? false) == (value.force ?? false)
            case .gitBranchRename:
                let value = try request.decode(GitBranchRenameRequest.self)
                return tool(.gitBranchRename, value.projectID)
                    && arguments["from"]?.stringValue == value.from
                    && arguments["to"]?.stringValue == value.to
            case .gitMerge:
                let value = try request.decode(GitMergeRequest.self)
                return tool(.gitMerge, value.projectID)
                    && arguments["branch"]?.stringValue == value.branch
                    && (arguments["no_fast_forward"]?.boolValue ?? false) == value.noFastForward
            case .gitMergeAbort:
                return tool(.gitMergeAbort, try request.decode(GitMergeAbortRequest.self).projectID)
            default:
                return false
            }
        } catch {
            return false
        }
    }

    /// Spend one exact approval in Strict mode, never a session-wide grant.
    static func authorize(_ request: WireRequest, session: String?, registry: TaskRegistry) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard entry.mode.asks else { return nil }
        let covered = await AgentApprovals.spend(entry: entry, registry: registry) { asked in
            covers(request, project: entry.project.id, asked: asked)
        }
        return covered ? nil : ApelinError(.denied, "approval required: this branch or merge operation has not been approved")
    }
}
