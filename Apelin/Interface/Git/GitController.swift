import ApelinCore
import SnapKit
import Then
import UIKit

/// What a Git page needs from the screen it sits in.
@MainActor
protocol GitPageHost: AnyObject {
    func gitShowToast(_ text: String)
    func gitSetBusy(_ busy: Bool)
    func gitReload()
    func gitOpenCredentials()
    /// Shows a diff as the system's sheet, over everything the page has up.
    func gitShowDiff(_ page: UIViewController)
}

/// What every page shares: the session and the screen it sits in.
@MainActor
protocol GitPage: AnyObject {
    func applySession()
    func pageDidAppear()
    func applyBottomInset()
}

/// The visual Git page, opened from the conversation's bar.
///
/// A port of the reference app's Git screen: a top bar naming the page and
/// the repository, a pager over three pages — status, branches, commits —
/// and the floating tab bar they share. The pages are the reference app's
/// pages, with its spacing, its words and its dialogs.
final class GitController: UIViewController {
    private let session: GitSession

    private let statusPage: GitStatusPage
    private let branchesPage: GitBranchesPage
    private let logPage: GitLogPage
    private lazy var pages: [UIViewController] = [statusPage, branchesPage, logPage]

    private var isLoading = false {
        didSet { applyState() }
    }

    private var isNotARepository = false {
        didSet { applyState() }
    }

    private var busy = false {
        didSet {
            refreshButton.isEnabled = !busy && !isLoading
            applyNotARepoBusy()
        }
    }

    private var currentTab = 0

    // MARK: - Views

    private let topBar = UIView()
    private let backButton = GitGlassButton.icon(
        GitIcon.Name.back, label: String(localized: "Back"),
    )
    private let titleLabel = UILabel().then {
        $0.text = String(localized: "Git")
        $0.font = GitTheme.titleLarge
        $0.textColor = GitTheme.onSurface
        $0.accessibilityTraits = .header
    }

    private let repoNameLabel = UILabel().then {
        $0.font = GitTheme.bodyMedium
        $0.textColor = GitTheme.onSurfaceVariant
        $0.lineBreakMode = .byTruncatingMiddle
        $0.numberOfLines = 1
    }

    private let repoChevron = UIImageView(image: GitIcon.image(
        GitIcon.Name.chevronDown, pointSize: 16,
    )).then {
        $0.tintColor = GitTheme.onSurfaceVariant
        $0.contentMode = .scaleAspectFit
    }

    private let repoButton = UIControl()

    private let titleStack = UIStackView().then {
        $0.axis = .vertical
        $0.alignment = .leading
        $0.spacing = 0
    }

    private let keyButton = GitGlassButton.icon(
        GitIcon.Name.key, label: String(localized: "Credentials & Identity"),
    )
    private let refreshButton = GitGlassButton.icon(
        GitIcon.Name.refresh, label: String(localized: "Refresh"),
    )

    private let scroll = UIScrollView().then {
        $0.isPagingEnabled = true
        $0.showsHorizontalScrollIndicator = false
        $0.showsVerticalScrollIndicator = false
        $0.contentInsetAdjustmentBehavior = .never
        $0.bounces = true
    }

    private let pagesStack = UIStackView().then {
        $0.axis = .horizontal
        $0.spacing = 0
        $0.alignment = .fill
        $0.distribution = .fillEqually
    }

    private let tabs = GitGlassTabs(titles: [
        String(localized: "Status"),
        String(localized: "Branches"),
        String(localized: "Commits"),
    ])

    private let spinner = UIActivityIndicatorView(style: .medium)
    private var stateView: UIView?
    private var notARepoButtons: [UIView] = []
    private var notARepoBusy: UIStackView?
    private var toast: UIView?
    private var toastWorkItem: DispatchWorkItem?

    init(projectName: String) {
        session = GitSession(projectName: projectName)
        statusPage = GitStatusPage(session: session)
        branchesPage = GitBranchesPage(session: session)
        logPage = GitLogPage(session: session)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = GitTheme.pageBackground
        navigationController?.setNavigationBarHidden(true, animated: false)

        statusPage.host = self
        branchesPage.host = self
        logPage.host = self
        tabs.onSelect = { [weak self] index in self?.selectTab(index, animated: true) }

        buildTopBar()
        for page in pages {
            addChild(page)
        }
        buildPager()

        scroll.delegate = self
        session.onChange = { [weak self] in
            guard let self else { return }
            self.refreshButton.isEnabled = !self.busy && !self.isLoading
            for page in self.pages {
                (page as? GitPage)?.applySession()
            }
        }

        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        spinner.snp.makeConstraints { make in make.center.equalTo(view.safeAreaLayoutGuide) }

        view.addSubview(tabs)
        tabs.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-8)
            make.width.equalTo(300)
            make.height.equalTo(46)
        }
        tabs.select(0)

        applyState()
        reloadAll()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        for page in pages {
            (page as? GitPage)?.applyBottomInset()
        }
    }

    // MARK: - Building

    private func buildTopBar() {
        topBar.backgroundColor = GitTheme.pageBackground
        view.addSubview(topBar)

        // The page is a screen of its own: its leading end goes back, and
        // all three of its buttons are the platform's glass.
        backButton.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        }, for: .touchUpInside)

        repoNameLabel.text = session.projectName
        repoButton.accessibilityLabel = String(localized: "Switch repository")
        repoButton.accessibilityTraits = .button
        repoButton.isAccessibilityElement = true
        repoButton.addSubview(repoNameLabel)
        repoButton.addSubview(repoChevron)
        repoNameLabel.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.trailing.equalTo(repoChevron.snp.leading).offset(-2)
        }
        repoChevron.snp.makeConstraints { make in
            make.trailing.centerY.equalToSuperview()
            make.size.equalTo(16)
        }
        repoButton.addAction(UIAction { [weak self] _ in
            self?.showRepoPicker()
        }, for: .touchUpInside)

        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(repoButton)
        titleStack.setCustomSpacing(2, after: titleLabel)

        keyButton.addAction(UIAction { [weak self] _ in
            self?.gitOpenCredentials()
        }, for: .touchUpInside)

        refreshButton.addAction(UIAction { [weak self] _ in
            self?.reloadAll()
        }, for: .touchUpInside)

        topBar.addSubview(backButton)
        topBar.addSubview(titleStack)
        topBar.addSubview(keyButton)
        topBar.addSubview(refreshButton)

        topBar.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalTo(view)
            make.height.equalTo(64)
        }
        backButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.centerY.equalToSuperview()
        }
        titleStack.snp.makeConstraints { make in
            make.leading.equalTo(backButton.snp.trailing).offset(4)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(keyButton.snp.leading).offset(-8)
        }
        refreshButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-8)
            make.centerY.equalToSuperview()
        }
        keyButton.snp.makeConstraints { make in
            make.trailing.equalTo(refreshButton.snp.leading).offset(-8)
            make.centerY.equalToSuperview()
        }
    }

    private func buildPager() {
        view.addSubview(scroll)
        scroll.addSubview(pagesStack)
        pagesStack.snp.makeConstraints { make in
            make.edges.equalTo(scroll.contentLayoutGuide)
            make.height.equalTo(scroll.frameLayoutGuide)
        }
        for page in pages {
            pagesStack.addArrangedSubview(page.view)
            page.view.snp.makeConstraints { make in
                make.width.equalTo(view)
            }
        }
        scroll.snp.makeConstraints { make in
            make.top.equalTo(topBar.snp.bottom)
            make.leading.trailing.equalTo(view)
            make.bottom.equalTo(view)
        }
    }

    // MARK: - State

    private func applyState() {
        spinner.isHidden = !isLoading
        if isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
        scroll.isHidden = isLoading || isNotARepository
        tabs.isHidden = isLoading || isNotARepository
        repoButton.isHidden = isNotARepository
        refreshButton.isEnabled = !busy && !isLoading
        refreshButton.alpha = busy || isLoading ? 0.45 : 1
        if isLoading {
            clearStateView()
            return
        }
        if isNotARepository {
            guard stateView == nil else { return }
            let state = makeNotARepoView()
            view.addSubview(state)
            state.snp.makeConstraints { make in
                make.top.equalTo(topBar.snp.bottom)
                make.leading.trailing.bottom.equalTo(self.view)
            }
            stateView = state
        } else {
            clearStateView()
        }
    }

    private func clearStateView() {
        stateView?.removeFromSuperview()
        stateView = nil
    }

    private func makeNotARepoView() -> UIView {
        let container = UIView()
        let title = UILabel().then {
            $0.text = String(localized: "This workspace is not a Git repository yet")
            $0.font = GitTheme.bodyMedium
            $0.textColor = GitTheme.onSurfaceVariant
            $0.textAlignment = .center
            $0.numberOfLines = 0
        }
        let first = UILabel().then {
            $0.text = String(localized: "Initialize a new repository here to start version control")
            $0.font = GitTheme.bodySmall
            $0.textColor = GitTheme.onSurfaceVariant
            $0.textAlignment = .center
            $0.numberOfLines = 0
        }
        let second = UILabel().then {
            $0.text = String(localized: "If a subdirectory already has a Git repository, you can select it instead")
            $0.font = GitTheme.bodySmall
            $0.textColor = GitTheme.onSurfaceVariant
            $0.textAlignment = .center
            $0.numberOfLines = 0
        }
        let initButton = GitButtons.tonal(
            title: String(localized: "Initialize New Repository"), symbol: GitIcon.Name.branch,
        )
        initButton.addAction(UIAction { [weak self] _ in self?.initialise() }, for: .touchUpInside)
        let cloneButton = GitButtons.tonal(
            title: String(localized: "Clone Remote Repository"), symbol: GitIcon.Name.download,
        )
        cloneButton.addAction(UIAction { [weak self] _ in self?.showCloneDialog() }, for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [initButton, cloneButton]).then {
            $0.axis = .horizontal
            $0.spacing = GitTheme.Space.md
            $0.distribution = .fillEqually
        }
        let pickButton = GitButtons.outlined(
            title: String(localized: "Choose Existing Repository"), symbol: GitIcon.Name.folder,
        )
        pickButton.addAction(UIAction { [weak self] _ in self?.showRepoPicker() }, for: .touchUpInside)

        let busySpinner = UIActivityIndicatorView(style: .medium)
        let busyLabel = UILabel().then {
            $0.text = String(localized: "Cloning the repository, please wait…")
            $0.font = GitTheme.bodySmall
            $0.textColor = GitTheme.onSurfaceVariant
            $0.textAlignment = .center
            $0.numberOfLines = 0
        }
        let busyRow = UIStackView(arrangedSubviews: [busySpinner, busyLabel]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.sm
            $0.alignment = .center
            $0.isHidden = true
        }
        busySpinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [title, first, second, row, pickButton, busyRow]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.md
            $0.alignment = .fill
        }
        container.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(GitTheme.Space.lg)
        }
        notARepoButtons = [row, pickButton]
        notARepoBusy = busyRow
        applyNotARepoBusy()
        return container
    }

    /// While a clone runs the reader sees the wait, not buttons that would
    /// start a second one — the reference app's arrangement.
    private func applyNotARepoBusy() {
        for view in notARepoButtons { view.isHidden = busy }
        notARepoBusy?.isHidden = !busy
    }

    // MARK: - Loading

    private func reloadAll() {
        guard !isLoading else { return }
        Task { @MainActor in
            isLoading = true
            await session.reload()
            isNotARepository = session.isNotARepository
            if !session.isNotARepository {
                await session.reloadCommits()
                await session.reloadStashes()
            }
            isLoading = false
            for page in pages {
                (page as? GitPage)?.applySession()
            }
        }
    }

    // MARK: - Pager

    private func selectTab(_ index: Int, animated: Bool) {
        guard index >= 0, index < pages.count else { return }
        currentTab = index
        tabs.select(index)
        let point = CGPoint(x: scroll.bounds.width * CGFloat(index), y: 0)
        if animated {
            UIView.animate(withDuration: 0.36, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3) {
                self.scroll.contentOffset = point
            }
        } else {
            scroll.contentOffset = point
        }
        (pages[index] as? GitPage)?.pageDidAppear()
    }

    // MARK: - Repository picker

    private func showRepoPicker() {
        let sheet = GitBottomSheetController(title: String(localized: "Choose Repository"))
        let stack = UIStackView().then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.xs
        }
        let root = DataFolder.app.projects.appendingPathComponent(session.projectName, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        ))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []

        let current = session.repository
        let rootIsRepo = current == nil && !isNotARepository
        stack.addArrangedSubview(makeRepoRow(
            repository: nil, isRepo: rootIsRepo, isSelected: current == nil,
            label: session.projectName,
        ))
        for entry in entries {
            let name = entry.lastPathComponent
            let isRepo = FileManager.default.fileExists(
                atPath: entry.appendingPathComponent(".git").path,
            )
            stack.addArrangedSubview(makeRepoRow(
                repository: name, isRepo: isRepo, isSelected: current == name,
                label: "\(session.projectName)/\(name)",
            ))
        }
        if entries.isEmpty, isNotARepository {
            let empty = UILabel().then {
                $0.text = String(localized: "No directories to choose in this workspace")
                $0.font = GitTheme.bodyMedium
                $0.textColor = GitTheme.onSurfaceVariant
                $0.numberOfLines = 0
            }
            stack.addArrangedSubview(empty)
        }
        let wrapper = UIView()
        wrapper.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        sheet.stack.addArrangedSubview(wrapper)
        present(sheet, animated: true)
    }

    private func makeRepoRow(
        repository: String?, isRepo: Bool, isSelected: Bool, label: String,
    ) -> UIView {
        let control = UIControl()
        control.isEnabled = isRepo
        let icon = UIImageView(image: GitIcon.image(GitIcon.Name.folder, pointSize: 20))
        icon.tintColor = isSelected ? GitTheme.primary : GitTheme.onSurfaceVariant
        let title = UILabel().then {
            $0.text = label
            $0.font = isSelected ? GitTheme.font(16, .semibold) : GitTheme.bodyLarge
            $0.textColor = isSelected ? GitTheme.primary : (isRepo ? GitTheme.onSurface : GitTheme.onSurfaceVariant)
            $0.lineBreakMode = .byTruncatingMiddle
            $0.numberOfLines = 1
        }
        control.addSubview(icon)
        control.addSubview(title)
        icon.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(GitTheme.Space.lg)
            make.centerY.equalToSuperview()
            make.size.equalTo(20)
        }
        if !isRepo {
            let trailing = UILabel().then {
                $0.text = String(localized: "Not a repository")
                $0.font = GitTheme.labelSmall
                $0.textColor = GitTheme.onSurfaceVariant
            }
            control.addSubview(trailing)
            trailing.snp.makeConstraints { make in
                make.trailing.equalToSuperview().offset(-GitTheme.Space.lg)
                make.centerY.equalToSuperview()
            }
            title.snp.makeConstraints { make in
                make.leading.equalTo(icon.snp.trailing).offset(GitTheme.Space.md)
                make.trailing.lessThanOrEqualTo(trailing.snp.leading).offset(-8)
                make.centerY.equalToSuperview()
            }
        } else {
            title.snp.makeConstraints { make in
                make.leading.equalTo(icon.snp.trailing).offset(GitTheme.Space.md)
                make.trailing.equalToSuperview().offset(-GitTheme.Space.lg)
                make.centerY.equalToSuperview()
            }
        }
        control.snp.makeConstraints { make in make.height.equalTo(48) }
        control.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.dismiss(animated: true) {
                self.openRepository(repository)
            }
        }, for: .touchUpInside)
        control.isAccessibilityElement = true
        control.accessibilityLabel = isRepo
            ? label
            : "\(label), \(String(localized: "Not a repository"))"
        control.accessibilityTraits = isRepo ? .button : [.button, .notEnabled]
        control.accessibilityValue = isSelected ? String(localized: "Current") : nil
        return control
    }

    /// Makes `repository` (nil: the workspace root) the repository the page
    /// reads, and reads it from nothing.
    private func openRepository(_ repository: String?) {
        Task { @MainActor in
            isLoading = true
            repoNameLabel.text = repository.map { "\(session.projectName)/\($0)" } ?? session.projectName
            await session.open(repository: repository)
            isNotARepository = session.isNotARepository
            isLoading = false
            for page in pages {
                (page as? GitPage)?.applySession()
            }
            (pages[currentTab] as? GitPage)?.pageDidAppear()
        }
    }

    // MARK: - Clone and init

    private func showCloneDialog() {
        let field = GitTextField(
            label: String(localized: "Repository URL"),
            placeholder: "https://github.com/user/repo.git",
        )
        field.field.keyboardType = .URL
        field.field.autocapitalizationType = .none
        presentGitDialog(
            title: String(localized: "Clone Git Repository"),
            message: String(localized: "Clone a remote repository into the current workspace root (directory must be empty). For private repos, configure credentials via the key icon first."),
            content: field,
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Clone")) { [weak self] in
                    guard let self, !field.text.isEmpty else { return }
                    self.clone(from: field.text)
                },
            ],
        )
    }

    private func clone(from url: String) {
        busy = true
        Task { @MainActor in
            do {
                try await session.cloneInto(url: url)
                await session.reload()
                await session.reloadCommits()
                isNotARepository = false
            } catch {
                gitShowToast(error.readableMessage)
            }
            busy = false
            isNotARepository = session.isNotARepository
            applyState()
            for page in pages { (page as? GitPage)?.applySession() }
        }
    }

    private func initialise() {
        busy = true
        Task { @MainActor in
            do {
                try await session.initialise()
                isNotARepository = false
                await session.reload()
                await session.reloadCommits()
            } catch {
                gitShowToast(error.readableMessage)
            }
            busy = false
            isNotARepository = session.isNotARepository
            applyState()
            for page in pages { (page as? GitPage)?.applySession() }
        }
    }
}

extension GitController: GitPageHost {
    func gitShowToast(_ text: String) {
        showToast(text)
    }

    func gitSetBusy(_ busy: Bool) {
        self.busy = busy
    }

    func gitReload() {
        reloadAll()
    }

    func gitOpenCredentials() {
        presentPageAsFormSheet(GitSettingsController())
    }

    func gitShowDiff(_ page: UIViewController) {
        // Presented from the screen, never from a tab inside it: a tab is one
        // of three in a pager, and a sheet it puts up belongs to whichever
        // tab was current when it did. A sheet that is still going away is
        // waited for, so a second tap is answered rather than dropped.
        if let presented = presentedViewController {
            if presented.isBeingDismissed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.presentDiffSheet(page)
                }
            } else {
                presented.dismiss(animated: true) { [weak self] in
                    self?.presentDiffSheet(page)
                }
            }
            return
        }
        presentDiffSheet(page)
    }

    private func presentDiffSheet(_ page: UIViewController) {
        page.modalPresentationStyle = .pageSheet
        if let sheet = page.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        present(page, animated: true)
    }
}

extension GitController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0 else { return }
        currentTab = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let page = Int(round(scrollView.contentOffset.x / max(scrollView.bounds.width, 1)))
        tabs.select(page)
        (pages[page] as? GitPage)?.pageDidAppear()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        let page = Int(round(scrollView.contentOffset.x / max(scrollView.bounds.width, 1)))
        tabs.select(page)
        (pages[page] as? GitPage)?.pageDidAppear()
    }
}

// MARK: - Toast

extension GitController {
    func showToast(_ text: String) {
        toast?.removeFromSuperview()
        toastWorkItem?.cancel()
        let label = UILabel().then {
            $0.text = text
            $0.font = GitTheme.bodySmall
            $0.textColor = .white
            $0.numberOfLines = 0
            $0.textAlignment = .center
        }
        let container = UIView().then {
            $0.backgroundColor = UIColor(rgb: 0x2C2C2E)
            $0.layer.cornerRadius = 4
            $0.layer.cornerCurve = .continuous
            $0.alpha = 0
        }
        container.addSubview(label)
        label.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        }
        view.addSubview(container)
        container.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(16)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
            make.bottom.equalTo(tabs.snp.top).offset(-12)
        }
        toast = container
        UIView.animate(withDuration: 0.2) { container.alpha = 1 }
        let work = DispatchWorkItem { [weak container] in
            UIView.animate(withDuration: 0.2) { container?.alpha = 0 } completion: { _ in
                container?.removeFromSuperview()
            }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
