import ApelinAgent
import ApelinProtocol
import Foundation

/// The caller cannot redirect a Git operation to another project by forging
/// its context. The host checks the worker's session scope again.
public extension ChannelHostBackend {
    func gitBranches(_: GitBranchesToolRequest) async throws -> GitBranchesResponse {
        try await git("git branches") { try await service.gitBranches(projectID: project.id) }
    }

    func gitBranchCreate(_ request: GitBranchCreateToolRequest) async throws -> GitBranchCreateResponse {
        try await git("git branch create") {
            try await service.gitBranchCreate(GitBranchCreateRequest(
                projectID: project.id, name: request.name, startPoint: request.startPoint, checkout: request.checkout,
            ))
        }
    }

    func gitBranchCheckout(_ request: GitBranchCheckoutToolRequest) async throws -> GitBranchCheckoutResponse {
        try await git("git branch checkout") {
            try await service.gitBranchCheckout(GitBranchCheckoutRequest(
                projectID: project.id, name: request.name, remote: request.remote,
            ))
        }
    }

    func gitBranchDelete(_ request: GitBranchDeleteToolRequest) async throws -> GitBranchDeleteResponse {
        try await git("git branch delete") {
            try await service.gitBranchDelete(GitBranchDeleteRequest(
                projectID: project.id, name: request.name, remote: request.remote, force: request.force,
            ))
            return GitBranchDeleteResponse()
        }
    }

    func gitBranchRename(_ request: GitBranchRenameToolRequest) async throws -> GitBranchRenameResponse {
        try await git("git branch rename") {
            try await service.gitBranchRename(GitBranchRenameRequest(projectID: project.id, from: request.from, to: request.to))
        }
    }

    func gitMerge(_ request: GitMergeToolRequest) async throws -> GitMergeResponse {
        try await git("git merge") {
            try await service.gitMerge(GitMergeRequest(projectID: project.id, branch: request.branch, noFastForward: request.noFastForward))
        }
    }

    func gitMergeAbort(_: GitMergeAbortToolRequest) async throws -> GitMergeAbortResponse {
        try await git("git merge abort") { try await service.gitMergeAbort(projectID: project.id) }
        return GitMergeAbortResponse()
    }

    func gitLog(_ request: GitLogToolRequest) async throws -> GitLogResponse {
        try await git("git log") { try await service.gitLog(projectID: project.id, limit: request.limit, skip: request.skip) }
    }

    func gitCommitDetail(_ request: GitCommitDetailToolRequest) async throws -> GitCommitDetailResponse {
        try await git("git commit detail") { try await service.gitCommitDetail(projectID: project.id, commit: request.commit) }
    }
}
