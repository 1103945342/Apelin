import Foundation

// A project's work tree as it stood before a message's run, kept so the
// reader can put the code back there (Checkpoint & Rewind). Served by
// apelin-environment (libgit2) as mobile, in the project's own repository:
// each checkpoint is a commit of every file the repository does not ignore,
// tracked or not, under `refs/apelin/checkpoints/<message id>`, a ref no
// branch, push or clone carries. The index, HEAD and the branches are never
// touched by a save.

public enum GitCheckpointRules {
    /// The ref a message's checkpoint is kept under.
    public static func reference(for messageID: UUID) -> String {
        "refs/apelin/checkpoints/" + messageID.uuidString.lowercased()
    }

    /// A work tree with more changed or untracked files than this, or more
    /// bytes in them, is not saved: a checkpoint is taken before every run,
    /// and one that copies a build folder nobody ignored would hold it up.
    public static let maximumFiles = 5000
    public static let maximumBytes: Int64 = 256 << 20
}

/// Saves the work tree before `messageID`'s run. The agent's, for its own
/// project only (GitHandler's scope check); the app never needs to.
public struct GitCheckpointSaveRequest: OperationRequest {
    public typealias Response = GitCheckpointSaveResponse
    public static let operation = AppOperation.gitCheckpointSave
    public var projectID: String
    public var messageID: UUID

    public init(projectID: String, messageID: UUID) {
        self.projectID = projectID
        self.messageID = messageID
    }
}

public struct GitCheckpointSaveResponse: Codable, Sendable, Equatable {
    /// The checkpoint's commit; nil when the work tree was too large to
    /// save (`GitCheckpointRules`).
    public var commit: String?

    public init(commit: String?) {
        self.commit = commit
    }
}

/// Makes the work tree what it was at `messageID`'s checkpoint: each file
/// the checkpoint holds written back, each file it does not hold removed,
/// ignored files left alone. What the work tree held first is saved on a
/// new branch `apelin-backup/checkpoint-<time>`, which the answer names, so
/// the restore can itself be undone. The index and HEAD stay where they
/// are. The app's alone, after the session's run has stopped
/// (`agentRewind` with `truncate` false or true).
public struct GitCheckpointRestoreRequest: OperationRequest {
    public typealias Response = GitCheckpointRestoreResponse
    public static let operation = AppOperation.gitCheckpointRestore
    public var projectID: String
    public var messageID: UUID

    public init(projectID: String, messageID: UUID) {
        self.projectID = projectID
        self.messageID = messageID
    }
}

public struct GitCheckpointRestoreResponse: Codable, Sendable, Equatable {
    /// The branch the work tree was saved on first; nil when it already
    /// was the checkpoint's and nothing changed.
    public var backupBranch: String?
    /// Files written back.
    public var written: Int
    /// Files removed.
    public var removed: Int

    public init(backupBranch: String?, written: Int, removed: Int) {
        self.backupBranch = backupBranch
        self.written = written
        self.removed = removed
    }
}

public extension ApelinService {
    func gitCheckpointSave(projectID: String, messageID: UUID) async throws -> GitCheckpointSaveResponse {
        try await send(GitCheckpointSaveRequest(projectID: projectID, messageID: messageID))
    }

    func gitCheckpointRestore(projectID: String, messageID: UUID) async throws -> GitCheckpointRestoreResponse {
        try await send(GitCheckpointRestoreRequest(projectID: projectID, messageID: messageID))
    }
}
