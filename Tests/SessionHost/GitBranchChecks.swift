import ApelinCore
import ApelinProtocol
import Foundation

func gitBranchChecks(scratch: URL, scratchPath: String) async throws {
    let operations: [AppOperation] = [.gitBranches, .gitBranchCreate, .gitBranchCheckout, .gitBranchDelete, .gitBranchRename, .gitMerge, .gitMergeAbort, .gitLog, .gitCommitDetail,
                                      .gitTagCreate, .gitTagDelete, .gitRestore, .gitDeletePaths,
                                      .gitStashList, .gitStashSave, .gitStashApply, .gitStashDrop, .gitStashClear]
    for operation in operations {
        check(CallerPolicy.allows(.worker(.agent, instance: "s"), operation), "agent reaches \(operation)")
        check(!CallerPolicy.allows(.worker(.environment, instance: nil), operation), "environment cannot request \(operation)")
    }
    for operation: AppOperation in [.gitReset, .gitIgnoreAppend, .gitCommitFileDiff, .gitFileVersions] {
        check(!CallerPolicy.allows(.worker(.agent, instance: "s"), operation), "destructive app operations stay app-only")
    }
    let project = ResolvedProject(id: "p-branches", name: "Branches", path: scratchPath)
    func card(_ tool: AgentToolName, _ arguments: String, projectID: String = "p-branches") -> JSONValue {
        .object(["tool": .string(tool.rawValue), "projectID": .string(projectID), "arguments": .string(arguments), "allowsSessionScope": .bool(false)])
    }
    let cases: [(WireRequest, JSONValue)] = [
        (try WireRequest(GitBranchCreateRequest(projectID: project.id, name: "feature", startPoint: "main", checkout: true)), card(.gitBranchCreate, #"{"name":"feature","start_point":"main","checkout":true}"#)),
        (try WireRequest(GitBranchCheckoutRequest(projectID: project.id, name: "main", remote: "origin")), card(.gitBranchCheckout, #"{"name":"main","remote":"origin"}"#)),
        (try WireRequest(GitBranchDeleteRequest(projectID: project.id, name: "old", remote: "origin", force: true)), card(.gitBranchDelete, #"{"name":"old","remote":"origin","force":true}"#)),
        (try WireRequest(GitBranchRenameRequest(projectID: project.id, from: "feature", to: "reviewed")), card(.gitBranchRename, #"{"from":"feature","to":"reviewed"}"#)),
        (try WireRequest(GitMergeRequest(projectID: project.id, branch: "reviewed", noFastForward: true)), card(.gitMerge, #"{"branch":"reviewed","no_fast_forward":true}"#)),
        (try WireRequest(GitMergeAbortRequest(projectID: project.id)), card(.gitMergeAbort, "{}")),
        (try WireRequest(GitTagCreateRequest(projectID: project.id, name: "v1", commit: "HEAD~1", message: "First", remote: "origin")), card(.gitTag, #"{"action":"create","name":"v1","commit":"HEAD~1","message":"First","remote":"origin"}"#)),
        (try WireRequest(GitTagDeleteRequest(projectID: project.id, name: "v1", remote: "origin")), card(.gitTag, #"{"action":"delete","name":"v1","remote":"origin"}"#)),
        (try WireRequest(GitRestoreRequest(projectID: project.id, paths: ["a.swift"], source: .index)), card(.gitRestore, #"{"paths":["a.swift"],"source":"index"}"#)),
        (try WireRequest(GitDeletePathsRequest(projectID: project.id, paths: ["build"])), card(.gitClean, #"{"paths":["build"]}"#)),
        (try WireRequest(GitStashSaveRequest(projectID: project.id, message: "wip", includeUntracked: true)), card(.gitStash, #"{"action":"save","message":"wip","include_untracked":true}"#)),
        (try WireRequest(GitStashApplyRequest(projectID: project.id, index: 2, pop: true)), card(.gitStash, #"{"action":"apply","index":2,"pop":true}"#)),
        (try WireRequest(GitStashDropRequest(projectID: project.id, index: 1)), card(.gitStash, #"{"action":"drop","index":1}"#)),
        (try WireRequest(GitStashClearRequest(projectID: project.id)), card(.gitStash, #"{"action":"clear"}"#)),
    ]
    for (request, asked) in cases {
        check(AgentGitBranchRules.covers(request, project: project.id, asked: asked), "exact arguments cover \(request.operation)")
        check(!AgentGitBranchRules.covers(request, project: "elsewhere", asked: asked), "another project is refused")
        check(!AgentGitBranchRules.covers(request, project: project.id, asked: card(.gitStatus, "{}")), "another tool covers no mutation")
    }
    let checkout = try WireRequest(GitBranchCheckoutRequest(projectID: project.id, name: "main"))
    check(!AgentGitBranchRules.covers(checkout, project: project.id, asked: card(.gitBranchCheckout, #"{"name":"other"}"#)), "another branch is refused")
    check(!AgentGitBranchRules.covers(checkout, project: project.id, asked: card(.gitBranchCheckout, #"{"name":"main","remote":"origin"}"#)), "a remote checkout cannot approve a local checkout")
    check(!AgentGitBranchRules.covers(cases[0].0, project: project.id, asked: card(.gitBranchCreate, #"{"name":"feature","start_point":"main","checkout":false}"#)), "create alone cannot approve switching")
    check(!AgentGitBranchRules.covers(cases[4].0, project: project.id, asked: card(.gitMerge, #"{"branch":"reviewed"}"#)), "merge mode is bound")
    check(!AgentGitBranchRules.covers(cases[2].0, project: project.id, asked: card(.gitBranchDelete, #"{"name":"old","remote":"origin"}"#)), "force cannot be granted without being named")
    check(!AgentGitBranchRules.covers(cases[6].0, project: project.id, asked: card(.gitTag, #"{"action":"create","name":"v1","commit":"HEAD~1","message":"First"}"#)), "a tag's remote cannot be granted without being named")
    check(!AgentGitBranchRules.covers(cases[7].0, project: project.id, asked: card(.gitTag, #"{"action":"delete","name":"v1","remote":"upstream"}"#)), "another remote is refused")
    check(!AgentGitBranchRules.covers(checkout, project: project.id, asked: card(.gitBranchCheckout, "invalid JSON")), "bad event fails closed")

    let registry = TaskRegistry(directory: scratch.appendingPathComponent("branch-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    for mode in [ApprovalMode.confirm, .relaxed, .full] {
        let id = "branches-\(mode.rawValue)"
        let entry = await AgentSessionTable.Entry(sessionID: id, task: registry.create(kind: .agent, owner: .agent, ownerKey: id), project: project, mode: mode, createdAt: Date())
        await sessions.add(entry)
        for (index, pair) in cases.enumerated() {
            let (request, asked) = pair
            let unasked = await AgentGitBranchRules.authorize(request, session: id, registry: registry)
            if mode != .confirm {
                check(unasked == nil, "\(mode): mutation runs without a card")
                continue
            }
            check(unasked?.code == .denied, "Strict refuses unapproved mutation")
            let approvalID = "branch-approval-\(index)"
            guard case var .object(payload) = asked else { fatalError("card") }
            payload["approvalID"] = .string(approvalID)
            await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object(payload))
            let pending = await AgentGitBranchRules.authorize(request, session: id, registry: registry)
            check(pending != nil, "asking alone is not approval")
            await sessions.record(id, approvalID: approvalID, decision: .approve)
            let approved = await AgentGitBranchRules.authorize(request, session: id, registry: registry)
            check(approved == nil, "one matching approval runs")
            let replay = await AgentGitBranchRules.authorize(request, session: id, registry: registry)
            check(replay != nil, "approval cannot be replayed")
        }
    }
    let unknown = await AgentGitBranchRules.authorize(checkout, session: "missing-branch-session", registry: registry)
    check(unknown?.code == .denied, "unknown session fails closed")
}
