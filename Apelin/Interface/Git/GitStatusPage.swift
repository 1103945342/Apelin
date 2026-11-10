import SnapKit
import Then
import UIKit

/// A row's place in its group's card: the first and last keep the card's
/// corners, the middle rows meet square.
enum GitGroupPosition {
    case single, first, middle, last
}

struct GitHeader {
    let title: String
    var action: String?
    var actionEnabled = true
    var actionTint: UIColor?
}

struct GitFileItem {
    let entry: GitEntry
    let code: String
    let staged: Bool
    let conflicted: Bool
}

struct GitDirectoryItem {
    let path: String
    let children: [GitEntry]
    let expanded: Bool
}

/// The status page: what the working tree holds, the commit button, the four
/// secondary actions, and every group of changed paths, each row with its
/// badge and its stage button. Long-press opens the row's sheet; the commit
/// dialog, the stash sheet and every confirmation are the reference app's.
final class GitStatusPage: UIViewController, GitPage {
    private let session: GitSession
    weak var host: GitPageHost?

    private let table = UITableView(frame: .zero, style: .plain)
    private var items: [Item] = []

    private var expandedDirs: Set<String> = []
    private var busy = false {
        didSet {
            host?.gitSetBusy(busy)
            table.reloadData()
        }
    }

    init(session: GitSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.showsVerticalScrollIndicator = false
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 64
        table.register(GitOverviewCell.self, forCellReuseIdentifier: "overview")
        table.register(GitCommitCell.self, forCellReuseIdentifier: "commit")
        table.register(GitActionsCell.self, forCellReuseIdentifier: "actions")
        table.register(GitCleanCell.self, forCellReuseIdentifier: "clean")
        table.register(GitHeaderCell.self, forCellReuseIdentifier: "header")
        table.register(GitFileCell.self, forCellReuseIdentifier: "file")
        table.register(GitDirCell.self, forCellReuseIdentifier: "dir")
        table.register(GitMergeBannerCell.self, forCellReuseIdentifier: "merge")
        view.addSubview(table)
        table.snp.makeConstraints { make in make.edges.equalToSuperview() }
        applyBottomInset()

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        table.addGestureRecognizer(longPress)

        applySession()
    }

    func applyBottomInset() {
        table.contentInset.bottom = 70 + view.safeAreaInsets.bottom
        table.verticalScrollIndicatorInsets.bottom = 70 + view.safeAreaInsets.bottom
    }

    func pageDidAppear() {
        Task { @MainActor in await session.reloadStashes() }
    }

    // MARK: - Model

    private enum Item {
        case overview
        case commit
        case actions
        case clean
        case header(GitHeader)
        case mergeBanner
        case file(GitFileItem, position: GitGroupPosition)
        case directory(GitDirectoryItem, position: GitGroupPosition)
    }

    private var stagedFiles: [GitFileItem] {
        session.staged.map { GitFileItem(entry: $0, code: statusCode($0.index), staged: true, conflicted: false) }
    }

    private var modifiedFiles: [GitFileItem] {
        session.modified.map { entry in
            GitFileItem(entry: entry, code: statusCode(entry.worktree), staged: false, conflicted: false)
        }
    }

    private var conflictedFiles: [GitFileItem] {
        session.conflicted.map { GitFileItem(entry: $0, code: "U", staged: false, conflicted: true) }
    }

    private var untrackedSections: ([GitFileItem], [GitDirectoryItem]) {
        var top: [GitEntry] = []
        var grouped: [String: [GitEntry]] = [:]
        for entry in session.untracked {
            let path = entry.path
            if path.hasSuffix("/") {
                grouped[path, default: []].append(entry)
                continue
            }
            if let slash = path.firstIndex(of: "/") {
                let dir = String(path[..<slash]) + "/"
                grouped[dir, default: []].append(entry)
            } else {
                top.append(entry)
            }
        }
        let files = top.map { GitFileItem(entry: $0, code: "?", staged: false, conflicted: false) }
        let dirs = grouped.keys.sorted().map { path in
            let children = (grouped[path] ?? []).filter { $0.path != path }
            return GitDirectoryItem(
                path: path,
                children: children.sorted { $0.path < $1.path },
                expanded: expandedDirs.contains(path),
            )
        }
        return (files, dirs)
    }

    private var hasChanges: Bool { session.hasChanges }
    private var hasRemote: Bool { session.upstream != nil || !session.remoteBranches.isEmpty }
    private var isMerging: Bool { session.isMerging }

    private func statusCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "M" : String(trimmed.prefix(1))
    }

    // MARK: - Building the rows

    func applySession() {
        var items: [Item] = [.overview, .commit, .actions]
        if !hasChanges {
            items.append(.clean)
        } else {
            if !conflictedFiles.isEmpty {
                items.append(.header(GitHeader(
                    title: String(localized: "Conflicts (\(conflictedFiles.count))"),
                    action: isMerging ? String(localized: "Abort Merge") : nil,
                    actionEnabled: !busy,
                )))
                appendFiles(conflictedFiles, to: &items)
            } else if isMerging {
                items.append(.mergeBanner)
            }
            if !stagedFiles.isEmpty {
                items.append(.header(GitHeader(
                    title: String(localized: "Staged (\(stagedFiles.count))"),
                    action: String(localized: "Unstage all"),
                    actionEnabled: !busy,
                )))
                appendFiles(stagedFiles, to: &items)
            }
            if !modifiedFiles.isEmpty {
                items.append(.header(GitHeader(
                    title: String(localized: "Modified (\(modifiedFiles.count))"),
                    action: String(localized: "Revert all"),
                    actionEnabled: !busy,
                )))
                appendFiles(modifiedFiles, to: &items)
            }
            let (untrackedFiles, untrackedDirs) = untrackedSections
            if !untrackedFiles.isEmpty || !untrackedDirs.isEmpty {
                items.append(.header(GitHeader(
                    title: String(localized: "Untracked (\(untrackedFiles.count + untrackedDirs.count))"),
                )))
                for file in untrackedFiles {
                    items.append(.file(file, position: .single))
                }
                for directory in untrackedDirs {
                    items.append(.directory(directory, position: .single))
                }
            }
        }
        self.items = items
        table.reloadData()
    }

    private func appendFiles(_ files: [GitFileItem], to items: inout [Item]) {
        for (index, file) in files.enumerated() {
            let position: GitGroupPosition = files.count == 1
                ? .single
                : index == 0 ? .first : index == files.count - 1 ? .last : .middle
            items.append(.file(file, position: position))
        }
    }

    // MARK: - Actions

    private func showCommitDialog() {
        let dialog = GitCommitDialogController(
            staged: stagedFiles,
            hasIdentity: session.hasIdentity,
            onCommit: { [weak self] message, amend in
                guard let self else { return }
                self.busy = true
                Task { @MainActor in
                    do {
                        try await self.session.commit(message: message, amend: amend)
                    } catch {
                        self.host?.gitShowToast(error.readableMessage)
                    }
                    self.busy = false
                }
            },
        )
        present(dialog, animated: true)
    }

    private func stage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        busy = true
        Task { @MainActor in
            await session.stage(paths)
            busy = false
        }
    }

    private func unstage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        busy = true
        Task { @MainActor in
            await session.unstage(paths)
            busy = false
        }
    }

    private func stageAll() {
        guard hasChanges else { return }
        busy = true
        Task { @MainActor in
            await session.stageAll()
            busy = false
        }
    }

    private func unstageAll() {
        presentGitDialog(
            title: String(localized: "Unstage all"),
            message: String(localized: "All files will be unstaged, but their contents will not be deleted. Continue?"),
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Unstage all")) { [weak self] in
                    guard let self else { return }
                    self.busy = true
                    Task { @MainActor in
                        await self.session.unstageAll()
                        self.busy = false
                    }
                },
            ],
        )
    }

    private func revertAll() {
        presentGitDialog(
            title: String(localized: "Revert all"),
            message: String(localized: "Discard all unstaged changes (\(session.modified.count) files) and restore them to the last staged or committed content? Staged content is unaffected, but discarded changes cannot be recovered."),
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Revert all"), destructive: true) { [weak self] in
                    guard let self else { return }
                    let paths = self.modifiedFiles.map(\.entry.path)
                    self.busy = true
                    Task { @MainActor in
                        await self.session.restore(paths, source: .index)
                        self.busy = false
                    }
                },
            ],
        )
    }

    private func revert(file: GitFileItem) {
        let deleted = file.code == "D" && !file.staged
        let title = deleted ? String(localized: "Restore file") : String(localized: "Revert changes")
        let message: String
        if deleted {
            message = String(localized: "Restore the deleted \(file.entry.path)? The file will be brought back from the last commit.")
        } else if file.staged {
            message = String(localized: "Restore \(file.entry.path) to its last committed content? Both staged and unstaged changes to this file will be lost and cannot be recovered.")
        } else {
            message = String(localized: "Restore \(file.entry.path) to its last staged or committed content? Unstaged changes will be lost and cannot be recovered.")
        }
        presentGitDialog(
            title: title,
            message: message,
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: title, destructive: !deleted) { [weak self] in
                    guard let self else { return }
                    self.busy = true
                    Task { @MainActor in
                        await self.session.restore(
                            [file.entry.path],
                            source: file.staged ? .head : .index,
                        )
                        self.busy = false
                    }
                },
            ],
        )
    }

    private func deleteUntracked(_ paths: [String], isDirectory: Bool) {
        let name = paths.first ?? ""
        presentGitDialog(
            title: isDirectory ? String(localized: "Delete folder") : String(localized: "Delete file"),
            message: String(localized: "Delete \(name)? It has never been committed, so Git cannot recover it after deletion."),
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Delete"), destructive: true) { [weak self] in
                    guard let self else { return }
                    self.busy = true
                    Task { @MainActor in
                        await self.session.deleteUntracked(paths)
                        self.busy = false
                    }
                },
            ],
        )
    }

    private func ignore(_ pattern: String) {
        busy = true
        Task { @MainActor in
            await session.ignore(pattern)
            busy = false
            host?.gitShowSuccess(String(localized: "Added to .gitignore"))
        }
    }

    private func copyPath(_ path: String) {
        UIPasteboard.general.string = path
        host?.gitShowSuccess(String(localized: "Path copied"))
    }

    private func openDiff(path: String, staged: Bool) {
        let page = GitDiffPage(session: session, source: .worktree(staged: staged), path: path)
        page.host = host
        host?.gitShowDiff(page)
    }

    private func pull() {
        guard hasRemote else {
            host?.gitShowToast(String(localized: "No remote repository configured, cannot pull"))
            return
        }
        if session.hasChanges {
            presentGitDialog(
                title: String(localized: "Pull"),
                message: String(localized: "The working tree has uncommitted changes. Pulling may cause conflicts. Commit or stage them first if possible. Continue pulling?"),
                actions: [
                    .init(title: String(localized: "Cancel")) {},
                    .init(title: String(localized: "Continue Pull")) { [weak self] in self?.startPull() },
                ],
            )
            return
        }
        startPull()
    }

    private func startPull() {
        busy = true
        Task { @MainActor in
            do {
                try await session.pullAndWait()
            } catch {
                host?.gitShowToast(error.readableMessage)
            }
            busy = false
        }
    }

    private func push() {
        guard hasRemote else {
            host?.gitShowToast(String(localized: "No remote repository configured, cannot push"))
            return
        }
        let branch = session.currentBranch ?? "main"
        if branch == "master", session.upstream == nil {
            presentGitDialog(
                title: String(localized: "Branch Naming Suggestion"),
                message: String(localized: "Current local branch is \"master\". GitHub and GitLab recommend using \"main\" as the default branch. Would you like to rename it to \"main\" before pushing?"),
                actions: [
                    .init(title: String(localized: "Cancel")) {},
                    .init(title: String(localized: "Keep master & Push")) { [weak self] in
                        self?.startPush(branch: "master")
                    },
                    .init(title: String(localized: "Rename to main & Push")) { [weak self] in
                        guard let self else { return }
                        self.busy = true
                        Task { @MainActor in
                            do {
                                try await self.session.renameBranch(from: "master", to: "main")
                                try await self.session.pushAndWait(branch: "main")
                            } catch {
                                self.host?.gitShowToast(error.readableMessage)
                            }
                            self.busy = false
                        }
                    },
                ],
            )
            return
        }
        startPush(branch: branch)
    }

    private func startPush(branch: String) {
        busy = true
        Task { @MainActor in
            do {
                try await session.pushAndWait(branch: branch)
            } catch {
                host?.gitShowToast(error.readableMessage)
            }
            busy = false
        }
    }

    private func abortMerge() {
        presentGitDialog(
            title: String(localized: "Abort Merge"),
            message: String(localized: "Abort the current merge? Unresolved changes will be discarded and the working tree will be restored."),
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Abort Merge"), destructive: true) { [weak self] in
                    guard let self else { return }
                    self.busy = true
                    Task { @MainActor in
                        do {
                            try await self.session.abortMerge()
                        } catch {
                            self.host?.gitShowToast(error.readableMessage)
                        }
                        self.busy = false
                    }
                },
            ],
        )
    }

    // MARK: - Stash sheet

    private func showStashSheet() {
        let content = GitStashSheetContent(
            stashes: session.stashes,
            hasChanges: hasChanges,
            busy: busy,
            onSave: { [weak self] message, includeUntracked in
                guard let self else { return }
                self.busy = true
                Task { @MainActor in
                    do {
                        _ = try await self.session.saveStash(message: message, includeUntracked: includeUntracked)
                    } catch {
                        self.host?.gitShowToast(error.readableMessage)
                    }
                    self.busy = false
                }
            },
            onPop: { [weak self] stash in self?.applyStash(stash, pop: true) },
            onApply: { [weak self] stash in self?.applyStash(stash, pop: false) },
            onDrop: { [weak self] stash in self?.confirmDrop(stash) },
            onClear: { [weak self] in self?.confirmClear() },
        )
        presentGitSheet(content: content)
    }

    private func applyStash(_ stash: GitStash, pop: Bool) {
        busy = true
        Task { @MainActor in
            do {
                let conflicts = try await session.applyStash(stash, pop: pop)
                if !conflicts.isEmpty {
                    host?.gitShowToast(String(localized: "Conflicts (\(conflicts.count))"))
                }
            } catch {
                host?.gitShowToast(error.readableMessage)
            }
            busy = false
        }
    }

    private func confirmDrop(_ stash: GitStash) {
        presentGitDialog(
            title: String(localized: "Drop"),
            message: String(localized: "Drop stash \(stash.index)? This action cannot be undone."),
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Delete"), destructive: true) { [weak self] in
                    guard let self else { return }
                    self.busy = true
                    Task { @MainActor in
                        do { try await self.session.dropStash(stash) } catch {
                            self.host?.gitShowToast(error.readableMessage)
                        }
                        self.busy = false
                    }
                },
            ],
        )
    }

    private func confirmClear() {
        presentGitDialog(
            title: String(localized: "Clear All"),
            message: String(localized: "Clear all stashes? This action cannot be undone."),
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Delete"), destructive: true) { [weak self] in
                    guard let self else { return }
                    self.busy = true
                    Task { @MainActor in
                        do { try await self.session.clearStashes() } catch {
                            self.host?.gitShowToast(error.readableMessage)
                        }
                        self.busy = false
                    }
                },
            ],
        )
    }

    // MARK: - Long press

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: table)
        guard let indexPath = table.indexPathForRow(at: point) else { return }
        switch items[indexPath.row] {
        case let .file(file, _):
            showFileMenu(file)
        case let .directory(directory, _):
            showDirectoryMenu(directory)
        default:
            break
        }
    }

    private func showFileMenu(_ file: GitFileItem) {
        let path = file.entry.path
        var rows: [GitBottomSheetController.Row] = [
            .init(title: String(localized: "View diff"), symbol: GitIcon.Name.fileText) { [weak self] in
                self?.openDiff(path: path, staged: file.staged)
            },
        ]
        if file.conflicted {
            rows.append(.init(title: String(localized: "Stage"), symbol: GitIcon.Name.plus) { [weak self] in
                self?.stage([path])
            })
        } else if file.staged {
            rows.append(.init(title: String(localized: "Revert changes"), symbol: GitIcon.Name.rotate, destructive: true) { [weak self] in
                self?.revert(file: file)
            })
        } else if file.code == "D" {
            rows.append(.init(title: String(localized: "Restore file"), symbol: GitIcon.Name.rotate) { [weak self] in
                self?.revert(file: file)
            })
        } else {
            rows.append(.init(title: String(localized: "Revert changes"), symbol: GitIcon.Name.rotate, destructive: true) { [weak self] in
                self?.revert(file: file)
            })
        }
        if !file.staged, file.code == "?" {
            let name = (path as NSString).lastPathComponent
            rows.insert(.init(title: String(localized: "Ignore this file (\(name))"), symbol: GitIcon.Name.eyeOff) { [weak self] in
                self?.ignore("/\(path)")
            }, at: 1)
            let ext = (path as NSString).pathExtension
            if !ext.isEmpty {
                rows.insert(.init(title: String(localized: "Ignore same extension (*.\(ext))"), symbol: GitIcon.Name.eyeOff) { [weak self] in
                    self?.ignore("*.\(ext)")
                }, at: 2)
            }
            rows.append(.init(title: String(localized: "Delete file"), symbol: GitIcon.Name.trash, destructive: true) { [weak self] in
                self?.deleteUntracked([path], isDirectory: false)
            })
        }
        rows.append(.init(title: String(localized: "Copy path"), symbol: GitIcon.Name.copy) { [weak self] in
            self?.copyPath(path)
        })
        presentGitSheet(title: path, rows: rows)
    }

    private func showDirectoryMenu(_ directory: GitDirectoryItem) {
        let name = (directory.path as NSString).lastPathComponent
        let children = directory.children.map(\.path)
        presentGitSheet(title: directory.path, rows: [
            .init(title: String(localized: "Ignore directory (\(name)/)"), symbol: GitIcon.Name.eyeOff) { [weak self] in
                self?.ignore("/\(directory.path)")
            },
            .init(title: String(localized: "Delete folder"), symbol: GitIcon.Name.trash, destructive: true) { [weak self] in
                self?.deleteUntracked(children, isDirectory: true)
            },
            .init(title: String(localized: "Copy path"), symbol: GitIcon.Name.copy) { [weak self] in
                self?.copyPath(directory.path)
            },
        ])
    }
}

// MARK: - Table

extension GitStatusPage: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch items[indexPath.row] {
        case .overview:
            let cell = tableView.dequeueReusableCell(withIdentifier: "overview", for: indexPath) as! GitOverviewCell
            cell.configure(status: session.status, clean: !hasChanges)
            return cell
        case .commit:
            let cell = tableView.dequeueReusableCell(withIdentifier: "commit", for: indexPath) as! GitCommitCell
            let enabled = !busy && !stagedFiles.isEmpty && session.hasIdentity
            cell.configure(enabled: enabled, hasIdentity: session.hasIdentity) { [weak self] in
                self?.showCommitDialog()
            }
            return cell
        case .actions:
            let cell = tableView.dequeueReusableCell(withIdentifier: "actions", for: indexPath) as! GitActionsCell
            cell.configure(
                stageAllEnabled: !busy && hasChanges,
                stashEnabled: !busy,
                pullEnabled: !busy && hasRemote,
                pushEnabled: !busy && hasRemote,
                onStageAll: { [weak self] in self?.stageAll() },
                onStash: { [weak self] in self?.showStashSheet() },
                onPull: { [weak self] in self?.pull() },
                onPush: { [weak self] in self?.push() },
            )
            return cell
        case .clean:
            return tableView.dequeueReusableCell(withIdentifier: "clean", for: indexPath)
        case let .header(header):
            let cell = tableView.dequeueReusableCell(withIdentifier: "header", for: indexPath) as! GitHeaderCell
            cell.configure(header: header) { [weak self] in
                guard let self else { return }
                if header.title.hasPrefix(String(localized: "Staged")) {
                    self.unstageAll()
                } else if header.title.hasPrefix(String(localized: "Modified")) {
                    self.revertAll()
                } else {
                    self.abortMerge()
                }
            }
            return cell
        case let .file(file, position):
            let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath) as! GitFileCell
            cell.configure(
                file: file,
                position: position,
                busy: busy,
                onAction: { [weak self] in
                    guard let self else { return }
                    if file.staged {
                        self.unstage([file.entry.path])
                    } else {
                        self.stage([file.entry.path])
                    }
                },
                onOpen: { [weak self] in
                    self?.openDiff(path: file.entry.path, staged: file.staged)
                },
            )
            return cell
        case let .directory(directory, position):
            let cell = tableView.dequeueReusableCell(withIdentifier: "dir", for: indexPath) as! GitDirCell
            cell.configure(
                directory: directory,
                position: position,
                busy: busy,
                onToggle: { [weak self] in
                    guard let self else { return }
                    if self.expandedDirs.contains(directory.path) {
                        self.expandedDirs.remove(directory.path)
                    } else {
                        self.expandedDirs.insert(directory.path)
                    }
                    self.applySession()
                },
                onStage: { [weak self] in
                    self?.stage(directory.children.map(\.path))
                },
            )
            return cell
        case .mergeBanner:
            let cell = tableView.dequeueReusableCell(withIdentifier: "merge", for: indexPath) as! GitMergeBannerCell
            cell.configure { [weak self] in self?.abortMerge() }
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        switch items[indexPath.row] {
        case let .file(file, _):
            openDiff(path: file.entry.path, staged: file.staged)
        case let .directory(directory, _):
            if expandedDirs.contains(directory.path) {
                expandedDirs.remove(directory.path)
            } else {
                expandedDirs.insert(directory.path)
            }
            applySession()
        default:
            break
        }
    }
}

// MARK: - Cells

private enum GitCellCard {
    /// Puts a row inside the group's card: the first and last keep their
    /// corners, the middle rows meet square.
    static func apply(to card: UIView, position: GitGroupPosition) {
        card.backgroundColor = GitTheme.cardSurface
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        switch position {
        case .single:
            card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                        .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .first:
            card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .last:
            card.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .middle:
            card.layer.maskedCorners = []
        }
    }
}

private final class GitOverviewCell: UITableViewCell {
    private let card = UIView()
    private let sync = UILabel()
    private let metrics = UIStackView()
    private let icon = UIImageView(image: GitIcon.image(GitIcon.Name.branch, pointSize: 18))
    private let stateLabel = UILabel()
    private let branchLabel = UILabel()
    private let upstreamLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)
        card.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalToSuperview()
            make.bottom.equalToSuperview().offset(-4)
        }
        icon.tintColor = GitTheme.primary
        icon.contentMode = .scaleAspectFit
        stateLabel.font = GitTheme.labelMedium
        stateLabel.textColor = GitTheme.onSurfaceVariant
        branchLabel.font = GitTheme.mono(16, .medium)
        branchLabel.textColor = GitTheme.onSurface
        branchLabel.numberOfLines = 1
        branchLabel.lineBreakMode = .byTruncatingMiddle
        upstreamLabel.font = GitTheme.labelSmall
        upstreamLabel.textColor = GitTheme.onSurfaceVariant
        upstreamLabel.numberOfLines = 1
        sync.font = GitTheme.mono(12)
        sync.textColor = GitTheme.onSurfaceVariant
        sync.backgroundColor = GitTheme.mutedSurface
        sync.layer.cornerRadius = 8
        sync.layer.cornerCurve = .continuous
        sync.textAlignment = .center
        sync.clipsToBounds = true

        let text = UIStackView(arrangedSubviews: [stateLabel, branchLabel, upstreamLabel]).then {
            $0.axis = .vertical
            $0.spacing = 0
            $0.alignment = .leading
        }
        let head = UIStackView(arrangedSubviews: [icon, text, sync]).then {
            $0.axis = .horizontal
            $0.spacing = GitTheme.Space.sm
            $0.alignment = .center
        }
        icon.snp.makeConstraints { make in make.size.equalTo(18) }
        sync.snp.makeConstraints { make in make.height.equalTo(24) }

        metrics.axis = .horizontal
        metrics.spacing = GitTheme.Space.sm
        metrics.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [head, metrics]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.md
        }
        card.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(GitTheme.Space.lg)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(status: GitStatus?, clean: Bool) {
        stateLabel.text = clean
            ? String(localized: "Working tree clean")
            : String(localized: "Working tree has changes")
        branchLabel.text = status?.branch ?? String(localized: "(no branch)")
        if status?.isDetached == true {
            upstreamLabel.text = String(localized: "detached HEAD: not on any branch")
            upstreamLabel.textColor = GitTheme.error
        } else if let upstream = status?.upstream {
            let ahead = status?.ahead ?? 0
            let behind = status?.behind ?? 0
            var text = String(localized: "Tracking \(upstream)")
            if ahead > 0 { text += " · " + String(localized: "\(ahead) to push") }
            if behind > 0 { text += " · " + String(localized: "\(behind) to pull") }
            upstreamLabel.text = text
            upstreamLabel.textColor = GitTheme.onSurfaceVariant
        } else if status != nil {
            upstreamLabel.text = String(localized: "No upstream set")
            upstreamLabel.textColor = GitTheme.onSurfaceVariant
        } else {
            upstreamLabel.text = nil
        }
        let ahead = status?.ahead ?? 0
        let behind = status?.behind ?? 0
        sync.isHidden = ahead == 0 && behind == 0
        var syncText: [String] = []
        if ahead > 0 { syncText.append(String(localized: "\(ahead) to push")) }
        if behind > 0 { syncText.append(String(localized: "\(behind) to pull")) }
        sync.text = "  " + syncText.joined(separator: "  ") + "  "

        metrics.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let entries = status?.entries, entries.contains(where: \.isConflicted) {
            metrics.addArrangedSubview(GitMetricView(
                title: String(localized: "Conflicts"),
                count: entries.filter(\.isConflicted).count,
                color: GitTheme.error,
            ))
        }
        metrics.addArrangedSubview(GitMetricView(
            title: String(localized: "Staged"),
            count: status?.entries.filter(\.isStaged).count ?? 0,
            color: GitTheme.success,
        ))
        metrics.addArrangedSubview(GitMetricView(
            title: String(localized: "Modified"),
            count: status?.entries.filter(\.isModified).count ?? 0,
            color: GitTheme.warning,
        ))
        metrics.addArrangedSubview(GitMetricView(
            title: String(localized: "Untracked"),
            count: status?.entries.filter(\.isUntracked).count ?? 0,
            color: GitTheme.onSurfaceVariant,
        ))
    }
}

private final class GitCommitCell: UITableViewCell {
    private let button = GitButtons.primary(title: String(localized: "Commit Changes"), symbol: GitIcon.Name.check)
    private let hint = UILabel().then {
        $0.text = String(localized: "No commit identity configured. Set your name and email in “Credentials & Identity”.")
        $0.font = GitTheme.bodySmall
        $0.textColor = GitTheme.onSurfaceVariant
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }
    private var action: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        let stack = UIStackView(arrangedSubviews: [button, hint]).then {
            $0.axis = .vertical
            $0.spacing = 4
        }
        contentView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalToSuperview().offset(12)
            make.bottom.equalToSuperview()
        }
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(enabled: Bool, hasIdentity: Bool, action: @escaping () -> Void) {
        self.action = action
        button.isEnabled = enabled
        hint.isHidden = hasIdentity
    }
}

private final class GitActionsCell: UITableViewCell {
    private let stage = GitButtons.action(title: String(localized: "Stage All"), symbol: GitIcon.Name.plus)
    private let stash = GitButtons.action(title: String(localized: "Stash"), symbol: GitIcon.Name.archive)
    private let pull = GitButtons.action(title: String(localized: "Pull"), symbol: GitIcon.Name.downloadCloud)
    private let push = GitButtons.action(title: String(localized: "Push"), symbol: GitIcon.Name.uploadCloud)
    private var actions: [() -> Void] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        let row = UIStackView(arrangedSubviews: [stage, stash, pull, push]).then {
            $0.axis = .horizontal
            $0.spacing = GitTheme.Space.sm
            $0.distribution = .fillEqually
        }
        contentView.addSubview(row)
        row.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalToSuperview().offset(12)
            make.bottom.equalToSuperview()
        }
        for (index, button) in [stage, stash, pull, push].enumerated() {
            button.addAction(UIAction { [weak self] _ in
                guard let self, index < self.actions.count else { return }
                self.actions[index]()
            }, for: .touchUpInside)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        stageAllEnabled: Bool,
        stashEnabled: Bool,
        pullEnabled: Bool,
        pushEnabled: Bool,
        onStageAll: @escaping () -> Void,
        onStash: @escaping () -> Void,
        onPull: @escaping () -> Void,
        onPush: @escaping () -> Void,
    ) {
        stage.isEnabled = stageAllEnabled
        stash.isEnabled = stashEnabled
        pull.isEnabled = pullEnabled
        push.isEnabled = pushEnabled
        actions = [onStageAll, onStash, onPull, onPush]
    }
}

private final class GitCleanCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        let label = UILabel().then {
            $0.text = String(localized: "Working tree clean, no changes")
            $0.font = GitTheme.bodyMedium
            $0.textColor = GitTheme.onSurfaceVariant
            $0.textAlignment = .center
        }
        contentView.addSubview(label)
        label.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(96)
            make.bottom.equalToSuperview().offset(-32)
            make.leading.trailing.equalToSuperview().inset(16)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class GitHeaderCell: UITableViewCell {
    private let label = UILabel()
    private let button = GitButtons.text(title: "")
    private var action: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        label.font = GitTheme.font(13, .regular)
        label.textColor = GitTheme.subtleText
        label.numberOfLines = 1
        let row = UIStackView(arrangedSubviews: [label, button]).then {
            $0.axis = .horizontal
            $0.alignment = .center
        }
        contentView.addSubview(row)
        row.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.trailing.equalToSuperview().offset(-12)
            make.top.equalToSuperview().offset(16)
            make.bottom.equalToSuperview().offset(-4)
        }
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(header: GitHeader, onAction: @escaping () -> Void) {
        label.text = header.title
        label.isAccessibilityElement = true
        label.accessibilityTraits = .header
        if let title = header.action, !title.isEmpty {
            button.isHidden = false
            var configuration = button.configuration
            configuration?.title = title
            configuration?.baseForegroundColor = header.actionTint ?? GitTheme.primary
            button.configuration = configuration
            button.isEnabled = header.actionEnabled
            action = onAction
        } else {
            button.isHidden = true
            action = nil
        }
    }
}

private final class GitFileCell: UITableViewCell {
    private let card = UIView()
    private let chipHost = UIView()
    private let name = UILabel().then {
        $0.font = GitTheme.mono(14)
        $0.textColor = GitTheme.onSurface
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
    }
    private let directory = UILabel().then {
        $0.font = GitTheme.mono(11)
        $0.textColor = GitTheme.onSurfaceVariant
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
    }
    private let action = UIButton(type: .system)
    private let separator = UIView()
    private var onAction: (() -> Void)?
    private var onOpen: (() -> Void)?
    private var chip: GitStatusChip?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let tap = UITapGestureRecognizer(target: self, action: #selector(openTapped))
        // The stage button keeps its own taps; only the row around it opens
        // the diff.
        tap.delegate = self
        card.addGestureRecognizer(tap)
        contentView.addSubview(card)
        card.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.bottom.equalToSuperview()
        }
        card.addSubview(chipHost)
        let text = UIStackView(arrangedSubviews: [name, directory]).then {
            $0.axis = .vertical
            $0.spacing = 0
        }
        card.addSubview(text)
        card.addSubview(action)
        card.addSubview(separator)
        separator.backgroundColor = GitTheme.subtleBorder
        chipHost.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.width.equalTo(32)
            make.height.equalTo(20)
        }
        text.snp.makeConstraints { make in
            make.leading.equalTo(chipHost.snp.trailing).offset(GitTheme.Space.md)
            make.top.equalToSuperview().offset(GitTheme.Space.sm)
            make.bottom.equalToSuperview().offset(-GitTheme.Space.sm)
            make.trailing.lessThanOrEqualTo(action.snp.leading).offset(-8)
        }
        action.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-4)
            make.centerY.equalToSuperview()
            make.size.equalTo(44)
        }
        separator.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(60)
            make.trailing.equalToSuperview()
            make.bottom.equalToSuperview()
            make.height.equalTo(1 / UIScreen.main.scale)
        }
        action.tintColor = GitTheme.onSurfaceVariant
        action.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openTapped() {
        onOpen?()
    }

    func configure(
        file: GitFileItem,
        position: GitGroupPosition,
        busy: Bool,
        onAction: @escaping () -> Void,
        onOpen: @escaping () -> Void,
    ) {
        self.onAction = onAction
        self.onOpen = onOpen
        chip?.removeFromSuperview()
        let badge = GitStatusChip(code: file.code)
        badge.isAccessibilityElement = true
        badge.accessibilityLabel = statusWord(file.code)
        chipHost.addSubview(badge)
        badge.snp.makeConstraints { make in make.edges.equalToSuperview() }
        chip = badge
        let path = file.entry.path
        name.text = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        directory.text = dir.isEmpty ? nil : dir
        directory.isHidden = dir.isEmpty
        let symbol = file.staged ? GitIcon.Name.minus : GitIcon.Name.plus
        action.setImage(GitIcon.image(symbol, pointSize: 17), for: .normal)
        action.accessibilityLabel = file.staged ? String(localized: "Unstage") : String(localized: "Stage")
        action.isEnabled = !busy
        separator.isHidden = position == .last || position == .single
        GitCellCard.apply(to: card, position: position)
        isAccessibilityElement = false
        accessibilityElements = [badge, name, directory, action]
    }

    private func statusWord(_ code: String) -> String {
        switch code {
        case "A": String(localized: "Added")
        case "M": String(localized: "Modified")
        case "D": String(localized: "Deleted")
        case "R": String(localized: "Renamed")
        case "C": String(localized: "Copied")
        case "?": String(localized: "Untracked")
        default: String(localized: "Conflicted")
        }
    }
}

extension GitFileCell {
    override func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
}

private final class GitDirCell: UITableViewCell {
    private let card = UIView()
    private let chipHost = UIView()
    private let pathLabel = UILabel().then {
        $0.font = GitTheme.mono(14)
        $0.textColor = GitTheme.onSurface
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
    }
    private let count = UILabel().then {
        $0.font = GitTheme.labelSmall
        $0.textColor = GitTheme.onSurfaceVariant
    }
    private let chevron = UIImageView()
    private let action = UIButton(type: .system)
    private let separator = UIView()
    private var onToggle: (() -> Void)?
    private var onStage: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(card)
        card.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.bottom.equalToSuperview()
        }
        card.addSubview(chipHost)
        card.addSubview(pathLabel)
        card.addSubview(count)
        card.addSubview(chevron)
        card.addSubview(action)
        card.addSubview(separator)
        separator.backgroundColor = GitTheme.subtleBorder
        chipHost.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.width.equalTo(32)
            make.height.equalTo(20)
        }
        pathLabel.snp.makeConstraints { make in
            make.leading.equalTo(chipHost.snp.trailing).offset(GitTheme.Space.md)
            make.top.bottom.equalToSuperview().inset(GitTheme.Space.sm)
            make.trailing.lessThanOrEqualTo(count.snp.leading).offset(-8)
            make.height.greaterThanOrEqualTo(20)
        }
        count.snp.makeConstraints { make in
            make.trailing.equalTo(chevron.snp.leading).offset(-4)
            make.centerY.equalToSuperview()
        }
        chevron.tintColor = GitTheme.onSurfaceVariant
        chevron.contentMode = .scaleAspectFit
        chevron.snp.makeConstraints { make in
            make.trailing.equalTo(action.snp.leading).offset(-4)
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }
        action.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-4)
            make.centerY.equalToSuperview()
            make.size.equalTo(44)
        }
        action.tintColor = GitTheme.onSurfaceVariant
        action.setImage(GitIcon.image(GitIcon.Name.plus, pointSize: 17), for: .normal)
        action.accessibilityLabel = String(localized: "Stage")
        action.addAction(UIAction { [weak self] _ in self?.onStage?() }, for: .touchUpInside)
        separator.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(60)
            make.trailing.equalToSuperview()
            make.bottom.equalToSuperview()
            make.height.equalTo(1 / UIScreen.main.scale)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        directory: GitDirectoryItem,
        position: GitGroupPosition,
        busy: Bool,
        onToggle: @escaping () -> Void,
        onStage: @escaping () -> Void,
    ) {
        self.onToggle = onToggle
        self.onStage = onStage
        chipHost.subviews.forEach { $0.removeFromSuperview() }
        let badge = GitStatusChip(code: "?")
        chipHost.addSubview(badge)
        badge.snp.makeConstraints { make in make.edges.equalToSuperview() }
        pathLabel.text = directory.path
        count.text = directory.expanded ? "\(directory.children.count)" : nil
        chevron.image = GitIcon.image(
            directory.expanded ? GitIcon.Name.chevronDown : GitIcon.Name.chevronRight, pointSize: 16,
        )
        action.isEnabled = !busy
        separator.isHidden = position == .last || position == .single
        GitCellCard.apply(to: card, position: position)
        isAccessibilityElement = false
        accessibilityElements = [badge, pathLabel, count, chevron, action]
    }
}

private final class GitMergeBannerCell: UITableViewCell {
    private var action: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        let card = UIView().then {
            $0.backgroundColor = GitTheme.warning.withAlphaComponent(0.12)
            $0.layer.cornerRadius = GitTheme.Radius.mdLarge
            $0.layer.cornerCurve = .continuous
            $0.layer.borderWidth = 1
            $0.layer.borderColor = GitTheme.warning.withAlphaComponent(0.35).cgColor
        }
        let title = UILabel().then {
            $0.text = String(localized: "Merge Awaiting Commit")
            $0.font = GitTheme.font(13, .semibold)
            $0.textColor = GitTheme.warning
        }
        let hint = UILabel().then {
            $0.text = String(localized: "There are no unresolved conflicts. Review and stage the changes you want to keep, then commit to complete the merge.")
            $0.font = GitTheme.bodySmall
            $0.textColor = GitTheme.onSurfaceVariant
            $0.numberOfLines = 0
        }
        let abort = GitButtons.text(title: String(localized: "Abort Merge"))
        var abortConfiguration = abort.configuration
        abortConfiguration?.baseForegroundColor = GitTheme.error
        abort.configuration = abortConfiguration
        abort.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
        let text = UIStackView(arrangedSubviews: [title, hint]).then {
            $0.axis = .vertical
            $0.spacing = 2
        }
        let row = UIStackView(arrangedSubviews: [text, abort]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = 8
        }
        card.addSubview(row)
        row.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(GitTheme.Space.md)
        }
        contentView.addSubview(card)
        card.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalToSuperview().offset(12)
            make.bottom.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(onAbort: @escaping () -> Void) {
        action = onAbort
    }
}
