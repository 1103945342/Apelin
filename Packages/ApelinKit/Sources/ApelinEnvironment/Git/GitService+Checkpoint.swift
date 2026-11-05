import ApelinCore
import ApelinGit
import ApelinProtocol
import Foundation

/// Checkpoint & Rewind's code half (`GitCheckpoint`): the work tree saved
/// before a message's run, and put back.
extension GitService {
    func checkpointSave(_ request: GitCheckpointSaveRequest) throws -> GitCheckpointSaveResponse {
        let repository = try open(request.projectID).repository
        let author = checkpointAuthor(repository)
        let commit = try mapped {
            try repository.saveCheckpoint(
                at: GitCheckpointRules.reference(for: request.messageID),
                message: "Checkpoint before message \(request.messageID.uuidString.lowercased())\n\nSaved by Apelin: every file the repository does not ignore, as it was before the run.\n",
                author: author,
                maximumFiles: GitCheckpointRules.maximumFiles,
                maximumBytes: GitCheckpointRules.maximumBytes,
            )
        }
        return GitCheckpointSaveResponse(commit: commit)
    }

    func checkpointRestore(_ request: GitCheckpointRestoreRequest) throws -> GitCheckpointRestoreResponse {
        let repository = try open(request.projectID).repository
        let author = checkpointAuthor(repository)
        let restored = try mapped {
            try repository.restoreCheckpoint(at: GitCheckpointRules.reference(for: request.messageID), author: author)
        }
        return GitCheckpointRestoreResponse(
            backupBranch: restored.backupBranch,
            written: restored.written,
            removed: restored.removed,
        )
    }

    /// The author Settings ▸ Git names, else the repository's, else
    /// Apelin's own: a checkpoint is on no branch, and a missing author
    /// must not cost the reader the code they would go back to.
    private func checkpointAuthor(_ repository: GitRepository) -> GitSignature {
        (try? author(name: nil, email: nil, repository: repository))
            ?? GitSignature(name: "Apelin", email: "apelin@localhost")
    }
}
