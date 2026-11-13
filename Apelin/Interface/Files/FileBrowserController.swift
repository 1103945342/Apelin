import AlertController
import ApelinCore
import QuickLook
import SnapKit
import SPIndicator
import Then
import UIKit

/// A folder on this device, a directory at a time: the page Fila used to be
/// opened for, inside the app.
///
/// It starts where the caller points it and walks anywhere mobile may read —
/// up to the top of the file system, across to the bootstrap, and back to the
/// project it was opened from. Ordinary files are made, renamed, copied,
/// moved, edited, previewed, shared and deleted here; Apelin's own records —
/// its projects, SDKs, toolchains and the rest — are read here and changed on
/// the page that manages them, which the list says in place of the actions.
///
/// The reader's place is a value on this page. Nothing in here is remembered
/// between openings, and nothing is written anywhere but the file the reader
/// asked for: browsing never moves the conversation's project or the agent's
/// root.
final class FileBrowserController: UIViewController {
    // MARK: - What it was opened on

    /// The place the caller named, and why it could not be opened — shown once
    /// when it could not be, never an empty folder standing in for it.
    private let startFailure: FileBrowserFailure?
    private let projectRoot: URL?
    private let policy: FileBrowserPolicy
    private let places: [FileBrowserPlace]

    // MARK: - State

    private var navigation: FileBrowserNavigation?
    private var rows: [FileBrowserEntry] = []
    /// What each row takes, asked once per listing: a row offers the actions it
    /// can actually finish.
    private var accessByPath: [String: FileBrowserAccess] = [:]
    private var failure: FileBrowserFailure?
    private var isLoading = false
    private var listing: Task<Void, Never>?
    /// What Copy or Cut put aside: the entry as it sits, and whether Paste
    /// moves it.
    private var clipboard: (url: URL, moving: Bool)?
    private var didShowStartFailure = false

    // MARK: - Views

    private lazy var pathButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.titleLineBreakMode = .byTruncatingMiddle
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "Path")
        return button
    }()

    private lazy var upButton = UIButton(type: .system).then {
        $0.setImage(UIImage(systemName: "arrow.up"), for: .normal)
        $0.accessibilityLabel = String(localized: "Enclosing Folder")
    }

    /// The line under the path while this folder is not one the app changes:
    /// a record's own page, or a read-only place, said in words rather than
    /// left to a refusal after the fact.
    private let statusLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .footnote)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 0
        $0.isHidden = true
    }

    private lazy var pathRow = UIStackView(arrangedSubviews: [pathButton, upButton]).then {
        $0.axis = .horizontal
        $0.alignment = .center
        $0.spacing = 8
    }

    private lazy var header = UIStackView(arrangedSubviews: [pathRow, statusLabel]).then {
        $0.axis = .vertical
        $0.alignment = .fill
        $0.spacing = 2
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped).then {
        $0.backgroundColor = .clear
        $0.rowHeight = UITableView.automaticDimension
        $0.estimatedRowHeight = 44
        $0.register(UITableViewCell.self, forCellReuseIdentifier: "entry")
    }

    private lazy var locationsItem = UIBarButtonItem(
        title: String(localized: "Locations"),
        menu: placesMenu()
    )

    private lazy var moreItem = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis"),
        primaryAction: nil,
        menu: UIMenu(children: [])
    ).then {
        $0.accessibilityLabel = String(localized: "More")
    }

    // MARK: - Opening

    init(directory: URL, projectRoot: URL? = nil) {
        let dataFolder = DataFolder.app.root
        policy = FileBrowserPolicy(
            dataFolder: dataFolder,
            bootstrapRoot: FileBrowserLocations.bootstrapRoot(bundlePath: Bundle.main.bundlePath)
        )
        let project = projectRoot.flatMap {
            URL(fileURLWithPath: CanonicalPath.resolve($0.path) ?? $0.path, isDirectory: true)
        }
        self.projectRoot = project
        places = FileBrowserLocations.all(
            projectRoot: project,
            dataFolder: dataFolder,
            bundlePath: Bundle.main.bundlePath
        )
        let opened = FileBrowserLocation(url: directory)
        startFailure = opened == nil ? FileBrowserListing.openReason(for: directory) : nil
        navigation = opened.map(FileBrowserNavigation.init(directory:))
            ?? project.flatMap(FileBrowserLocation.init(url:)).map(FileBrowserNavigation.init(directory:))
            ?? FileBrowserLocation(path: "/").map(FileBrowserNavigation.init(directory:))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(directory:projectRoot:)")
    }

    deinit {
        listing?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItems = [moreItem, locationsItem]

        view.addSubview(header)
        view.addSubview(tableView)
        header.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(4)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(16)
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(header.snp.bottom).offset(4)
            make.leading.trailing.bottom.equalToSuperview()
        }
        tableView.dataSource = self
        tableView.delegate = self
        upButton.addAction(UIAction { [weak self] _ in self?.goUp() }, for: .touchUpInside)
        rebuild()
        load()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didShowStartFailure, let startFailure else { return }
        didShowStartFailure = true
        presentNotice(
            title: "Unable to Open Folder",
            message: startFailure.errorDescription ?? String(localized: "The folder could not be read.")
        )
    }

    // MARK: - Reading the place

    private func load() {
        guard let current = navigation?.current else { return }
        listing?.cancel()
        isLoading = true
        failure = nil
        rebuild()
        let url = current.url
        listing = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                FileBrowserListing.list(url)
            }.value
            guard let self, !Task.isCancelled else { return }
            isLoading = false
            switch result {
            case let .success(entries):
                rows = entries
                accessByPath = Dictionary(
                    entries.map { ($0.url.path, policy.access(to: $0.url)) },
                    uniquingKeysWith: { first, _ in first }
                )
            case let .failure(reason):
                rows = []
                accessByPath = [:]
                failure = reason
            }
            rebuild()
        }
    }

    private func rebuild() {
        let current = navigation?.current
        title = current?.title ?? String(localized: "Files")
        pathButton.configuration?.title = current?.path
        pathButton.accessibilityValue = current?.path
        pathButton.isEnabled = navigation != nil
        pathButton.menu = pathMenu()
        upButton.isEnabled = navigation?.parent != nil
        updateStatus()
        updateMoreMenu()
        applyRows()
    }

    private func updateStatus() {
        guard let current = navigation?.current else {
            statusLabel.isHidden = true
            return
        }
        let note = policy.access(toCreateIn: current.url).refusal
        statusLabel.text = note
        statusLabel.isHidden = note == nil
    }

    private func applyRows() {
        tableView.reloadData()
        if isLoading {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            tableView.backgroundView = spinner
        } else if let failure {
            tableView.backgroundView = EmptyStateView(
                symbolName: failure == .brokenLink ? "link" : "exclamationmark.triangle",
                text: failure.errorDescription ?? String(localized: "The folder could not be read.")
            )
        } else if rows.isEmpty {
            tableView.backgroundView = EmptyStateView(symbolName: "folder", text: String(localized: "This folder is empty."))
        } else {
            tableView.backgroundView = nil
        }
    }

    // MARK: - Moving

    private func go(to location: FileBrowserLocation) {
        navigation?.go(to: location)
        load()
    }

    private func goUp() {
        guard var navigation, navigation.goUp() else { return }
        self.navigation = navigation
        load()
    }

    private func goBack() {
        guard var navigation, navigation.goBack() else { return }
        self.navigation = navigation
        load()
    }

    private func enter(_ entry: FileBrowserEntry) {
        guard let location = FileBrowserLocation(url: entry.url) else {
            presentNotice(
                title: "Unable to Open Folder",
                message: FileBrowserListing.openReason(for: entry.url).errorDescription ?? ""
            )
            return
        }
        go(to: location)
    }

    // MARK: - Menus

    private func pathMenu() -> UIMenu {
        guard let current = navigation?.current else { return UIMenu(children: []) }
        let trail = current.ancestors.reversed()
        return UIMenu(children: trail.map { location in
            let name = location.path == "/" ? String(localized: "This Device") : location.title
            return UIAction(title: name, state: location == current ? .on : .off) { [weak self] _ in
                self?.go(to: location)
            }
        })
    }

    private func placesMenu() -> UIMenu {
        UIMenu(children: places.map { place in
            UIAction(title: label(for: place.name), image: UIImage(systemName: symbol(for: place.name))) { [weak self] _ in
                self?.go(to: place.location)
            }
        })
    }

    private func updateMoreMenu() {
        guard let current = navigation?.current else {
            moreItem.menu = UIMenu(children: [])
            return
        }
        var actions: [UIMenuElement] = []
        if navigation?.canGoBack == true {
            actions.append(UIAction(
                title: String(localized: "Back"),
                image: UIImage(systemName: "chevron.backward")
            ) { [weak self] _ in self?.goBack() })
        }
        let creating = policy.access(toCreateIn: current.url)
        if creating.isWritable {
            actions.append(UIAction(
                title: String(localized: "New File"),
                image: UIImage(systemName: "doc.badge.plus")
            ) { [weak self] _ in self?.createFile(in: current.url) })
            actions.append(UIAction(
                title: String(localized: "New Folder"),
                image: UIImage(systemName: "folder.badge.plus")
            ) { [weak self] _ in self?.createFolder(in: current.url) })
            if clipboard != nil {
                actions.append(UIAction(
                    title: String(localized: "Paste"),
                    image: UIImage(systemName: "doc.on.clipboard")
                ) { [weak self] _ in self?.paste(into: current.url) })
            }
        }
        // Leaving this folder is reading, which every place allows.
        actions.append(UIMenu(options: .displayInline, children: [
            UIAction(
                title: String(localized: "Open in Terminal"),
                image: UIImage(systemName: "terminal")
            ) { [weak self] _ in self?.openTerminal(at: current.url) },
            UIAction(
                title: String(localized: "Reload"),
                image: UIImage(systemName: "arrow.clockwise")
            ) { [weak self] _ in self?.load() }
        ]))
        moreItem.menu = UIMenu(children: actions)
    }

    private func menu(for entry: FileBrowserEntry) -> UIMenu {
        let access = accessByPath[entry.url.path] ?? policy.access(to: entry.url)
        let creating = policy.access(toCreateIn: entry.url)
        var actions: [UIMenuElement] = []
        actions.append(UIAction(
            title: String(localized: "Open"),
            image: UIImage(systemName: entry.opensAsDirectory ? "folder" : "doc.text")
        ) { [weak self] _ in self?.act(on: entry) })
        if entry.opensAsDirectory {
            actions.append(UIAction(
                title: String(localized: "Open in Terminal"),
                image: UIImage(systemName: "terminal")
            ) { [weak self] _ in self?.openTerminal(at: entry.url) })
        }
        if creating.isWritable, entry.opensAsDirectory {
            actions.append(UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "New File"),
                    image: UIImage(systemName: "doc.badge.plus")
                ) { [weak self] _ in self?.createFile(in: entry.url) },
                UIAction(
                    title: String(localized: "New Folder"),
                    image: UIImage(systemName: "folder.badge.plus")
                ) { [weak self] _ in self?.createFolder(in: entry.url) }
            ]))
        }
        if access.isWritable {
            actions.append(UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Rename…"),
                    image: UIImage(systemName: "pencil")
                ) { [weak self] _ in self?.rename(entry) },
                UIAction(
                    title: String(localized: "Copy"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { [weak self] _ in self?.copy(entry, moving: false) },
                UIAction(
                    title: String(localized: "Cut"),
                    image: UIImage(systemName: "scissors")
                ) { [weak self] _ in self?.copy(entry, moving: true) }
            ]))
            if entry.opensAsDirectory, clipboard != nil, creating.isWritable {
                actions.append(UIAction(
                    title: String(localized: "Paste"),
                    image: UIImage(systemName: "doc.on.clipboard")
                ) { [weak self] _ in self?.paste(into: entry.url) })
            }
        }
        // Sharing only reads, so a record can be handed on as it is.
        actions.append(UIMenu(options: .displayInline, children: [
            UIAction(
                title: String(localized: "Share…"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.share(entry) }
        ]))
        if access.isWritable {
            actions.append(UIAction(
                title: String(localized: "Delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in self?.confirmDelete(entry) })
        }
        return UIMenu(children: actions)
    }

    // MARK: - Reading a file

    private func act(on entry: FileBrowserEntry) {
        if entry.opensAsDirectory {
            enter(entry)
        } else {
            open(entry)
        }
    }

    private func open(_ entry: FileBrowserEntry) {
        if case let .link(target) = entry.kind, target == nil {
            presentNotice(
                title: "Unable to Open File",
                message: FileBrowserListing.openReason(for: entry.url).errorDescription ?? ""
            )
            return
        }
        let url = entry.url
        let name = entry.name
        // Read first to tell text by its contents rather than by its
        // extension: source files without a registered UTI still use the
        // editor, while images, audio and documents go to Quick Look.
        Task { [weak self] in
            let isText = (try? await Task.detached(priority: .userInitiated) {
                try ProjectFileContent.read(at: url)
            }.value) != nil
            guard let self else { return }
            guard isText else {
                guard QLPreviewController.canPreview(url as NSURL) else {
                    presentNotice(
                        title: "Unable to Open File",
                        message: FileBrowserListing.openReason(for: url).errorDescription ?? ""
                    )
                    return
                }
                present(ProjectFilePreviewController(url: url), animated: true)
                return
            }
            guard let editor = await FileEditorController.prepare(url: url, relativePath: name, line: nil) else {
                presentNotice(title: "Unable to Open File", message: String(localized: "The file could not be read."))
                return
            }
            // Asked before the pencil and again before a save: a file in a
            // record is shown, and not written, wherever the link led. The
            // guard holds the policy and the file as they were, not this page,
            // so closing the browser does not open the file for writing.
            let writeGuard = FileBrowserWriteGuard(url: url, policy: policy)
            editor.writeRefusal = { writeGuard.refusal() }
            // Asked again inside the editor's write, next to the file.
            editor.writeGuard = { writeGuard.refusal() }
            editor.onSaved = { [weak self] in
                writeGuard.didSave()
                self?.load()
            }
            presentPageAsFormSheet(editor)
        }
    }

    private func openTerminal(at directory: URL) {
        let url = FileBrowserLocation(url: directory)?.url ?? directory
        TerminalPresenter.open(directory: url, projectRoot: projectRoot, from: self)
    }

    // MARK: - Changing the folder

    private func createFile(in directory: URL) {
        askName(title: "New File", in: directory) { [weak self] name in
            guard let self else { return }
            do {
                try FileBrowserOperations.createFile(named: name, in: directory, policy: policy)
                load()
            } catch {
                presentNotice(title: "Unable to Create File", message: error.readableMessage)
            }
        }
    }

    private func createFolder(in directory: URL) {
        askName(title: "New Folder", in: directory) { [weak self] name in
            guard let self else { return }
            do {
                try FileBrowserOperations.createFolder(named: name, in: directory, policy: policy)
                load()
            } catch {
                presentNotice(title: "Unable to Create Folder", message: error.readableMessage)
            }
        }
    }

    private func rename(_ entry: FileBrowserEntry) {
        let holder = entry.url.deletingLastPathComponent()
        askName(title: "Rename", in: holder, current: entry.name) { [weak self] name in
            guard let self else { return }
            do {
                try FileBrowserOperations.rename(entry.url, to: name, policy: policy)
                load()
            } catch {
                presentNotice(title: "Unable to Rename", message: error.readableMessage)
            }
        }
    }

    private func copy(_ entry: FileBrowserEntry, moving: Bool) {
        clipboard = (entry.url, moving)
        updateMoreMenu()
        SPIndicator.present(
            title: String(localized: moving ? "Cut" : "Copied"),
            preset: .done,
            haptic: .success
        )
    }

    private func paste(into directory: URL) {
        guard let clipboard else { return }
        do {
            if clipboard.moving {
                try FileBrowserOperations.move(clipboard.url, into: directory, policy: policy)
                self.clipboard = nil
            } else {
                try FileBrowserOperations.copy(clipboard.url, into: directory, policy: policy)
            }
            SPIndicator.present(title: String(localized: "Pasted"), preset: .done, haptic: .success)
            load()
        } catch {
            presentNotice(title: "Unable to Paste", message: error.readableMessage)
        }
    }

    private func confirmDelete(_ entry: FileBrowserEntry) {
        presentConfirmation(
            title: "Delete “\(entry.name)”?",
            message: entry.opensAsDirectory
                ? "The folder and everything in it will be deleted. This cannot be undone."
                : "This file will be deleted. This cannot be undone.",
            confirmTitle: "Delete",
            destructive: true
        ) { [weak self] in
            guard let self else { return }
            do {
                try FileBrowserOperations.remove(entry.url, policy: policy)
                if clipboard?.url == entry.url { clipboard = nil }
                load()
            } catch {
                presentNotice(title: "Unable to Delete", message: error.readableMessage)
            }
        }
    }

    private func share(_ entry: FileBrowserEntry) {
        let controller = UIActivityViewController(activityItems: [entry.url], applicationActivities: nil)
        // A popover on iPad has to point at something, or presenting throws.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = CGRect(
                x: tableView.bounds.midX,
                y: tableView.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        present(controller, animated: true)
    }

    private func askName(
        title: String.LocalizationValue,
        in directory: URL,
        current: String = "",
        onConfirm: @escaping (String) -> Void
    ) {
        present(AlertInputViewController(
            title: title,
            message: "",
            placeholder: "Name",
            text: current,
            doneButtonText: "Done"
        ) { [weak self] name in
            guard let self else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = FileBrowserOperations.check(name: trimmed, in: directory, policy: policy) {
                presentNotice(
                    title: "Unable to Use That Name",
                    message: problem.errorDescription ?? String(localized: "That name cannot be used here.")
                )
                return
            }
            onConfirm(trimmed)
        }, animated: true)
    }

    // MARK: - Words

    private func label(for name: FileBrowserPlace.Name) -> String {
        switch name {
        case let .project(project): project
        case .dataFolder: String(localized: "App Data")
        case .projects: String(localized: "Projects")
        case .home: String(localized: "Mobile Home")
        case .documents: String(localized: "Documents")
        case .bootstrap: String(localized: "Jailbreak Root")
        case .device: String(localized: "This Device")
        }
    }

    private func symbol(for name: FileBrowserPlace.Name) -> String {
        switch name {
        case .project(_): "shippingbox"
        case .dataFolder: "internaldrive"
        case .projects: "folder"
        case .home: "house"
        case .documents: "folder"
        case .bootstrap: "wrench.and.screwdriver"
        case .device: "iphone"
        }
    }
}

// MARK: - The list

extension FileBrowserController: UITableViewDataSource {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        guard rows.indices.contains(indexPath.row) else { return cell }
        let entry = rows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = entry.name
        content.secondaryText = subtitle(for: entry)
        content.image = UIImage(systemName: symbol(for: entry))
        content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        content.imageProperties.tintColor = entry.opensAsDirectory ? .label : .secondaryLabel
        cell.contentConfiguration = content
        // A folder opens; a file is handed to the editor or to Quick Look.
        cell.accessoryType = entry.opensAsDirectory ? .disclosureIndicator : .none
        return cell
    }

    private func symbol(for entry: FileBrowserEntry) -> String {
        switch entry.kind {
        case .directory: "folder"
        case .file: "doc.text"
        case .link(_): "link"
        }
    }

    /// The line under the name: where a link leads, that a record is changed
    /// elsewhere, and how large a file is. A folder that is none of those says
    /// nothing more.
    private func subtitle(for entry: FileBrowserEntry) -> String? {
        if case .record = accessByPath[entry.url.path] ?? policy.access(to: entry.url) {
            return String(localized: "Managed elsewhere")
        }
        switch entry.kind {
        case let .link(target):
            return target ?? String(localized: "Leads nowhere")
        case .directory:
            return nil
        case .file:
            guard let byteCount = entry.byteCount else { return nil }
            return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        }
    }
}

// MARK: - Acting on a row

extension FileBrowserController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row) else { return }
        act(on: rows[indexPath.row])
    }

    /// Long press: everything this entry can be given, beside the row it
    /// changes. A record is short of actions, and says why in its own line.
    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard rows.indices.contains(indexPath.row) else { return nil }
        let entry = rows[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: entry)
        }
    }

    /// Swipe is the one destructive shortcut, and only where a change is
    /// allowed at all.
    func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard rows.indices.contains(indexPath.row) else { return UISwipeActionsConfiguration(actions: []) }
        let entry = rows[indexPath.row]
        let access = accessByPath[entry.url.path] ?? policy.access(to: entry.url)
        guard access.isWritable else { return UISwipeActionsConfiguration(actions: []) }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete")
        ) { [weak self] _, _, completion in
            completion(false)
            self?.confirmDelete(entry)
        }
        delete.image = UIImage(systemName: "trash.fill")
        return UISwipeActionsConfiguration(actions: [delete])
    }
}
