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
        func paths(_ value: JSONValue?) -> [String]? {
            value?.arrayValue?.compactMap(\.stringValue)
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
            case .gitTagCreate:
                let value = try request.decode(GitTagCreateRequest.self)
                return tool(.gitTag, value.projectID)
                    && arguments["action"]?.stringValue == "create"
                    && arguments["name"]?.stringValue == value.name
                    && optional("commit") == value.commit
                    && optional("message") == value.message
                    && optional("remote") == value.remote
            case .gitTagDelete:
                let value = try request.decode(GitTagDeleteRequest.self)
                return tool(.gitTag, value.projectID)
                    && arguments["action"]?.stringValue == "delete"
                    && arguments["name"]?.stringValue == value.name
                    && optional("remote") == value.remote
            case .gitRestore:
                let value = try request.decode(GitRestoreRequest.self)
                return tool(.gitRestore, value.projectID)
                    && paths(arguments["paths"]) == value.paths
                    && (arguments["source"]?.stringValue ?? "head") == value.source.rawValue
            case .gitDeletePaths:
                let value = try request.decode(GitDeletePathsRequest.self)
                return tool(.gitClean, value.projectID)
                    && paths(arguments["paths"]) == value.paths
            case .gitStashSave:
                let value = try request.decode(GitStashSaveRequest.self)
                return tool(.gitStash, value.projectID)
                    && arguments["action"]?.stringValue == "save"
                    && optional("message") == value.message
                    && (arguments["include_untracked"]?.boolValue ?? false) == value.includeUntracked
            case .gitStashApply:
                let value = try request.decode(GitStashApplyRequest.self)
                return tool(.gitStash, value.projectID)
                    && arguments["action"]?.stringValue == "apply"
                    && (arguments["index"]?.doubleValue ?? 0) == Double(value.index)
                    && (arguments["pop"]?.boolValue ?? false) == value.pop
            case .gitStashDrop:
                let value = try request.decode(GitStashDropRequest.self)
                return tool(.gitStash, value.projectID)
                    && arguments["action"]?.stringValue == "drop"
                    && (arguments["index"]?.doubleValue ?? 0) == Double(value.index)
            case .gitStashClear:
                let value = try request.decode(GitStashClearRequest.self)
                return tool(.gitStash, value.projectID)
                    && arguments["action"]?.stringValue == "clear"
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
