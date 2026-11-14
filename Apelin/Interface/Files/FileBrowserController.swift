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
    /// Which read of a folder the page is waiting on: a read that finished
    /// after another folder was asked for leaves what is on screen alone.
    @objc dynamic private var listingGeneration = 0
    /// The folder `rows` were read from. Moving to another one clears them
    /// before the read starts, so the old folder's rows are never tappable
    /// under the new path.
    @objc dynamic private var listedPath: String?
    /// What Copy or Cut put aside: the entry as it sits, and whether Paste
    /// moves it.
    private var clipboard: (url: URL, moving: Bool)?
    private var didShowStartFailure = false
    /// The trail the path area was last drawn as, so a reload of the same
    /// folder redraws nothing and keeps the reader's sideways position.
    private var shownBreadcrumb: FileBrowserBreadcrumb?
    @objc dynamic private var currentCrumbButton: UIButton?
    @objc dynamic private var breadcrumbWidthConstraints: [NSLayoutConstraint] = []
    /// The width the crumb limits were worked out for, 0 before the first
    /// layout.
    @objc dynamic private var crumbWidthLimit: CGFloat = 0
    private var breadcrumbReveal = FileBrowserBreadcrumbReveal()
    @objc dynamic private var needsBreadcrumbReveal = false

    // MARK: - Views

    /// The path under the bar: one button per folder, from the root down to
    /// the one on screen, scrolled sideways instead of squeezed. Nothing here
    /// is remembered between openings; it is drawn from the place the page is
    /// standing on.
    private let breadcrumbScroll = UIScrollView().then {
        $0.showsHorizontalScrollIndicator = false
        $0.contentInsetAdjustmentBehavior = .never
        $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private let breadcrumbStack = UIStackView().then {
        $0.axis = .horizontal
        $0.alignment = .center
        $0.spacing = 2
        $0.translatesAutoresizingMaskIntoConstraints = false
    }

    private lazy var upButton = UIButton(type: .system).then {
        $0.setImage(UIImage(systemName: "arrow.up"), for: .normal)
        $0.accessibilityLabel = String(localized: "Enclosing Folder")
        $0.setContentHuggingPriority(.required, for: .horizontal)
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
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

    private lazy var pathRow = UIStackView(arrangedSubviews: [breadcrumbScroll, upButton]).then {
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
        breadcrumbScroll.addSubview(breadcrumbStack)
        header.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(4)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(16)
        }
        // The path area takes the width Up leaves and scrolls sideways rather
        // than squeezing names out of sight; its height is its tallest crumb's,
        // so a larger text size grows it instead of being clipped.
        breadcrumbScroll.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(FileBrowserBreadcrumbLayout.minimumTarget)
        }
        NSLayoutConstraint.activate([
            breadcrumbStack.leadingAnchor.constraint(equalTo: breadcrumbScroll.contentLayoutGuide.leadingAnchor),
            breadcrumbStack.trailingAnchor.constraint(equalTo: breadcrumbScroll.contentLayoutGuide.trailingAnchor),
            breadcrumbStack.topAnchor.constraint(equalTo: breadcrumbScroll.contentLayoutGuide.topAnchor),
            breadcrumbStack.bottomAnchor.constraint(equalTo: breadcrumbScroll.contentLayoutGuide.bottomAnchor),
            breadcrumbStack.heightAnchor.constraint(equalTo: breadcrumbScroll.frameLayoutGuide.heightAnchor),
        ])
        tableView.snp.makeConstraints { make in
            make.top.equalTo(header.snp.bottom).offset(4)
            make.leading.trailing.bottom.equalToSuperview()
        }
        upButton.snp.makeConstraints { make in
            make.width.height.greaterThanOrEqualTo(FileBrowserBreadcrumbLayout.minimumTarget)
        }
        tableView.dataSource = self
        tableView.delegate = self
        upButton.addAction(UIAction { [weak self] _ in self?.goUp() }, for: .touchUpInside)
        rebuild()
        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A changed width re-caps the names first; the crumbs are laid out at
        // the new widths before the trail moves to the folder on screen.
        guard !updateBreadcrumbWidthLimit() else { return }
        revealCurrentCrumb()
    }

    /// A new text size redraws the names at that size, and a new writing
    /// direction mirrors them; neither is a reason to reload the folder.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.preferredContentSizeCategory != previous?.preferredContentSizeCategory
            || traitCollection.layoutDirection != previous?.layoutDirection
        else { return }
        redrawBreadcrumb()
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
        listingGeneration &+= 1
        let generation = listingGeneration
        let url = current.url
        // Another folder: the rows on screen belong to the folder the page
        // left, and must not be tappable while the new one is read.
        if listedPath != url.path {
            rows = []
            accessByPath = [:]
        }
        isLoading = true
        failure = nil
        rebuild()
        listing = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                FileBrowserListing.list(url)
            }.value
            guard let self, !Task.isCancelled else { return }
            guard generation == listingGeneration else { return }
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
            listedPath = url.path
            rebuild()
        }
    }

    private func rebuild() {
        let current = navigation?.current
        title = current?.title ?? String(localized: "Files")
        rebuildBreadcrumb()
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

    // MARK: - The path area

    /// Draws the trail under the bar from the folder the page is standing on.
    ///
    /// The trail is only rebuilt when it leads somewhere else: a reload of the
    /// same folder — after a save, a paste, a refresh — keeps the crumbs the
    /// reader already has and their sideways position.
    @objc dynamic private func rebuildBreadcrumb() {
        guard let current = navigation?.current else {
            clearBreadcrumb()
            return
        }
        let trail = FileBrowserBreadcrumb(
            location: current,
            rootTitle: String(localized: "This Device")
        )
        if trail != shownBreadcrumb {
            populateBreadcrumb(trail)
        }
        if breadcrumbReveal.shouldReveal(current.path) {
            needsBreadcrumbReveal = true
            view.setNeedsLayout()
        }
    }

    @objc dynamic private func clearBreadcrumb() {
        shownBreadcrumb = nil
        currentCrumbButton = nil
        breadcrumbWidthConstraints = []
        crumbWidthLimit = 0
        needsBreadcrumbReveal = false
        for view in breadcrumbStack.arrangedSubviews {
            breadcrumbStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// The trail's own order, root first, drawn in the interface's reading
    /// direction by the stack itself: an Arabic or Hebrew page reads it from
    /// the right, and the file system's order is unchanged.
    private func populateBreadcrumb(_ trail: FileBrowserBreadcrumb) {
        clearBreadcrumb()
        shownBreadcrumb = trail
        crumbWidthLimit = breadcrumbScroll.bounds.width
        let limit = FileBrowserBreadcrumbLayout.titleWidthLimit(available: crumbWidthLimit)
        for (index, segment) in trail.segments.enumerated() {
            if index > 0 {
                breadcrumbStack.addArrangedSubview(separator())
            }
            let button = crumbButton(for: segment)
            breadcrumbStack.addArrangedSubview(button)
            let width = button.widthAnchor.constraint(lessThanOrEqualToConstant: limit)
            width.isActive = true
            breadcrumbWidthConstraints.append(width)
            if segment.isCurrent {
                currentCrumbButton = button
            }
        }
    }

    /// One folder on the way here. A tap goes there, which is why the current
    /// crumb's tap is no move at all; a long press copies that folder's path,
    /// and on the current crumb also lists the folders above it.
    private func crumbButton(for segment: FileBrowserBreadcrumb.Segment) -> UIButton {
        let style: UIFont.TextStyle = segment.isCurrent ? .headline : .subheadline
        var configuration = UIButton.Configuration.plain()
        configuration.title = segment.title
        configuration.titleLineBreakMode = .byTruncatingMiddle
        configuration.baseForegroundColor = segment.isCurrent ? .label : .link
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: style)
            return outgoing
        }
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        // The width limit and the touch target are required; the title is what
        // gives way, so a long name truncates instead of fighting the cap.
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.heightAnchor.constraint(
            greaterThanOrEqualToConstant: FileBrowserBreadcrumbLayout.minimumTarget
        ).isActive = true
        button.widthAnchor.constraint(
            greaterThanOrEqualToConstant: FileBrowserBreadcrumbLayout.minimumTarget
        ).isActive = true
        // The title drawn may be shortened to fit; what VoiceOver reads is the
        // whole name, the path it leads to, and whether this is the folder on
        // screen.
        button.accessibilityLabel = segment.title
        button.accessibilityValue = segment.location.path
        if segment.isCurrent {
            button.accessibilityTraits.insert(.selected)
        }
        button.addAction(UIAction { [weak self] _ in
            self?.openCrumb(segment.location)
        }, for: .touchUpInside)
        button.menu = crumbMenu(for: segment)
        button.showsMenuAsPrimaryAction = false
        return button
    }

    /// What sits between two crumbs: a chevron that mirrors with the language,
    /// and nothing for VoiceOver to stop on.
    @objc dynamic private func separator() -> UIImageView {
        let view = UIImageView(
            image: UIImage(systemName: "chevron.forward")?.imageFlippedForRightToLeftLayoutDirection()
        )
        view.tintColor = .tertiaryLabel
        view.contentMode = .scaleAspectFit
        view.isAccessibilityElement = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }

    private func crumbMenu(for segment: FileBrowserBreadcrumb.Segment) -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Copy Path"),
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in self?.copyPath(segment.location.path) }
        ]
        // The list the path used to drop down, kept beside the crumbs that
        // took its place, for the folder on screen — named as the path area
        // named it before.
        if segment.isCurrent, let ancestors = shownBreadcrumb?.ancestors, !ancestors.isEmpty {
            children.append(UIMenu(
                title: String(localized: "Path"),
                options: .displayInline,
                children: ancestors.reversed().map { ancestor in
                    UIAction(title: ancestor.title) { [weak self] _ in
                        self?.openCrumb(ancestor.location)
                    }
                }
            ))
        }
        return UIMenu(children: children)
    }

    /// A crumb is a folder, not a promise: the path is resolved again and
    /// checked to still be a directory before the page moves, so a name that
    /// has become a file is not opened as one and a folder that is gone is
    /// said so. The page stays where it is rather than quietly landing
    /// somewhere else.
    private func openCrumb(_ location: FileBrowserLocation) {
        guard location != navigation?.current else { return }
        var isDirectory: ObjCBool = false
        guard let target = FileBrowserLocation(path: location.path),
              FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            presentNotice(
                title: "Unable to Open Folder",
                message: FileBrowserListing.openReason(for: location.url).errorDescription
                    ?? String(localized: "The folder could not be read.")
            )
            load()
            return
        }
        go(to: target)
    }

    /// The widest a crumb is drawn is a share of the path area, so a deep path
    /// on a narrow screen still shows the folders around the one on screen.
    /// Answers whether the width changed, in which case the crumbs are laid
    /// out again before the trail is moved.
    @discardableResult
    @objc dynamic private func updateBreadcrumbWidthLimit() -> Bool {
        let available = breadcrumbScroll.bounds.width
        guard available > 0, abs(available - crumbWidthLimit) > 0.5 else { return false }
        crumbWidthLimit = available
        let limit = FileBrowserBreadcrumbLayout.titleWidthLimit(available: available)
        breadcrumbWidthConstraints.forEach { $0.constant = limit }
        // A resized page is not a reload: what it shows is still worth
        // bringing into view.
        needsBreadcrumbReveal = true
        view.setNeedsLayout()
        return true
    }

    /// Moves the trail sideways to the folder on screen, once per folder it
    /// comes to show. A reload of that folder never moves it.
    @objc dynamic private func revealCurrentCrumb() {
        guard needsBreadcrumbReveal else { return }
        needsBreadcrumbReveal = false
        guard let crumb = currentCrumbButton,
              breadcrumbScroll.contentSize.width > breadcrumbScroll.bounds.width
        else { return }
        breadcrumbStack.layoutIfNeeded()
        let rect = crumb.convert(crumb.bounds, to: breadcrumbScroll).insetBy(dx: -8, dy: 0)
        breadcrumbScroll.scrollRectToVisible(rect, animated: false)
    }

    /// The path, ready to paste. Named for the copy family in Swift, so its
    /// selector is given a name of its own rather than read by ARC as one that
    /// returns a retained object.
    @objc(apelin_copyPath) private dynamic func copyPath(_ path: String) {
        UIPasteboard.general.string = path
        SPIndicator.present(title: String(localized: "Path copied"), preset: .done, haptic: .success)
    }

    /// The same trail at another text size or in another direction, without
    /// reading the folder again.
    @objc dynamic private func redrawBreadcrumb() {
        guard let trail = shownBreadcrumb else { return }
        populateBreadcrumb(trail)
        needsBreadcrumbReveal = true
        view.setNeedsLayout()
    }

    // MARK: - Moving

    private func go(to location: FileBrowserLocation) {
        // The folder the page is already on is no move, and no reload either.
        guard location != navigation?.current else { return }
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
        // Reading the folder's path is allowed everywhere, so it does not wait
        // for the place to be writable.
        actions.append(UIAction(
            title: String(localized: "Copy Path"),
            image: UIImage(systemName: "doc.on.doc")
        ) { [weak self] _ in self?.copyPath(current.path) })
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
