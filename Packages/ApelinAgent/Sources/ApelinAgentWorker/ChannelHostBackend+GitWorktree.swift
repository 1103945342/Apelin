import ApelinAgent
import ApelinProtocol
import Foundation

/// Tags, stashes, a path's changes discarded, and the untracked files a clean
/// takes away. The host checks the worker's session scope again.
public extension ChannelHostBackend {
    func gitTag(_ request: GitTagToolRequest) async throws -> GitTagToolResponse {
        try await git("git tag") {
            switch request.action {
            case .create:
                let made = try await service.gitTagCreate(GitTagCreateRequest(
                    projectID: project.id,
                    name: request.name,
                    commit: request.commit,
                    message: request.message,
                    remote: request.remote,
                ))
                return GitTagToolResponse(name: made.name)
            case .delete:
                try await service.gitTagDelete(projectID: project.id, name: request.name, remote: request.remote)
                return GitTagToolResponse(name: request.name)
            }
        }
    }

    func gitStash(_ request: GitStashToolRequest) async throws -> GitStashToolResponse {
        try await git("git stash") {
            switch request.action {
            case .list:
                let list = try await service.gitStashList(projectID: project.id)
                return GitStashToolResponse(stashes: list.stashes)
            case .save:
                let saved = try await service.gitStashSave(
                    projectID: project.id,
                    message: request.message,
                    includeUntracked: request.includeUntracked,
                )
                return GitStashToolResponse(saved: saved.saved)
            case .apply:
                let applied = try await service.gitStashApply(
                    projectID: project.id,
                    index: request.index,
                    pop: request.pop,
                )
                return GitStashToolResponse(conflicts: applied.conflicts)
            case .drop:
                try await service.gitStashDrop(projectID: project.id, index: request.index)
                return GitStashToolResponse()
            case .clear:
                try await service.gitStashClear(projectID: project.id)
                return GitStashToolResponse()
            }
        }
    }

    func gitRestore(_ request: GitRestoreToolRequest) async throws -> GitRestoreResponse {
        try await git("git restore") {
            try await service.gitRestore(projectID: project.id, paths: request.paths, source: request.source)
            return GitRestoreResponse()
        }
    }

    func gitClean(_ request: GitCleanToolRequest) async throws -> GitDeletePathsResponse {
        try await git("git clean") {
            try await service.gitDeletePaths(projectID: project.id, paths: request.paths)
            return GitDeletePathsResponse()
        }
    }
}
