import ApelinProtocol
import UIKit

/// Settings ▸ Plugins ▸ WeChat ClawBot: the switch, the WeChat sign-in, where
/// the bot's conversation opens, who may drive it and what a message may do
/// without a word here.
///
/// Every row is drawn from what the host answers (`channelList`) and every
/// change goes back as one `channelConfigure`, so the page keeps nothing the
/// host does not have. The bot's token never arrives here: the host keeps it,
/// and the page only learns whether there is one.
///
/// Approvals are the device's. A tool call a message asks for waits in Apelin,
/// and the channel is told while it waits; nothing said in WeChat approves
/// anything.
final class ClawBotController: TableController {
    /// The one channel this build ships. The host makes its folder from the
    /// name, so it never changes once a device has one.
    static let channelID = "wechat-clawbot"

    private enum Section: Hashable {
        case status
        case signIn
        case settings
        case users
    }

    private enum Row: Hashable {
        case account
        case connection
        /// The host's own sentence; `String` keeps every message apart.
        case error(String)
        case signIn
        case showCode
        case signOut
        case enabled
        case project
        case approvals
        case user(String)
        case addUser
    }

    private struct RowContent: Equatable {
        let row: Row
        let title: String
        let detail: String?
    }

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, content in
        self?.cell(in: table, content: content)
    }

    private let switchView = UISwitch()

    /// The page's copy, which every change is built from.
    private var enabled = false
    /// The peers the host will admit. The summary must carry the list itself:
    /// every change writes the whole list, and replacing one the page cannot
    /// read would drop a peer somebody added elsewhere.
    private var allowedUsers: [String] = []
    private var projectID: String?
    private var projectName: String?
    private var approvalMode: ApprovalMode = .confirm
    private var hasCredential = false
    private var state: ChannelState = .stopped
    private var taskID: TaskID?
    private var lastError: String?

    /// Counts the answers this page asked for, so a late one writes nothing.
    @objc private dynamic var generation = 0
    @objc private dynamic var projectGeneration = 0
    private var loader: Task<Void, Never>?
    private var saver: Task<Void, Never>?
    private var projectLoader: Task<Void, Never>?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    deinit {
        loader?.cancel()
        saver?.cancel()
        projectLoader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "WeChat ClawBot")
        navigationItem.backButtonDisplayMode = .minimal
        switchView.accessibilityLabel = String(localized: "WeChat ClawBot")
        switchView.addAction(
            UIAction { [weak self] _ in self?.switchChanged() },
            for: .valueChanged,
        )
        // Only the allowed users can be swiped away; every other row answers nil.
        dataSource.allowsEditing = true
        dataSource.headerTitle = { [weak self] in self?.header(for: $0) }
        dataSource.footerTitle = { [weak self] in self?.footer(for: $0) }
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        dataSource.beginLoad()
        loadStatus()
    }

    // MARK: - Reading

    @objc private dynamic func loadStatus() {
        loader?.cancel()
        generation &+= 1
        let generation = generation
        loader = Task { [weak self] in
            do {
                let channels = try await ApelinService.app.channelList(channelID: Self.channelID).channels
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                // A channel the host has never been asked to keep answers
                // nothing; the page stands at its defaults until the first
                // change names it.
                if let summary = channels.first {
                    self.apply(summary)
                    await self.nameProject()
                } else {
                    self.updateRows()
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.presentNotice(title: "WeChat ClawBot Unavailable", message: error.readableMessage)
            }
        }
    }

    /// What the host answered is the page's state, whatever the page had drawn
    /// while a change was in flight. Not `@objc`: a summary is a struct
    /// Objective-C cannot carry.
    private func apply(_ summary: ChannelSummary) {
        enabled = summary.enabled
        allowedUsers = summary.allowlist
        projectID = summary.projectID
        projectName = summary.projectID.flatMap { projectNames[$0] }
        approvalMode = summary.approvalMode
        hasCredential = summary.hasCredential
        state = summary.state
        taskID = summary.taskID
        lastError = summary.lastError?.message
        updateRows()
    }

    /// The host carries the project's ID and not its name; the folder's name
    /// is what the app shows everywhere else. Read once, then remembered.
    private func nameProject() async {
        guard let id = projectID, projectName == nil else { return }
        let projects = (try? await ProjectSummary.load()) ?? []
        guard !Task.isCancelled, projectID == id else { return }
        for project in projects where project.projectID == id {
            projectNames[id] = project.displayTitle
        }
        projectName = projectNames[id] ?? id
        updateRows()
    }

    // MARK: - Writing

    /// Sends everything the page holds, as the host takes it in one call.
    @objc private dynamic func saveConfiguration() {
        updateRows()
        let request = ChannelConfigureRequest(
            channelID: Self.channelID,
            kind: .weChatClawBot,
            enabled: enabled,
            binding: .project(projectID),
            allowlist: allowedUsers,
            approvalMode: approvalMode,
        )
        generation &+= 1
        let generation = generation
        saver?.cancel()
        saver = Task { [weak self] in
            do {
                let summary = try await ApelinService.app.channelConfigure(request)
                guard !Task.isCancelled, let self else { return }
                self.apply(summary)
                await self.nameProject()
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.presentNotice(title: "Not Saved", message: error.readableMessage)
                self.loadStatus()
            }
        }
    }

    // MARK: - The page

    @objc private dynamic func updateRows() {
        var rows: [(Section, [RowContent])] = []
        var statusRows: [RowContent] = [
            RowContent(
                row: .account,
                title: String(localized: "WeChat Account"),
                detail: hasCredential ? String(localized: "Signed In") : String(localized: "Not Signed In"),
            ),
            RowContent(
                row: .connection,
                title: String(localized: "Connection"),
                detail: Self.text(for: state),
            ),
        ]
        if let lastError, !lastError.isEmpty {
            statusRows.append(RowContent(row: .error(lastError), title: String(localized: "Last Error"), detail: lastError))
        }
        rows.append((.status, statusRows))

        var signInRows: [RowContent] = []
        if hasCredential {
            signInRows.append(RowContent(row: .signOut, title: String(localized: "Sign Out"), detail: nil))
        } else {
            signInRows.append(RowContent(row: .signIn, title: String(localized: "Sign In"), detail: nil))
        }
        if state == .awaitingLogin, taskID != nil {
            signInRows.append(RowContent(row: .showCode, title: String(localized: "Show Sign-In Code"), detail: nil))
        }
        rows.append((.signIn, signInRows))

        rows.append((.settings, [
            RowContent(row: .enabled, title: String(localized: "Enabled"), detail: nil),
            RowContent(row: .project, title: String(localized: "Target Project"), detail: targetText),
            RowContent(row: .approvals, title: String(localized: "Approvals"), detail: AgentPermissions.title(for: approvalMode)),
        ]))

        var userRows = allowedUsers.map { RowContent(row: .user($0), title: $0, detail: nil) }
        userRows.append(RowContent(row: .addUser, title: String(localized: "Add Allowed User"), detail: nil))
        rows.append((.users, userRows))

        dataSource.update(rows, reconfigure: true)
        if switchView.isOn != enabled {
            switchView.setOn(enabled, animated: true)
        }
    }

    /// The project the bot opens in: General Chat when the channel names none,
    /// the folder's own name when it is known, and the ID until then.
    @objc private dynamic var targetText: String {
        guard let projectID else { return String(localized: "General Chat") }
        return projectName ?? projectID
    }

    /// Not `@objc`: a section is this page's own enum.
    private func header(for section: Section) -> String? {
        switch section {
        case .status:
            return String(localized: "Status")
        case .signIn, .settings:
            return nil
        case .users:
            return String(localized: "Allowed Users")
        }
    }

    /// Not `@objc`: a section is this page's own enum.
    private func footer(for section: Section) -> String? {
        switch section {
        case .status, .signIn:
            return nil
        case .settings:
            return String(localized: """
            A tool call a WeChat message asks for is approved on this device, in Apelin — never in WeChat; \
            the chat is told while it waits.
            """)
        case .users:
            return String(localized: """
            Only the WeChat accounts listed here can reach the agent. While the list is empty the bot \
            cannot be turned on.
            """)
        }
    }

    // MARK: - Cells

    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        switch value.row {
        case .enabled:
            let cell = tableView.dequeueReusableCell(withIdentifier: "clawbot-switch")
                ?? UITableViewCell(style: .default, reuseIdentifier: "clawbot-switch")
            var content = UIListContentConfiguration.valueCell()
            content.text = value.title
            cell.contentConfiguration = content
            cell.accessoryView = switchView
            cell.selectionStyle = .none
            return cell
        case let .error(message):
            let cell = tableView.dequeueReusableCell(withIdentifier: "clawbot-error")
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: "clawbot-error")
            var content = UIListContentConfiguration.explanatoryCell()
            content.text = value.title
            content.secondaryText = message
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        default:
            break
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "clawbot")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "clawbot")
        var content = UIListContentConfiguration.valueCell()
        content.text = value.title
        content.secondaryText = value.detail
        switch value.row {
        case .account, .connection, .user:
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case .addUser:
            content.textProperties.color = .tintColor
            cell.accessoryType = .none
            cell.selectionStyle = .default
        case .signOut:
            content.textProperties.color = .systemRed
            cell.accessoryType = .none
            cell.selectionStyle = .default
        case .signIn, .showCode, .project, .approvals:
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .enabled, .error:
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    // MARK: - Rows

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        switch row {
        case .signIn, .showCode:
            pushSignIn()
        case .signOut:
            confirmSignOut()
        case .project:
            chooseProject()
        case .approvals:
            chooseApprovals()
        case .addUser:
            addUser()
        case .account, .connection, .enabled, .error, .user:
            break
        }
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard case let .user(id)? = dataSource.value(at: indexPath)?.row else { return nil }
        let remove = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, completion in
            completion(true)
            self?.remove(id)
        }
        remove.image = UIImage(systemName: "trash")
        let actions = UISwipeActionsConfiguration(actions: [remove])
        actions.performsFirstActionWithFullSwipe = false
        return actions
    }

    // MARK: - The switch

    @objc private dynamic func switchChanged() {
        let turnedOn = switchView.isOn
        guard turnedOn else {
            enabled = false
            saveConfiguration()
            return
        }
        guard hasCredential else {
            switchView.setOn(false, animated: true)
            presentNotice(
                title: "Sign In First",
                message: "The bot cannot start until WeChat is signed in. Sign in above, then turn it on.",
            )
            return
        }
        guard !allowedUsers.isEmpty else {
            switchView.setOn(false, animated: true)
            presentNotice(
                title: "Add Allowed Users First",
                message: "The bot stays off until at least one WeChat user is allowed. Add one under Allowed Users.",
            )
            return
        }
        enabled = true
        saveConfiguration()
    }

    // MARK: - Signing in

    @objc private dynamic func pushSignIn() {
        let page = ClawBotLoginController(channelID: Self.channelID)
        page.onFinish = { [weak self] _ in
            // The host turns the switch on when the sign-in lands; the page
            // asks for the list again rather than guessing what it did.
            self?.loadStatus()
        }
        navigationController?.pushViewController(page, animated: true)
    }

    @objc private dynamic func confirmSignOut() {
        presentConfirmation(
            title: "Sign Out WeChat?",
            message: "The bot stops and this device forgets its WeChat sign-in. The conversation it opened stays.",
            cancelTitle: "Cancel",
            confirmTitle: "Sign Out",
            destructive: true,
        ) { [weak self] in self?.signOut() }
    }

    @objc private dynamic func signOut() {
        generation &+= 1
        let generation = generation
        saver?.cancel()
        saver = Task { [weak self] in
            do {
                let summary = try await ApelinService.app.channelLogout(channelID: Self.channelID)
                guard !Task.isCancelled, let self else { return }
                self.apply(summary)
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.presentNotice(title: "Could Not Sign Out", message: error.readableMessage)
            }
        }
    }

    // MARK: - Who may talk

    @objc private dynamic func addUser() {
        presentTextInput(
            title: "Add Allowed User",
            message: "Type the WeChat user ID to allow. Only the accounts listed here reach the agent.",
            placeholder: "WeChat ID",
            doneTitle: "Add",
        ) { [weak self] text in
            guard let self else { return }
            let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !self.allowedUsers.contains(id) else { return }
            self.allowedUsers.append(id)
            self.saveConfiguration()
        }
    }

    @objc private dynamic func remove(_ id: String) {
        allowedUsers.removeAll { $0 == id }
        guard allowedUsers.isEmpty, enabled else {
            saveConfiguration()
            return
        }
        // Nothing may reach the agent without a name on the list.
        enabled = false
        saveConfiguration()
        presentNotice(
            title: "The Bot Was Turned Off",
            message: "Nothing can reach the agent while no WeChat user is allowed. Add one to turn it back on.",
        )
    }

    // MARK: - Where it opens

    @objc private dynamic func chooseProject() {
        projectLoader?.cancel()
        projectGeneration &+= 1
        let generation = projectGeneration
        projectLoader = Task { [weak self] in
            do {
                let projects = try await ProjectSummary.load()
                guard !Task.isCancelled, let self, self.projectGeneration == generation else { return }
                self.showProjectChoice(projects)
            } catch {
                guard !Task.isCancelled, let self, self.projectGeneration == generation else { return }
                self.presentNotice(title: "Projects Unavailable", message: error.readableMessage)
            }
        }
    }

    /// Not `@objc`: a project is a struct Objective-C cannot carry.
    private func showProjectChoice(_ projects: [ProjectSummary]) {
        var titles = [String(localized: "General Chat")]
        var ids: [String?] = [nil]
        for project in projects {
            titles.append(project.displayTitle)
            ids.append(project.projectID)
        }
        let page = ClawBotChoiceController(
            title: String(localized: "Target Project"),
            options: titles,
            selected: ids.firstIndex { $0 == projectID } ?? 0,
            footer: String(localized: """
            Every conversation the bot opens starts in this project. General Chat keeps them out of \
            your projects.
            """),
        ) { [weak self] index in
            guard let self, index < ids.count else { return }
            self.projectID = ids[index]
            if let id = ids[index] {
                self.projectNames[id] = titles[index]
            }
            self.projectName = ids[index].flatMap { self.projectNames[$0] }
            self.updateRows()
            self.saveConfiguration()
        }
        navigationController?.pushViewController(page, animated: true)
    }

    // MARK: - What a message may do

    @objc private dynamic func chooseApprovals() {
        let modes: [ApprovalMode] = [.confirm, .relaxed]
        let page = ClawBotChoiceController(
            title: String(localized: "Approvals"),
            options: modes.map { AgentPermissions.title(for: $0) },
            selected: modes.firstIndex(of: approvalMode) ?? 0,
            footer: String(localized: """
            Strict asks before each step. Relaxed runs them within the app's own permission mode. \
            Full is never offered to a chat channel, and a call still asks on this device.
            """),
        ) { [weak self] index in
            guard let self, index < modes.count else { return }
            self.approvalMode = modes[index]
            self.updateRows()
            self.saveConfiguration()
        }
        navigationController?.pushViewController(page, animated: true)
    }

    // MARK: - Words

    /// The channel's state in the reader's words. Not `@objc`: a state is an
    /// enum of the protocol's, which Objective-C cannot carry.
    static func text(for state: ChannelState) -> String {
        switch state {
        case .stopped:
            return String(localized: "Stopped")
        case .starting:
            return String(localized: "Starting")
        case .awaitingLogin:
            return String(localized: "Waiting for Sign-In")
        case .online:
            return String(localized: "Online")
        case .paused:
            return String(localized: "Paused")
        case .failed:
            return String(localized: "Failed")
        }
    }

    /// A project's name from its folder, for a summary that carries only the
    /// ID: a folder that is gone is shown by its ID rather than by nothing.
    private var projectNames: [String: String] = [:]
}
