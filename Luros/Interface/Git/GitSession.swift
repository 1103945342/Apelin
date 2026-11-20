import ApelinCore
import ApelinProtocol
import Foundation

/// One changed path, as the page lists it. The wire's own name is spelled
/// here so the page can be written without importing `ApelinProtocol`, whose
/// `UIAction` would stand in for UIKit's at every button.
typealias GitEntry = GitStatusEntry
typealias GitStatus = GitStatusResponse
typealias GitNameRules = GitBranchName
typealias GitBranch = GitBranchRow
typealias GitTag = GitTagRow
typealias GitStash = GitStashRow
typealias GitCommit = GitCommitRow
typealias GitRef = GitRefRow
typealias GitFileChange = GitChangedFile
typealias GitVersions = GitFileVersionsResponse
typealias GitCommitDetail = GitCommitDetailResponse
typealias GitResetMode = GitResetRequest.Mode

/// One project's repository, as the visual Git page reads and changes it.
///
/// The page is a view of this: a tab asks for a reload, acts through it, and
/// draws whatever came back. Nothing here holds a view, so a tab can be built
/// and thrown away without losing what the others read.
@MainActor
final class GitSession {
    let projectName: String

    /// The folder inside the workspace that holds the repository, when it is
    /// not the workspace root: `Projects/<name>/<repository>/`.
    private(set) var repository: String?

    private(set) var status: GitStatusResponse?
    private(set) var branches: GitBranchesResponse?
    private(set) var commits: [GitCommitRow] = []
    private(set) var stashes: [GitStashRow] = []
    /// Whether the commit list stopped at a page with more behind it.
    private(set) var hasMoreCommits = false
    private(set) var isLoading = false
    /// What went wrong last, until the next read answers for it.
    private(set) var failure: String?
    /// The project is not a repository at all, rather than failing to read
    /// one: the page offers to make or clone one instead of a status.
    private(set) var isNotARepository = false

    /// Called on the main queue after anything here changed.
    var onChange: (() -> Void)?

    /// How many commits one page of the commits tab holds.
    static let commitPageSize = 100

    init(projectName: String) {
        self.projectName = projectName
    }

    // MARK: - What the page reads

    var branch: String? { status?.branch }
    var isDetached: Bool { status?.isDetached ?? false }
    var upstream: String? { status?.upstream }
    var ahead: Int { status?.ahead ?? 0 }
    var behind: Int { status?.behind ?? 0 }
    var hasIdentity: Bool { status?.hasIdentity ?? true }
    var isMerging: Bool { status?.mergeInProgress ?? false }

    /// The changed paths, split the way the status page lists them. A path can
    /// be in two of these at once — staged and changed again afterwards —
    /// which is what git's two columns mean.
    var staged: [GitEntry] { entries.filter(\.isStaged) }
    var modified: [GitEntry] { entries.filter(\.isModified) }
    var untracked: [GitEntry] { entries.filter(\.isUntracked) }
    var conflicted: [GitEntry] { entries.filter(\.isConflicted) }
    var hasChanges: Bool { !entries.isEmpty }

    /// `Projects/<name>/`, the workspace this page is the repository of — or
    /// the folder inside it, when the repository is there.
    var workspacePath: URL {
        let root = DataFolder.app.projects.appendingPathComponent(projectName, isDirectory: true)
        guard let repository else { return root }
        return root.appendingPathComponent(repository, isDirectory: true)
    }

    /// What every request names: the project, and the folder inside it when
    /// the repository sits below the workspace root.
    var scopeID: String {
        guard let repository else { return projectName }
        return "\(projectName)/\(repository)"
    }

    private var entries: [GitEntry] { status?.entries ?? [] }

    var localBranches: [GitBranchRow] { branches?.local ?? [] }
    var remoteBranches: [GitBranchRow] { branches?.remote ?? [] }
    var tags: [GitTagRow] { branches?.tags ?? [] }
    var currentBranch: String? { branches?.current ?? status?.branch }

    // MARK: - Reading

    /// Everything the page shows, after anything that changes the repository.
    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        onChange?()
        defer {
            isLoading = false
            onChange?()
        }
        do {
            status = try await ApelinService.app.gitStatus(projectID: scopeID)
            branches = try await ApelinService.app.gitBranches(projectID: scopeID)
            failure = nil
            isNotARepository = false
        } catch {
            note(error)
        }
        await reloadStashes()
    }

    /// The status alone — what a stage or an unstage changes.
    func reloadStatus() async {
        do {
            status = try await ApelinService.app.gitStatus(projectID: scopeID)
            failure = nil
            isNotARepository = false
        } catch {
            note(error)
        }
        onChange?()
    }

    func reloadBranches() async {
        do {
            branches = try await ApelinService.app.gitBranches(projectID: scopeID)
            failure = nil
        } catch {
            failure = error.readableMessage
        }
        onChange?()
    }

    func reloadStashes() async {
        do {
            stashes = try await ApelinService.app.gitStashList(projectID: scopeID).stashes
        } catch {
            stashes = []
        }
    }

    /// The first page of commits, replacing whatever was there.
    func reloadCommits() async {
        do {
            let page = try await ApelinService.app.gitLog(
                projectID: scopeID, limit: Self.commitPageSize, skip: 0,
            )
            commits = page.commits
            hasMoreCommits = page.hasMore
            failure = nil
        } catch {
            failure = error.readableMessage
        }
        onChange?()
    }

    /// The next page, appended. Answers whether anything came back.
    @discardableResult
    func loadMoreCommits() async -> Bool {
        guard hasMoreCommits else { return false }
        do {
            let page = try await ApelinService.app.gitLog(
                projectID: scopeID, limit: Self.commitPageSize, skip: commits.count,
            )
            let known = Set(commits.map(\.id))
            commits.append(contentsOf: page.commits.filter { !known.contains($0.id) })
            hasMoreCommits = page.hasMore
            onChange?()
            return !page.commits.isEmpty
        } catch {
            failure = error.readableMessage
            onChange?()
            return false
        }
    }

    // MARK: - Diffs

    /// The two whole texts of one file, for the line-by-line page.
    func fileVersions(path: String, staged: Bool) async throws -> GitFileVersionsResponse {
        try await ApelinService.app.gitFileVersions(projectID: scopeID, path: path, staged: staged)
    }

    func commitDetail(_ commit: String) async throws -> GitCommitDetailResponse {
        try await ApelinService.app.gitCommitDetail(projectID: scopeID, commit: commit)
    }

    func commitFileVersions(commit: String, path: String) async throws -> GitFileVersionsResponse {
        let detail = try await ApelinService.app.gitCommitFileDiff(
            projectID: scopeID, commit: commit, path: path,
        )
        return Self.versions(fromPatch: detail.diff)
    }

    // MARK: - Staging and committing

    func stage(_ paths: [String]) async {
        await perform { try await ApelinService.app.gitStage(projectID: self.scopeID, paths: paths) }
    }

    /// Every path the work tree holds a change for. The protocol stages a
    /// list, never "everything", so the list is the changes themselves.
    func stageAll() async {
        let paths = entries.filter { !$0.isStaged || $0.isUntracked }.map(\.path)
        guard !paths.isEmpty else { return }
        await stage(paths)
    }

    func unstage(_ paths: [String]) async {
        await perform { try await ApelinService.app.gitUnstage(projectID: self.scopeID, paths: paths) }
    }

    func unstageAll() async {
        let paths = staged.map(\.path)
        guard !paths.isEmpty else { return }
        await unstage(paths)
    }

    /// Puts a path back: `head` drops both the staged and the work-tree
    /// change, `index` only what is not staged.
    func restore(_ paths: [String], source: GitRestoreRequest.Source) async {
        await perform { try await ApelinService.app.gitRestore(projectID: self.scopeID, paths: paths, source: source) }
    }

    func deleteUntracked(_ paths: [String]) async {
        await perform { try await ApelinService.app.gitDeletePaths(projectID: self.scopeID, paths: paths) }
    }

    func ignore(_ pattern: String) async {
        await perform { _ = try await ApelinService.app.gitIgnoreAppend(projectID: self.scopeID, pattern: pattern) }
    }

    /// Commits the index with `message`; `all` stages every change first, as
    /// `git add --all` does, and `amend` rewrites HEAD's commit instead.
    func commit(message: String, all: Bool = false, amend: Bool = false) async throws {
        _ = try await ApelinService.app.gitCommit(GitCommitRequest(
            projectID: scopeID,
            message: message,
            all: all ? true : nil,
            amend: amend ? true : nil,
        ))
        await reload()
        await reloadCommits()
    }

    // MARK: - Branches, tags and merges

    func createBranch(name: String, startPoint: String?, checkout: Bool) async throws {
        _ = try await ApelinService.app.gitBranchCreate(GitBranchCreateRequest(
            projectID: scopeID, name: name, startPoint: startPoint, checkout: checkout,
        ))
        await reload()
        await reloadCommits()
    }

    func checkout(_ branch: GitBranchRow) async throws {
        let (remote, name) = Self.split(branch)
        _ = try await ApelinService.app.gitBranchCheckout(GitBranchCheckoutRequest(
            projectID: scopeID, name: name, remote: remote,
        ))
        await reload()
        await reloadCommits()
    }

    func checkout(name: String, remote: Bool) async throws {
        let remoteName = remote ? name.split(separator: "/").first.map(String.init) : nil
        let short = remote
            ? name.split(separator: "/").dropFirst().joined(separator: "/")
            : name
        _ = try await ApelinService.app.gitBranchCheckout(GitBranchCheckoutRequest(
            projectID: scopeID, name: short, remote: remoteName,
        ))
        await reload()
        await reloadCommits()
    }

    func deleteBranch(_ branch: GitBranchRow) async throws {
        let (remote, name) = Self.split(branch)
        _ = try await ApelinService.app.gitBranchDelete(GitBranchDeleteRequest(
            projectID: scopeID, name: name, remote: remote,
        ))
        await reload()
    }

    func renameBranch(from: String, to: String) async throws {
        _ = try await ApelinService.app.gitBranchRename(GitBranchRenameRequest(
            projectID: scopeID, from: from, to: to,
        ))
        await reload()
    }

    func merge(_ branch: String, noFastForward: Bool) async throws -> GitMergeResponse {
        let answer = try await ApelinService.app.gitMerge(GitMergeRequest(
            projectID: scopeID, branch: branch, noFastForward: noFastForward,
        ))
        await reload()
        await reloadCommits()
        return answer
    }

    func abortMerge() async throws {
        try await ApelinService.app.gitMergeAbort(projectID: scopeID)
        await reload()
    }

    func createTag(name: String, commit: String?, message: String?) async throws {
        _ = try await ApelinService.app.gitTagCreate(GitTagCreateRequest(
            projectID: scopeID, name: name, commit: commit, message: message,
        ))
        await reload()
        await reloadCommits()
    }

    func deleteTag(_ name: String) async throws {
        try await ApelinService.app.gitTagDelete(projectID: scopeID, name: name)
        await reload()
        await reloadCommits()
    }

    func reset(to commit: String, mode: GitResetMode) async throws {
        _ = try await ApelinService.app.gitReset(projectID: scopeID, commit: commit, mode: mode)
        await reload()
        await reloadCommits()
    }

    // MARK: - Stashes

    func saveStash(message: String?, includeUntracked: Bool) async throws -> Bool {
        let saved = try await ApelinService.app.gitStashSave(
            projectID: scopeID, message: message, includeUntracked: includeUntracked,
        ).saved
        await reload()
        return saved
    }

    func applyStash(_ stash: GitStashRow, pop: Bool) async throws -> [String] {
        let conflicts = try await ApelinService.app.gitStashApply(
            projectID: scopeID, index: stash.index, pop: pop,
        ).conflicts
        await reload()
        return conflicts
    }

    func dropStash(_ stash: GitStashRow) async throws {
        try await ApelinService.app.gitStashDrop(projectID: scopeID, index: stash.index)
        await reload()
    }

    func clearStashes() async throws {
        try await ApelinService.app.gitStashClear(projectID: scopeID)
        await reload()
    }

    // MARK: - Pull, push and init

    /// Starts a pull; the page follows the task it answers with.
    func pull() async throws -> TaskHandle {
        try await ApelinService.app.gitPull(projectID: scopeID)
    }

    func push(branch: String, url: String? = nil) async throws -> TaskHandle {
        try await ApelinService.app.gitPush(GitPushRequest(
            projectID: scopeID, branch: branch, url: url,
        ))
    }

    func initialise() async throws {
        _ = try await ApelinService.app.gitInit(projectID: projectName)
        isNotARepository = false
        await reload()
        await reloadCommits()
    }

    /// Points the page at a repository the workspace keeps in
    /// `repository` (nil: the workspace root), and reads it again from
    /// nothing, so nothing the last one answered is shown for this one.
    func open(repository: String?) async {
        guard repository != self.repository else {
            await reload()
            await reloadCommits()
            return
        }
        self.repository = repository
        status = nil
        branches = nil
        commits = []
        stashes = []
        hasMoreCommits = false
        failure = nil
        isNotARepository = false
        onChange?()
        await reload()
        guard !isNotARepository else { return }
        await reloadCommits()
        await reloadStashes()
    }

    /// Imports a repository into the workspace: the reference app's clone,
    /// which fills the folder that is there rather than making a new one.
    func cloneInto(url: String) async throws {
        let handle = try await ApelinService.app.gitCloneInto(GitCloneIntoRequest(
            projectID: projectName, url: url, branch: nil,
        ))
        try await follow(handle)
        isNotARepository = false
    }

    /// A pull or push is a task: the page waits for the one it started, as
    /// the reference app's action pipeline does, rather than reading the
    /// repository before the work has run.
    func pullAndWait() async throws {
        let handle = try await pull()
        try await follow(handle)
        await reload()
        await reloadCommits()
    }

    func pushAndWait(branch: String) async throws {
        let handle = try await push(branch: branch)
        try await follow(handle)
        await reload()
        await reloadCommits()
    }

    /// Reads a task to its final state, throwing what it failed with.
    func follow(_ handle: TaskHandle) async throws {
        var terminal: TaskState = .failed
        var message: String?
        for try await event in ApelinService.app.events(of: handle) {
            guard event.kind == TaskEvent.stateKind else { continue }
            if let raw = event.payload?["state"]?.stringValue, let state = TaskState(rawValue: raw) {
                terminal = state
            }
            if let said = event.payload?["message"]?.stringValue, !said.isEmpty {
                message = said
            }
        }
        guard terminal == .succeeded else {
            throw GitTaskError(message: message ?? String(localized: "The task did not finish."))
        }
    }

    private func note(_ error: Error) {
        failure = error.readableMessage
        if let error = error as? ApelinError,
           error.code == .notFound,
           error.reason?.rawValue == "notARepository"
        {
            isNotARepository = true
        }
    }

    // MARK: - Plumbing

    /// Runs one change and reloads whatever it did, keeping a failure for the
    /// page to show rather than throwing at a button.
    private func perform(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
            failure = nil
        } catch {
            failure = error.readableMessage
        }
        await reloadStatus()
        await reloadBranches()
    }

    /// A remote branch's remote and its short name; a local branch's name and
    /// no remote.
    private static func split(_ branch: GitBranchRow) -> (remote: String?, name: String) {
        guard branch.isRemote, let first = branch.name.split(separator: "/").first else {
            return (nil, branch.name)
        }
        let short = branch.name.split(separator: "/").dropFirst().joined(separator: "/")
        return (String(first), short)
    }

    /// The two sides of a patch: every `-` line but the headers is the old
    /// side, every `+` line but the headers the new one, and the context
    /// lines belong to both.
    static func versions(fromPatch patch: String) -> GitFileVersionsResponse {
        var old: [String] = []
        var new: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("@@")
                || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                || line.hasPrefix("similarity index") || line.hasPrefix("rename ")
            {
                continue
            }
            if line.hasPrefix("-") {
                old.append(String(line.dropFirst()))
            } else if line.hasPrefix("+") {
                new.append(String(line.dropFirst()))
            } else if line.hasPrefix(" ") {
                old.append(String(line.dropFirst()))
                new.append(String(line.dropFirst()))
            }
        }
        return GitFileVersionsResponse(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
    }
}

/// A task the Git page followed that ended without succeeding.
struct GitTaskError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension GitStatusEntry {
    /// In the index, waiting to be committed.
    var isStaged: Bool {
        !isUntracked && !isConflicted && index != " " && index != ""
    }

    /// Changed in the work tree, whether or not a version is staged too.
    var isModified: Bool {
        !isUntracked && !isConflicted && worktree != " " && worktree != ""
    }

    var isUntracked: Bool { index == "?" }

    /// Either side's `U`, which is git's way of saying the path is in a merge
    /// that has not been resolved.
    var isConflicted: Bool {
        index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D")
    }

    /// The letter the row shows: the work tree's state when there is one, else
    /// the index's.
    var shownStatus: String {
        if isUntracked { return "?" }
        if isConflicted { return "!" }
        let worktree = worktree.trimmingCharacters(in: .whitespaces)
        let index = index.trimmingCharacters(in: .whitespaces)
        if !worktree.isEmpty, worktree != "?" { return worktree }
        return index.isEmpty ? "M" : index
    }

    /// What the status letter means, for VoiceOver.
    var statusDescription: String {
        switch shownStatus {
        case "M": String(localized: "Modified")
        case "A": String(localized: "Added")
        case "D": String(localized: "Deleted")
        case "R": String(localized: "Renamed")
        case "C": String(localized: "Copied")
        case "?": String(localized: "Untracked")
        default: String(localized: "Conflicted")
        }
    }
}
