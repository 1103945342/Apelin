import AlertController
import ApelinCore
import SnapKit
import Then
import UIKit

/// The last page of the sidebar: the open workspace's folder, a directory at
/// a time, under a search field that stays where it is — aimini's file tab.
///
/// A folder opens where it stands; a file opens in the editor, which is the
/// only way this page changes one. Everything else here — a new file or
/// folder, a rename, a delete, a copy and a paste — is a long press away.
final class SidebarFilesController: UIViewController {
    /// A page the reader asked for, for the sidebar to present: a form sheet
    /// from inside a 340 pt column would be clipped by it.
    var onPresent: ((UIViewController) -> Void)?

    private var project: ProjectSummary?
    private var files: ProjectFiles?
    private var rows: [ProjectFile] = []
    private var query = ""
    /// What Copy or Cut put aside, and the file it came from.
    private var clipboard: (file: ProjectFile, moving: Bool)?
    /// The sentence the empty list is showing, so it is not made again on
    /// every rebuild.
    private var emptyState: String?

    private lazy var searchField = SidebarSearchField(placeholder: "Search files").then {
        $0.onChange = { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed != query else { return }
            query = trimmed
            rebuild()
        }
    }

    private lazy var newButton = UIButton(type: .system).then {
        $0.setImage(UIImage(systemName: "plus"), for: .normal)
        $0.accessibilityLabel = String(localized: "New")
        $0.showsMenuAsPrimaryAction = true
        $0.addAction(UIAction { [weak self] _ in self?.refreshMenu() }, for: .menuActionTriggered)
    }

    private let tableView = FirstFillTableView(frame: .zero, style: .plain).then {
        $0.backgroundColor = .clear
        $0.separatorStyle = .none
        // Self-sizing, with a height to start from: a name at a larger text
        // size grows the row rather than being cut off.
        $0.rowHeight = UITableView.automaticDimension
        $0.estimatedRowHeight = 40
        $0.register(SidebarFileCell.self, forCellReuseIdentifier: "file")
        $0.backgroundView = EmptyStateView(
            symbolName: "doc.text",
            text: String(localized: "No files yet. Long press to make one."),
            showsText: true,
        )
    }

    private lazy var dataSource = UITableViewDiffableDataSource<Int, String>(
        tableView: tableView,
    ) { [unowned self] tableView, indexPath, path in
        let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath) as! SidebarFileCell
        let file = rows.first { $0.relativePath == path }
        cell.configure(
            file: file,
            depth: query.isEmpty ? (file?.depth ?? 0) : 0,
            expanded: files?.isExpanded(path) ?? false,
        )
        return cell
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        view.addSubview(searchField)
        view.addSubview(newButton)
        view.addSubview(tableView)

        searchField.snp.makeConstraints { x in
            x.top.equalToSuperview()
            x.leading.equalToSuperview().offset(16)
            x.trailing.equalTo(newButton.snp.leading).offset(-8)
        }
        newButton.snp.makeConstraints { x in
            x.centerY.equalTo(searchField)
            x.trailing.equalToSuperview().offset(-16)
            x.size.equalTo(40)
        }
        tableView.snp.makeConstraints { x in
            x.top.equalTo(searchField.snp.bottom).offset(8)
            x.leading.trailing.bottom.equalToSuperview()
        }
        tableView.delegate = self
        rebuild()
    }

    // MARK: - What the sidebar asks for

    func update(project: ProjectSummary?) {
        guard project?.name != self.project?.name else {
            self.project = project
            return
        }
        self.project = project
        files = project.flatMap { DataFolder.app.project(named: $0.name) }.map { ProjectFiles(root: $0) }
        rows = []
        clipboard = nil
        query = ""
        searchField.text = ""
        guard isViewLoaded else { return }
        rebuild()
    }

    /// The page was opened again: the folder may have changed since the last
    /// time it was looked at, by a build or by the agent.
    func reload() {
        guard isViewLoaded else { return }
        files?.reloadAll()
        rebuild()
    }

    private func rebuild() {
        guard let files else {
            rows = []
            applyRows()
            setEmptyState(symbol: "folder", text: String(localized: "Pick a workspace to browse its files."))
            tableView.backgroundView?.isHidden = false
            searchField.isUserInteractionEnabled = false
            return
        }
        searchField.isUserInteractionEnabled = true
        rows = query.isEmpty ? files.rows() : files.search(query)
        applyRows()
        tableView.backgroundView?.isHidden = !rows.isEmpty
        // The empty state is the reader's only cue: an empty folder and a
        // search that found nothing are two different sentences.
        setEmptyState(
            symbol: query.isEmpty ? "doc.text" : "magnifyingglass",
            text: query.isEmpty
                ? String(localized: "No files yet. Long press to make one.")
                : String(localized: "No files match."),
        )
    }

    /// What the list says instead of rows, made again only when the sentence
    /// changes: `EmptyStateView` is written once, as a table's background.
    private func setEmptyState(symbol: String, text: String) {
        guard emptyState != text else { return }
        emptyState = text
        tableView.backgroundView = EmptyStateView(symbolName: symbol, text: text, showsText: true)
    }

    private func applyRows() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.relativePath), toSection: 0)
        let old = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reloadItems(snapshot.itemIdentifiers.filter { old.contains($0) })
        dataSource.applyChange(snapshot, to: tableView, animated: false)
    }

    // MARK: - Acting on a row

    private func toggle(_ file: ProjectFile) {
        files?.toggle(file.relativePath)
        rebuild()
    }

    private func open(_ file: ProjectFile) {
        guard let files else { return }
        let url = files.url(of: file.relativePath)
        let editor = FileEditorController(url: url, relativePath: file.relativePath)
        let folder = parent(of: file.relativePath)
        editor.onSaved = { [weak self] in
            self?.files?.reload(folder)
            self?.rebuild()
        }
        onPresent?(editor)
    }

    private func parent(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// The folder an action means: the row itself when it is one, the folder
    /// that holds it when it is a file, the project when there is no row.
    private func directory(for file: ProjectFile?) -> String {
        guard let file else { return "" }
        return file.isDirectory ? file.relativePath : parent(of: file.relativePath)
    }

    private func refreshMenu() {
        var actions: [UIMenuElement] = []
        let target = directory(for: nil)
        actions.append(UIAction(title: String(localized: "New File"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
            self?.createFile(in: target)
        })
        actions.append(UIAction(title: String(localized: "New Folder"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
            self?.createFolder(in: target)
        })
        actions.append(UIAction(title: String(localized: "Reload"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.reload()
        })
        newButton.menu = UIMenu(children: actions)
    }

    private func createFile(in directory: String) {
        askName(title: "New File", in: directory) { [weak self] name in
            guard let self else { return }
            do {
                try files?.createFile(named: name, in: directory)
                if !directory.isEmpty { files?.toggle(directory) }
                rebuild()
            } catch { presentNotice(title: "Unable to Create File", message: error.readableMessage) }
        }
    }

    private func createFolder(in directory: String) {
        askName(title: "New Folder", in: directory) { [weak self] name in
            guard let self else { return }
            do {
                try files?.createFolder(named: name, in: directory)
                if !directory.isEmpty { files?.toggle(directory) }
                rebuild()
            } catch { presentNotice(title: "Unable to Create Folder", message: error.readableMessage) }
        }
    }

    private func rename(_ file: ProjectFile) {
        let directory = parent(of: file.relativePath)
        askName(title: "Rename", in: directory, current: file.name) { [weak self] name in
            guard let self else { return }
            do {
                try files?.rename(file, to: name)
                rebuild()
            } catch { presentNotice(title: "Unable to Rename", message: error.readableMessage) }
        }
    }

    private func delete(_ file: ProjectFile) {
        presentConfirmation(
            title: "Delete “\(file.name)”?",
            message: file.isDirectory
                ? "The folder and everything in it will be deleted. This cannot be undone."
                : "This file will be deleted. This cannot be undone.",
            confirmTitle: "Delete",
            destructive: true,
        ) { [weak self] in
            guard let self else { return }
            do {
                try files?.delete(file)
                rebuild()
            } catch { presentNotice(title: "Unable to Delete", message: error.readableMessage) }
        }
    }

    private func copy(_ file: ProjectFile, moving: Bool) {
        clipboard = (file, moving)
    }

    private func paste(into directory: String) {
        guard let clipboard, let files else { return }
        // A folder cannot go inside itself: the move would delete its own
        // new home as it went.
        guard !(clipboard.file.isDirectory && directory.hasPrefix(clipboard.file.relativePath)) else {
            presentNotice(
                title: "Unable to Paste",
                message: String(localized: "A folder cannot be put inside itself."),
            )
            return
        }
        do {
            if directory.isEmpty || files.isExpanded(directory) == false { files.toggle(directory) }
            try files.transfer(clipboard.file, into: directory, moving: clipboard.moving)
            self.clipboard = clipboard.moving ? nil : clipboard
            rebuild()
        } catch { presentNotice(title: "Unable to Paste", message: error.readableMessage) }
    }

    private func askName(
        title: String.LocalizationValue,
        in directory: String,
        current: String = "",
        onConfirm: @escaping (String) -> Void,
    ) {
        present(AlertInputViewController(
            title: title,
            message: "",
            placeholder: "Name",
            text: current,
            doneButtonText: "Done",
        ) { [weak self] name in
            guard let self else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = files?.check(name: trimmed, in: directory) {
                presentNotice(title: "Unable to Use That Name", message: problem.message)
                return
            }
            onConfirm(trimmed)
        }, animated: true)
    }
}

extension SidebarFilesController: UITableViewDelegate {
    func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let path = dataSource.itemIdentifier(for: indexPath), let file = rows.first(where: { $0.relativePath == path })
        else { return }
        if file.isDirectory {
            toggle(file)
        } else {
            open(file)
        }
    }

    /// Long press: everything that changes the folder, beside the row it
    /// changes.
    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let path = dataSource.itemIdentifier(for: indexPath),
              let file = rows.first(where: { $0.relativePath == path })
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = []
            if file.isDirectory {
                actions.append(UIAction(title: String(localized: "New File"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
                    self?.createFile(in: file.relativePath)
                })
                actions.append(UIAction(title: String(localized: "New Folder"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                    self?.createFolder(in: file.relativePath)
                })
            }
            actions.append(UIAction(title: String(localized: "Rename…"), image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.rename(file)
            })
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(file, moving: false)
            })
            actions.append(UIAction(title: String(localized: "Cut"), image: UIImage(systemName: "scissors")) { [weak self] _ in
                self?.copy(file, moving: true)
            })
            if clipboard != nil, file.isDirectory {
                actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                    self?.paste(into: file.relativePath)
                })
            }
            actions.append(UIAction(
                title: String(localized: "Delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive,
            ) { [weak self] _ in
                self?.delete(file)
            })
            return UIMenu(children: actions)
        }
    }

    func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let path = dataSource.itemIdentifier(for: indexPath),
              let file = rows.first(where: { $0.relativePath == path })
        else { return UISwipeActionsConfiguration(actions: []) }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, completion in
            completion(false)
            self?.delete(file)
        }
        delete.image = UIImage(systemName: "trash.fill")
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

private extension ProjectFiles.NameProblem {
    var message: String.LocalizationValue {
        switch self {
        case .empty: "A name is needed."
        case .slash: "A name cannot hold a slash or a colon."
        case .reserved: "That name is not one a file can have."
        case .exists: "Something with that name is already here."
        }
    }
}

/// One row of the file list: the icon, the name indented by how deep it
/// sits, and — for a folder — whether it is open.
final class SidebarFileCell: UITableViewCell {
    private let icon = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.setContentHuggingPriority(.required, for: .horizontal)
    }

    private let name = UILabel().then {
        $0.font = UIFont.preferredFont(forTextStyle: .subheadline)
        $0.adjustsFontForContentSizeCategory = true
        $0.lineBreakMode = .byTruncatingMiddle
    }

    private let chevron = UIImageView(image: UIImage(systemName: "chevron.forward")).then {
        $0.tintColor = .tertiaryLabel
        $0.contentMode = .scaleAspectFit
        $0.setContentHuggingPriority(.required, for: .horizontal)
    }

    private var nameLeading: Constraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .default
        contentView.addSubview(chevron)
        contentView.addSubview(icon)
        contentView.addSubview(name)

        icon.snp.makeConstraints { x in
            x.leading.equalToSuperview().offset(16)
            x.centerY.equalToSuperview()
            x.size.equalTo(18)
        }
        // The name is bound top and bottom, not just centred: a label with
        // only a centre is a label of no height, and every row collapses to
        // the icon's.
        name.snp.makeConstraints { x in
            nameLeading = x.leading.equalTo(icon.snp.trailing).offset(8).constraint
            x.top.equalToSuperview().offset(10)
            x.bottom.equalToSuperview().offset(-10)
            x.trailing.lessThanOrEqualTo(chevron.snp.leading).offset(-8)
        }
        chevron.snp.makeConstraints { x in
            x.trailing.equalToSuperview().offset(-16)
            x.centerY.equalToSuperview()
            x.size.equalTo(12)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(file: ProjectFile?, depth: Int, expanded: Bool) {
        guard let file else {
            name.text = nil
            isAccessibilityElement = false
            return
        }
        name.text = file.name
        icon.image = UIImage(systemName: file.isDirectory
            ? (expanded ? "folder.fill" : "folder")
            : "doc.text")
        icon.tintColor = file.isDirectory ? .secondaryLabel : .tertiaryLabel
        icon.isHidden = false
        chevron.isHidden = !file.isDirectory
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        nameLeading?.update(offset: 8 + CGFloat(depth) * 14)
        isAccessibilityElement = true
        accessibilityLabel = file.name
        accessibilityValue = file.isDirectory
            ? String(localized: expanded ? "Folder, open" : "Folder, closed")
            : nil
        accessibilityTraits = file.isDirectory ? .button : []
    }
}
