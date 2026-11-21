import LurosCore
import LurosProtocol
import SPIndicator
import UIKit

/// Settings ▸ Storage ▸ Projects: every project with what its folder costs,
/// deleted through the runtime so the sidebar forgets it in the same breath.
/// The folder, its files and its Git history go; nothing is recoverable.
final class StorageProjectsController: TableController {
    private enum Row: Hashable {
        case deleteAll
        case project(name: String, title: String, bytes: Int64?)
        case reading
        case empty
    }

    private lazy var dataSource = TableDataSource<String, String, Row>(
        tableView: tableView,
        identifier: { row in
            switch row {
            case .deleteAll: "delete-all"
            case let .project(name, _, _): "project:" + name
            case .reading: "reading"
            case .empty: "empty"
            }
        },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private let runtime: ChatRuntime
    private var projects: [ProjectSummary] = []
    private var sizes: [String: StorageEntry] = [:]
    private var loading = false
    private var deleting = false

    init(runtime: ChatRuntime) {
        self.runtime = runtime
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(runtime:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Projects")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.footerTitle = { _ in
            String(localized: """
            A project's folder, its files and its Git history are deleted, and every conversation in it \
            goes with them.
            """)
        }
        tableView.backgroundView = LoadingView()
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        guard !loading else { return }
        loading = true
        Task { [weak self] in
            let projects = (try? await ProjectSummary.load()) ?? []
            let response = try? await LurosService.app.storageUsage(areas: [.projects], children: true)
            guard let self else { return }
            loading = false
            self.projects = projects
            var sizes: [String: StorageEntry] = [:]
            for entry in response?.usage.first?.entries ?? [] {
                sizes[entry.name] = entry
            }
            self.sizes = sizes
            refreshControl?.endRefreshing()
            tableView.backgroundView = projects.isEmpty
                ? EmptyStateView(
                    symbolName: "folder",
                    title: String(localized: "No Projects"),
                    text: String(localized: "A project appears here once one is made."),
                )
                : nil
            show()
        }
    }

    private func show() {
        var rows: [Row] = []
        if !projects.isEmpty {
            rows.append(.deleteAll)
            rows.append(contentsOf: projects.map { project in
                .project(
                    name: project.name,
                    title: project.displayTitle,
                    bytes: sizes[project.name]?.bytes,
                )
            })
        } else {
            rows.append(.empty)
        }
        dataSource.update([("projects", rows)], reconfigure: true)
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "storage-project")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "storage-project")
        var content = UIListContentConfiguration.subtitleCell()
        switch row {
        case .deleteAll:
            content.text = String(localized: "Delete Every Project")
            content.textProperties.color = .systemRed
            cell.accessoryType = .none
            cell.selectionStyle = .default
            cell.isAccessibilityElement = false
        case let .project(name, title, bytes):
            content.text = title
            let size = bytes.map(StorageController.format)
            content.secondaryText = [name == title ? nil : name, size]
                .compactMap { $0 }
                .joined(separator: " · ")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .default
            // The cell draws both lines itself, so it is the one element.
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = title
            cell.accessibilityValue = (([name == title ? nil : name, size] as [String?])
                .compactMap { $0 })
                .joined(separator: ", ")
            cell.accessibilityTraits = .button
        case .reading:
            content.text = String(localized: "Reading…")
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
        case .empty:
            content.text = String(localized: "No Projects")
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.value(at: indexPath) {
        case .deleteAll, .project: return !deleting
        default: return false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case .deleteAll:
            confirmDeleteAll()
        case let .project(name, title, bytes):
            confirmDelete(name: name, title: title, bytes: bytes)
        default:
            break
        }
    }

    private func confirmDelete(name: String, title: String, bytes: Int64?) {
        let size = bytes.map(StorageController.format) ?? String(localized: "Unknown Size")
        presentConfirmation(
            title: "Delete \(title)?",
            message: """
            \(size) at Projects/\(name) is deleted, its Git history with it, and every conversation in it \
            goes too. This cannot be undone.
            """,
            confirmTitle: "Delete",
            destructive: true,
        ) { [weak self] in
            self?.delete(name)
        }
    }

    private func confirmDeleteAll() {
        presentTextInput(
            title: "Delete Every Project?",
            message: """
            Every folder under Projects/ is deleted, with its Git history, and every conversation in them \
            goes too. This cannot be undone. Type DELETE to go ahead.
            """,
            placeholder: "DELETE",
            doneTitle: "Delete All",
        ) { [weak self] typed in
            guard typed == "DELETE" else { return }
            self?.deleteAll()
        }
    }

    private func delete(_ name: String) {
        guard !deleting else { return }
        deleting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.deleteProject(name)
                deleting = false
                SPIndicator.present(title: String(localized: "Deleted"), preset: .done, haptic: .success)
            } catch {
                deleting = false
                presentNotice(title: "Unable to Delete Project", message: error.readableMessage)
            }
            load()
        }
    }

    private func deleteAll() {
        guard !deleting else { return }
        deleting = true
        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for project in projects {
                do {
                    try await runtime.deleteProject(project.name)
                } catch {
                    failed += 1
                }
            }
            deleting = false
            if failed > 0 {
                presentNotice(
                    title: "Unable to Delete Project",
                    message: "Some of the folders could not be removed.",
                )
            } else {
                SPIndicator.present(title: String(localized: "Deleted"), preset: .done, haptic: .success)
            }
            load()
        }
    }
}

/// Settings ▸ Storage ▸ Conversations: every conversation with what its
/// record and event log cost, deleted through the runtime so the sidebar's row
/// goes in the same breath.
final class StorageConversationsController: TableController {
    private enum Row: Hashable {
        case deleteAll
        case conversation(id: UUID, title: String, project: String?, bytes: Int64?)
        case empty
    }

    private lazy var dataSource = TableDataSource<String, String, Row>(
        tableView: tableView,
        identifier: { row in
            switch row {
            case .deleteAll: "delete-all"
            case let .conversation(id, _, _, _): "chat:" + id.uuidString
            case .empty: "empty"
            }
        },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private let runtime: ChatRuntime
    private var sizes: [String: Int64] = [:]
    private var loading = false
    private var deleting = false

    init(runtime: ChatRuntime) {
        self.runtime = runtime
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(runtime:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Conversations")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.footerTitle = { _ in
            String(localized: """
            A conversation's messages and the record an agent resumes from are deleted together. This \
            cannot be undone.
            """)
        }
        tableView.backgroundView = LoadingView()
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        guard !loading else { return }
        loading = true
        Task { [weak self] in
            let response = try? await LurosService.app.storageUsage(areas: [.chats], children: true)
            guard let self else { return }
            loading = false
            var sizes: [String: Int64] = [:]
            for entry in response?.usage.first?.entries ?? [] {
                sizes[entry.name] = entry.bytes
            }
            self.sizes = sizes
            refreshControl?.endRefreshing()
            tableView.backgroundView = rows().count <= 1
                ? EmptyStateView(
                    symbolName: "bubble.left.and.bubble.right",
                    title: String(localized: "No Conversations"),
                    text: String(localized: "A conversation appears here once one is started."),
                )
                : nil
            dataSource.update([("chats", rows())], reconfigure: true)
        }
    }

    private func rows() -> [Row] {
        let summaries = runtime.summaries.sorted { $0.lastInteraction > $1.lastInteraction }
        guard !summaries.isEmpty else { return [.empty] }
        return [.deleteAll] + summaries.map { summary in
            .conversation(
                id: summary.id,
                title: summary.title,
                project: summary.projectName,
                bytes: sizes[summary.id.uuidString] ?? sizes[summary.id.uuidString.lowercased()],
            )
        }
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "storage-chat")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "storage-chat")
        var content = UIListContentConfiguration.subtitleCell()
        switch row {
        case .deleteAll:
            content.text = String(localized: "Delete Every Conversation")
            content.textProperties.color = .systemRed
            cell.accessoryType = .none
            cell.isAccessibilityElement = false
        case let .conversation(_, title, project, bytes):
            content.text = title
            content.textProperties.numberOfLines = 1
            let size = bytes.map(StorageController.format)
            content.secondaryText = [project, size].compactMap { $0 }.joined(separator: " · ")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = title
            cell.accessibilityValue = [project, size].compactMap { $0 }.joined(separator: ", ")
            cell.accessibilityTraits = .button
        case .empty:
            content.text = String(localized: "No Conversations")
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.value(at: indexPath) {
        case .deleteAll, .conversation: return !deleting
        default: return false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case .deleteAll:
            confirmDeleteAll()
        case let .conversation(id, title, _, bytes):
            let size = bytes.map(StorageController.format) ?? String(localized: "Unknown Size")
            presentConfirmation(
                title: "Delete \(title)?",
                message: "\(size) of messages is deleted with the record an agent resumes from. This cannot be undone.",
                confirmTitle: "Delete",
                destructive: true,
            ) { [weak self] in
                self?.delete([id])
            }
        default:
            break
        }
    }

    private func confirmDeleteAll() {
        presentTextInput(
            title: "Delete Every Conversation?",
            message: """
            Every conversation's messages and every record an agent resumes from are deleted. This cannot \
            be undone. Type DELETE to go ahead.
            """,
            placeholder: "DELETE",
            doneTitle: "Delete All",
        ) { [weak self] typed in
            guard typed == "DELETE" else { return }
            self?.delete(self?.runtime.summaries.map(\.id) ?? [])
        }
    }

    private func delete(_ ids: [UUID]) {
        guard !deleting, !ids.isEmpty else { return }
        deleting = true
        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for id in ids {
                do {
                    try await runtime.delete(id)
                } catch {
                    failed += 1
                }
            }
            deleting = false
            if failed > 0 {
                presentNotice(
                    title: "Unable to Delete Conversation",
                    message: "Some of the conversations could not be removed.",
                )
            } else {
                SPIndicator.present(title: String(localized: "Deleted"), preset: .done, haptic: .success)
            }
            load()
        }
    }
}
