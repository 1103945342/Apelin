import Foundation

// The repository's history as the app's commits tab draws it: a page of
// commits with their parents (the graph is built from those alone), one
// commit opened, one of its files diffed, and the two texts of a file a
// line-by-line view compares.
//
// The line view takes whole texts rather than a patch, because it shows every
// line of both sides with both numbers, as the reference app does; a patch
// carries three lines of context and would draw a different page.

/// One commit, as the list shows it.
public struct GitCommitRow: Codable, Sendable, Equatable, Hashable {
    public var id: String
    /// The first eight characters.
    public var shortID: String
    /// Every parent, first-parent first; more than one is a merge.
    public var parents: [String]
    public var summary: String
    public var authorName: String
    public var authorEmail: String
    /// Seconds since 1970.
    public var authoredAt: Double
    /// The branches, remotes and tags pointing at it.
    public var refs: [GitRefRow]

    public init(
        id: String,
        shortID: String,
        parents: [String] = [],
        summary: String,
        authorName: String,
        authorEmail: String,
        authoredAt: Double,
        refs: [GitRefRow] = [],
    ) {
        self.id = id
        self.shortID = shortID
        self.parents = parents
        self.summary = summary
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredAt = authoredAt
        self.refs = refs
    }
}

public struct GitRefRow: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case local
        case remote
        case tag
        /// HEAD points here.
        case head
    }
    public var name: String
    public var kind: Kind
    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

public struct GitLogRequest: OperationRequest {
    public typealias Response = GitLogResponse
    public static let operation = AppOperation.gitLog
    public var projectID: String
    /// How many to answer with, from `skip` on, newest first.
    public var limit: Int
    public var skip: Int
    public init(projectID: String, limit: Int = 100, skip: Int = 0) {
        self.projectID = projectID
        self.limit = limit
        self.skip = skip
    }
}

public struct GitLogResponse: Codable, Sendable, Equatable {
    public var commits: [GitCommitRow]
    /// Whether the walk stopped at the limit with more behind it.
    public var hasMore: Bool
    public init(commits: [GitCommitRow] = [], hasMore: Bool = false) {
        self.commits = commits
        self.hasMore = hasMore
    }
}

public struct GitCommitDetailRequest: OperationRequest {
    public typealias Response = GitCommitDetailResponse
    public static let operation = AppOperation.gitCommitDetail
    public var projectID: String
    public var commit: String
    public init(projectID: String, commit: String) {
        self.projectID = projectID
        self.commit = commit
    }
}

/// One file a commit touched, with what happened to it.
public struct GitChangedFile: Codable, Sendable, Equatable, Hashable {
    public var path: String
    /// `A`, `M`, `D`, `R`, `C`.
    public var status: String
    public var oldPath: String?
    public init(path: String, status: String, oldPath: String? = nil) {
        self.path = path
        self.status = status
        self.oldPath = oldPath
    }

    public var statusDescription: String {
        switch status {
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        default: "Modified"
        }
    }
}

public struct GitCommitDetailResponse: Codable, Sendable, Equatable {
    public var id: String
    public var message: String
    public var authorName: String
    public var authorEmail: String
    public var authoredAt: Double
    public var files: [GitChangedFile]
    public init(
        id: String,
        message: String,
        authorName: String,
        authorEmail: String,
        authoredAt: Double,
        files: [GitChangedFile] = [],
    ) {
        self.id = id
        self.message = message
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredAt = authoredAt
        self.files = files
    }
}

public struct GitCommitFileDiffRequest: OperationRequest {
    public typealias Response = GitCommitFileDiffResponse
    public static let operation = AppOperation.gitCommitFileDiff
    public var projectID: String
    public var commit: String
    public var path: String
    public init(projectID: String, commit: String, path: String) {
        self.projectID = projectID
        self.commit = commit
        self.path = path
    }
}

public struct GitCommitFileDiffResponse: Codable, Sendable, Equatable {
    public var diff: String
    public init(diff: String) {
        self.diff = diff
    }
}

/// The two texts of one file, for the line-by-line page.
///
/// `staged` picks the pair: true is the index against HEAD (what a commit
/// would take), false the work tree against the index (what is not staged
/// yet). An untracked file's old side is empty.
public struct GitFileVersionsRequest: OperationRequest {
    public typealias Response = GitFileVersionsResponse
    public static let operation = AppOperation.gitFileVersions
    public var projectID: String
    public var path: String
    public var staged: Bool
    public init(projectID: String, path: String, staged: Bool) {
        self.projectID = projectID
        self.path = path
        self.staged = staged
    }
}

public struct GitFileVersionsResponse: Codable, Sendable, Equatable {
    public var old: String
    public var new: String
    /// One side is not text: the page says so rather than showing bytes.
    public var isBinary: Bool
    /// A side was longer than the cap and was cut.
    public var truncated: Bool
    public init(old: String = "", new: String = "", isBinary: Bool = false, truncated: Bool = false) {
        self.old = old
        self.new = new
        self.isBinary = isBinary
        self.truncated = truncated
    }
}

public extension ApelinService {
    func gitLog(projectID: String, limit: Int = 100, skip: Int = 0) async throws -> GitLogResponse {
        try await send(GitLogRequest(projectID: projectID, limit: limit, skip: skip))
    }

    func gitCommitDetail(projectID: String, commit: String) async throws -> GitCommitDetailResponse {
        try await send(GitCommitDetailRequest(projectID: projectID, commit: commit))
    }

    func gitCommitFileDiff(projectID: String, commit: String, path: String) async throws -> GitCommitFileDiffResponse {
        try await send(GitCommitFileDiffRequest(projectID: projectID, commit: commit, path: path))
    }

    func gitFileVersions(projectID: String, path: String, staged: Bool) async throws -> GitFileVersionsResponse {
        try await send(GitFileVersionsRequest(projectID: projectID, path: path, staged: staged))
    }
}
