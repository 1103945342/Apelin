import ApelinCore
import Then
import UIKit

/// Settings groups agent preferences, the development environment, Git and About.
/// Only Memories shows a count, refreshed whenever Settings appears.
/// The `…` in the bar opens onboarding again or a new GitHub issue.
final class SettingsViewController: TableController {
    private enum Section: Hashable, CaseIterable {
        case chat
        case agent
        case environment
        case git
        case about
    }

    private enum Row: Hashable {
        case preferences
        case modelProviders
        case defaultModels
        case permissionMode
        case memories
        case skills
        case toolchain
        case sdks
        case templates
        case git
        case version
        case licenses
        case logs
    }

    private struct RowContent: Equatable {
        let row: Row
        let detail: String?
    }

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, row in
        self?.cell(in: table, content: row)
    }

    @objc private dynamic func updateRows() {
        dataSource.headerTitle = { [weak self] in self?.header(for: $0) }
        dataSource.footerTitle = { [weak self] in self?.footer(for: $0) }
        dataSource.update(Section.allCases.map { section in
            (section, rows(in: section).map { row in
                let detail: String? = switch row {
                case .defaultModels: Preferences.DefaultModels.summary
                case .permissionMode: AgentPermissions.title(for: AgentPermissions.mode)
                case .memories: memorySummary
                default: nil
                }
                return RowContent(row: row, detail: detail)
            })
        }, reconfigure: true)
    }

    @objc private dynamic var memorySummary: String?
    private var loader: Task<Void, Never>?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Settings")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIAction(
                    title: String(localized: "Open Onboarding"),
                    image: UIImage(systemName: "hand.wave"),
                ) { [weak self] _ in self?.openOnboarding() },
                UIAction(
                    title: String(localized: "Report a Problem"),
                    image: UIImage(systemName: "exclamationmark.bubble"),
                ) { _ in Self.reportProblem() },
            ]),
        ).then { $0.accessibilityLabel = String(localized: "More") }
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        dataSource.beginLoad()
        updateRows()
        loadMemorySummary()
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .chat: [.preferences]
        case .agent: [.modelProviders, .defaultModels, .permissionMode, .memories, .skills]
        case .environment: [.toolchain, .sdks, .templates]
        case .git: [.git]
        case .about: [.version, .licenses, .logs]
        }
    }

    @objc private dynamic func loadMemorySummary() {
        loader?.cancel()
        let store = MemoryStore(root: DataFolder.app.root)
        loader = Task { [weak self] in
            let count = await Task.detached { try? store.read().records.count }.value
            guard !Task.isCancelled, let self else { return }
            memorySummary = count?.formatted()
            updateRows()
        }
    }

    private func header(for section: Section) -> String? {
        switch section {
        // The section's one row names itself; the list at the top needs no
        // heading over a single word.
        case .chat: nil
        case .agent: String(localized: "Agent")
        case .environment: String(localized: "Environment")
        case .git: nil
        case .about: String(localized: "About")
        }
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .chat: nil
        case .agent: nil
        case .environment: nil
        case .git:
            String(localized: "The author of your commits, your GitHub account, and the package repository your releases are published to.")
        case .about: nil
        }
    }

    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "setting")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "setting")
        var content = UIListContentConfiguration.valueCell()
        content.secondaryText = value.detail
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        switch value.row {
        case .preferences:
            content.text = String(localized: "Preferences")
        case .modelProviders:
            content.text = String(localized: "Model Providers")
        case .defaultModels:
            content.text = String(localized: "Default Models")
        case .permissionMode:
            content.text = String(localized: "Permission Mode")
        case .memories:
            content.text = String(localized: "Memories")
        case .skills:
            content.text = String(localized: "Skills")
        case .toolchain:
            content.text = String(localized: "Toolchains")
        case .sdks:
            content.text = String(localized: "SDKs")
        case .templates:
            content.text = String(localized: "Templates")
        case .git:
            content.text = String(localized: "Git")
        case .version:
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            let build = info?["CFBundleVersion"] as? String ?? "?"
            content.text = String(localized: "Version")
            content.secondaryText = "\(version) (\(build))"
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case .licenses:
            content.text = String(localized: "Open Source Licenses")
        case .logs:
            content.text = String(localized: "Logs")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if case .version = dataSource.value(at: indexPath)?.row {
            return false
        }
        return true
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        let page: UIViewController
        switch row {
        case .preferences: page = ChatPreferencesController()
        case .modelProviders: page = ModelProvidersController()
        case .defaultModels: page = DefaultModelsController()
        case .permissionMode: page = PermissionModeController()
        case .memories: page = MemoriesController()
        case .skills: page = SkillsController()
        case .toolchain: page = ToolchainController()
        case .sdks: page = SDKListController()
        case .templates: page = TemplatesController()
        case .git: page = GitSettingsController()
        case .licenses: page = LicensesViewController()
        case .logs: page = LogsController()
        case .version: return
        }
        navigationController?.pushViewController(page, animated: true)
    }

    /// Settings as the sidebar's gear opens it, but already at Git, for a
    /// page whose next step is set up there: a package repository, and the
    /// GitHub sign-in it needs. Back leads to the rest of Settings.
    @objc dynamic static func presentGit(from presenter: UIViewController) {
        let settings = SettingsViewController()
        // the Git page's Back is made from the title and back button mode
        // this page sets as it loads
        settings.loadViewIfNeeded()
        presenter.presentPageAsFormSheet(settings, openedAt: GitSettingsController())
    }

    /// Closes Settings and shows the welcome pages from the start.
    @objc private dynamic func openOnboarding() {
        guard let root = view.window?.rootViewController as? RootInterfaceController else { return }
        navigationController?.dismiss(animated: true) { [weak root] in root?.presentWelcome() }
    }

    /// A new issue on Apelin's repository, in the browser.
    @objc private dynamic static func reportProblem() {
        guard let url = URL(string: "https://github.com/owngoal-dev/Apelin/issues/new") else { return }
        UIApplication.shared.open(url)
    }
}

/// Settings ▸ Preferences: what the chat itself does before a word is typed —
/// where a launch lands, what the return key sends, and when a conversation
/// that has grown long compacts itself.
///
/// Each answer is a page of its own, pushed as every other setting here is
/// (owner, 2026-11-08): a sheet that closed on every tap hid both what was
/// chosen and what was left to choose.
final class ChatPreferencesController: TableController {
    private enum Section: Hashable { case chat }

    private enum Row: Hashable {
        case launch
        case returnKey
        case compression
    }

    private struct RowContent: Equatable {
        let row: Row
        let detail: String
    }

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, row in
        self?.cell(in: table, content: row)
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Preferences")
        navigationItem.backButtonDisplayMode = .minimal
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateRows()
    }

    private func updateRows() {
        dataSource.update([(.chat, [
            RowContent(row: .launch, detail: Preferences.launch.title),
            RowContent(
                row: .returnKey,
                detail: ComposerBehavior.useConfirmationOnSend
                    ? String(localized: "New Line")
                    : String(localized: "Send"),
            ),
            RowContent(row: .compression, detail: Preferences.percentText(Preferences.compressionThreshold)),
        ])], reconfigure: true)
    }

    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chat-preference")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "chat-preference")
        var content = UIListContentConfiguration.valueCell()
        content.secondaryText = value.detail
        switch value.row {
        case .launch: content.text = String(localized: "On Launch")
        case .returnKey: content.text = String(localized: "Return Key")
        case .compression: content.text = String(localized: "Compression Threshold")
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        switch row {
        case .launch:
            let launches = Preferences.Launch.allCases
            push(
                SettingChoiceController(
                    title: String(localized: "On Launch"),
                    options: launches.map(\.title),
                    selected: launches.firstIndex(of: Preferences.launch) ?? 0,
                ) { index in
                    Preferences.launch = launches[index]
                },
            )
        case .returnKey:
            push(
                SettingChoiceController(
                    title: String(localized: "Return Key"),
                    options: [String(localized: "Send"), String(localized: "New Line")],
                    selected: ComposerBehavior.useConfirmationOnSend ? 1 : 0,
                ) { index in ComposerBehavior.useConfirmationOnSend = index == 1 },
            )
        case .compression:
            let choices = Preferences.compressionChoices
            let current = Preferences.compressionThreshold
            push(
                SettingChoiceController(
                    title: String(localized: "Compression Threshold"),
                    options: choices.map { Preferences.percentText($0) },
                    selected: choices.firstIndex { abs($0 - current) < 0.001 } ?? choices.count - 1,
                ) { index in Preferences.compressionThreshold = choices[index] },
            )
        }
    }

    private func push(_ page: UIViewController) {
        navigationController?.pushViewController(page, animated: true)
    }
}

/// A handful of answers with the one in use ticked. The page stays open after
/// a tap, as Permission Mode does, so the reader sees what they picked before
/// going back.
private final class SettingChoiceController: TableController {
    private enum Section: Hashable { case options }

    private struct Row: Equatable {
        let index: Int
        let title: String
        let selected: Bool
    }

    private let titles: [String]
    private let choose: (Int) -> Void
    private var selected: Int

    private lazy var dataSource = TableDataSource<Section, Int, Row>(
        tableView: tableView,
        identifier: { $0.index },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    init(title: String, options: [String], selected: Int, choose: @escaping (Int) -> Void) {
        titles = options
        self.selected = selected
        self.choose = choose
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:options:selected:choose:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        updateRows()
    }

    private func updateRows() {
        dataSource.update([(.options, titles.enumerated().map { index, title in
            Row(index: index, title: title, selected: index == selected)
        })], reconfigure: true)
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "setting-choice")
            ?? UITableViewCell(style: .default, reuseIdentifier: "setting-choice")
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        cell.contentConfiguration = content
        cell.accessoryType = row.selected ? .checkmark : .none
        cell.accessibilityTraits = row.selected ? [.button, .selected] : [.button]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath), row.index != selected else { return }
        selected = row.index
        choose(row.index)
        updateRows()
    }
}
