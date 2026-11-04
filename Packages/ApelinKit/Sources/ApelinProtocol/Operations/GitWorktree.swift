import Foundation

// The four ways the app's status page takes a change back: restore a file
// from HEAD or from the index, delete what git is not tracking yet, add a
// pattern to the repository's own ignore rules, move a branch with a reset,
// and put work aside in a stash.
//
// A restore and a delete never touch what a commit holds — they only move
// the work tree and the index — so both are refused for a path git is not
// already tracking (restore) or is tracking (delete).

public struct GitRestoreRequest: OperationRequest {
    public typealias Response = GitRestoreResponse
    public static let operation = AppOperation.gitRestore
    public var projectID: String
    /// Project-relative, matched literally.
    public var paths: [String]
    /// Where the contents come back from: `head` takes the committed version
    /// and unstages it too, `index` only drops the work-tree change.
    public var source: Source

    public enum Source: String, Codable, Sendable {
        case head
        case index
    }

    public init(projectID: String, paths: [String], source: Source) {
        self.projectID = projectID
        self.paths = paths
        self.source = source
    }
}

public struct GitRestoreResponse: Codable, Sendable, Equatable {
    public init() {}
}

public struct GitDeletePathsRequest: OperationRequest {
    public typealias Response = GitDeletePathsResponse
    public static let operation = AppOperation.gitDeletePaths
    public var projectID: String
    /// Project-relative; a directory removes everything below it, which is
    /// how the app deletes a folder of untracked files at once.
    public var paths: [String]
    public init(projectID: String, paths: [String]) {
        self.projectID = projectID
        self.paths = paths
    }
}

public struct GitDeletePathsResponse: Codable, Sendable, Equatable {
    public init() {}
}

public struct GitIgnoreAppendRequest: OperationRequest {
    public typealias Response = GitIgnoreAppendResponse
    public static let operation = AppOperation.gitIgnoreAppend
    public var projectID: String
    /// One line: a name, a `*.ext` pattern, or a folder's name with a
    /// trailing slash. Refused when it is empty, absolute or holds a newline.
    public var pattern: String
    public init(projectID: String, pattern: String) {
        self.projectID = projectID
        self.pattern = pattern
    }
}

public struct GitIgnoreAppendResponse: Codable, Sendable, Equatable {
    /// Whether the file already had that line.
    public var added: Bool
    public init(added: Bool) {
        self.added = added
    }
}

public struct GitResetRequest: OperationRequest {
    public typealias Response = GitResetResponse
    public static let operation = AppOperation.gitReset
    public var projectID: String
    /// The commit the branch moves to.
    public var commit: String
    /// `soft` keeps the index and the work tree, `mixed` keeps the work tree
    /// — the two the app offers.
    public var mode: Mode

    public enum Mode: String, Codable, Sendable {
        case soft
        case mixed
    }

    public init(projectID: String, commit: String, mode: Mode) {
        self.projectID = projectID
        self.commit = commit
        self.mode = mode
    }
}

public struct GitResetResponse: Codable, Sendable, Equatable {
    public var commit: String
    public init(commit: String) {
        self.commit = commit
    }
}

public struct GitStashRow: Codable, Sendable, Equatable, Hashable {
    /// `0` for `stash@{0}`, the newest.
    public var index: Int
    /// What the stash was saved with: the reader's message, else the commit
    /// subject git writes for it.
    public var message: String
    /// The branch it was saved on.
    public var branch: String
    public var commit: String
    public init(index: Int, message: String, branch: String, commit: String) {
        self.index = index
        self.message = message
        self.branch = branch
        self.commit = commit
    }
}

public struct GitStashListRequest: OperationRequest {
    public typealias Response = GitStashListResponse
    public static let operation = AppOperation.gitStashList
    public var projectID: String
    public init(projectID: String) {
        self.projectID = projectID
    }
}

public struct GitStashListResponse: Codable, Sendable, Equatable {
    public var stashes: [GitStashRow]
    public init(stashes: [GitStashRow] = []) {
        self.stashes = stashes
    }
}

public struct GitStashSaveRequest: OperationRequest {
    public typealias Response = GitStashSaveResponse
    public static let operation = AppOperation.gitStashSave
    public var projectID: String
    /// Absent leaves git's own subject.
    public var message: String?
    /// Takes untracked files with it; they are the ones a stash leaves
    /// behind otherwise, and the ones a reader is most surprised by.
    public var includeUntracked: Bool
    public init(projectID: String, message: String? = nil, includeUntracked: Bool = false) {
        self.projectID = projectID
        self.message = message
        self.includeUntracked = includeUntracked
    }
}

public struct GitStashSaveResponse: Codable, Sendable, Equatable {
    /// Whether there was anything to put aside.
    public var saved: Bool
    public init(saved: Bool) {
        self.saved = saved
    }
}

public struct GitStashApplyRequest: OperationRequest {
    public typealias Response = GitStashApplyResponse
    public static let operation = AppOperation.gitStashApply
    public var projectID: String
    public var index: Int
    /// Drops it once it is applied — a pop.
    public var pop: Bool
    public init(projectID: String, index: Int, pop: Bool) {
        self.projectID = projectID
        self.index = index
        self.pop = pop
    }
}

public struct GitStashApplyResponse: Codable, Sendable, Equatable {
    /// The paths the apply conflicted on, empty when it was clean.
    public var conflicts: [String]
    public init(conflicts: [String] = []) {
        self.conflicts = conflicts
    }
}

public struct GitStashDropRequest: OperationRequest {
    public typealias Response = GitStashDropResponse
    public static let operation = AppOperation.gitStashDrop
    public var projectID: String
    public var index: Int
    public init(projectID: String, index: Int) {
        self.projectID = projectID
        self.index = index
    }
}

public struct GitStashDropResponse: Codable, Sendable, Equatable {
    public init() {}
}

public struct GitStashClearRequest: OperationRequest {
    public typealias Response = GitStashClearResponse
    public static let operation = AppOperation.gitStashClear
    public var projectID: String
    public init(projectID: String) {
        self.projectID = projectID
    }
}

public struct GitStashClearResponse: Codable, Sendable, Equatable {
    public init() {}
}

public extension ApelinService {
    func gitRestore(projectID: String, paths: [String], source: GitRestoreRequest.Source) async throws {
        _ = try await send(GitRestoreRequest(projectID: projectID, paths: paths, source: source))
    }

    func gitDeletePaths(projectID: String, paths: [String]) async throws {
        _ = try await send(GitDeletePathsRequest(projectID: projectID, paths: paths))
    }

    func gitIgnoreAppend(projectID: String, pattern: String) async throws -> GitIgnoreAppendResponse {
        try await send(GitIgnoreAppendRequest(projectID: projectID, pattern: pattern))
    }

    func gitReset(projectID: String, commit: String, mode: GitResetRequest.Mode) async throws -> GitResetResponse {
        try await send(GitResetRequest(projectID: projectID, commit: commit, mode: mode))
    }

    func gitStashList(projectID: String) async throws -> GitStashListResponse {
        try await send(GitStashListRequest(projectID: projectID))
    }

    func gitStashSave(projectID: String, message: String? = nil, includeUntracked: Bool = false) async throws -> GitStashSaveResponse {
        try await send(GitStashSaveRequest(projectID: projectID, message: message, includeUntracked: includeUntracked))
    }

    func gitStashApply(projectID: String, index: Int, pop: Bool) async throws -> GitStashApplyResponse {
        try await send(GitStashApplyRequest(projectID: projectID, index: index, pop: pop))
    }

    func gitStashDrop(projectID: String, index: Int) async throws {
        _ = try await send(GitStashDropRequest(projectID: projectID, index: index))
    }

    func gitStashClear(projectID: String) async throws {
        _ = try await send(GitStashClearRequest(projectID: projectID))
    }
}
