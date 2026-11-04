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
        case launch
        case returnKey
        case compression
        case modelProviders
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

    private func updateRows() {
        dataSource.headerTitle = { [weak self] in self?.header(for: $0) }
        dataSource.footerTitle = { [weak self] in self?.footer(for: $0) }
        dataSource.update(Section.allCases.map { section in
            (section, rows(in: section).map { row in
                let detail: String? = switch row {
                case .launch: Preferences.launch.title
                case .returnKey: ComposerBehavior.useConfirmationOnSend
                    ? String(localized: "New Line")
                    : String(localized: "Send")
                case .compression: Preferences.percentText(Preferences.compressionThreshold)
                case .permissionMode: AgentPermissions.title(for: AgentPermissions.mode)
                case .memories: memorySummary
                default: nil
                }
                return RowContent(row: row, detail: detail)
            })
        }, reconfigure: true)
    }

    private var memorySummary: String?
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
        case .chat: [.launch, .returnKey, .compression]
        case .agent: [.modelProviders, .permissionMode, .memories, .skills]
        case .environment: [.toolchain, .sdks, .templates]
        case .git: [.git]
        case .about: [.version, .licenses, .logs]
        }
    }

    private func loadMemorySummary() {
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
        case .chat: String(localized: "Chat")
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
        case .launch:
            content.text = String(localized: "On Launch")
        case .returnKey:
            content.text = String(localized: "Return Key")
        case .compression:
            content.text = String(localized: "Compression Threshold")
        case .modelProviders:
            content.text = String(localized: "Model Providers")
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
        switch row {
        case .launch:
            choose(
                title: String(localized: "On Launch"),
                options: Preferences.Launch.allCases.map { ($0.title, $0 == Preferences.launch) },
            ) { index in
                Preferences.launch = Preferences.Launch.allCases[index]
                self.updateRows()
            }
            return
        case .returnKey:
            choose(
                title: String(localized: "Return Key"),
                options: [
                    (String(localized: "Send"), !ComposerBehavior.useConfirmationOnSend),
                    (String(localized: "New Line"), ComposerBehavior.useConfirmationOnSend),
                ],
            ) { index in
                ComposerBehavior.useConfirmationOnSend = index == 1
                self.updateRows()
            }
            return
        case .compression:
            let current = Preferences.compressionThreshold
            choose(
                title: String(localized: "Compression Threshold"),
                options: Preferences.compressionChoices.map {
                    (Preferences.percentText($0), abs($0 - current) < 0.001)
                },
            ) { index in
                Preferences.compressionThreshold = Preferences.compressionChoices[index]
                self.updateRows()
            }
            return
        default: break
        }
        let page: UIViewController
        switch row {
        case .modelProviders: page = ModelProvidersController()
        case .permissionMode: page = PermissionModeController()
        case .memories: page = MemoriesController()
        case .skills: page = SkillsController()
        case .toolchain: page = ToolchainController()
        case .sdks: page = SDKListController()
        case .templates: page = TemplatesController()
        case .git: page = GitSettingsController()
        case .licenses: page = LicensesViewController()
        case .logs: page = LogsController()
        case .version, .launch, .returnKey, .compression: return
        }
        navigationController?.pushViewController(page, animated: true)
    }

    /// A list of choices as a sheet, the chosen one ticked; a tap answers
    /// with the line it was on.
    private func choose(
        title: String,
        options: [(String, Bool)],
        chosen: @escaping (Int) -> Void,
    ) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (index, option) in options.enumerated() {
            let action = UIAlertAction(title: option.0, style: .default) { _ in chosen(index) }
            action.setValue(option.1, forKey: "checked")
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1,
        )
        present(sheet, animated: true)
    }

    /// Settings as the sidebar's gear opens it, but already at Git, for a
    /// page whose next step is set up there: a package repository, and the
    /// GitHub sign-in it needs. Back leads to the rest of Settings.
    static func presentGit(from presenter: UIViewController) {
        let settings = SettingsViewController()
        // the Git page's Back is made from the title and back button mode
        // this page sets as it loads
        settings.loadViewIfNeeded()
        presenter.presentPageAsFormSheet(settings, openedAt: GitSettingsController())
    }

    /// Closes Settings and shows the welcome pages from the start.
    private func openOnboarding() {
        guard let root = view.window?.rootViewController as? RootInterfaceController else { return }
        navigationController?.dismiss(animated: true) { [weak root] in root?.presentWelcome() }
    }

    /// A new issue on Apelin's repository, in the browser.
    private static func reportProblem() {
        guard let url = URL(string: "https://github.com/owngoal-dev/Apelin/issues/new") else { return }
        UIApplication.shared.open(url)
    }
}
