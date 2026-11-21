import LurosCore
import LurosProtocol
import SPIndicator
import UIKit

/// Settings ▸ Storage: what Luros keeps on the device, measured only while
/// this page is open and one area at a time, so a figure appears as soon as
/// its own walk ends and nothing waits on the largest folder.
///
/// Two kinds of clearing. The host empties the folders nothing indexes
/// (builds, temporary files, exports, logs, backups) through `storagePurge`.
/// A project, a conversation and the sessions an agent resumes from belong to
/// the runtime that shows them: they are deleted through it, so the sidebar
/// and the chat list forget them too. An SDK and a toolchain are removed on
/// their own pages, which this one only opens.
final class StorageController: TableController {
    private enum Section: Hashable, CaseIterable {
        case disk
        case areas
        case purgeable
    }

    private enum Row: Hashable {
        case disk
        case area(StorageArea)
        case purge(StorageArea)
        case purgeAll
    }

    private struct RowContent: Equatable {
        let row: Row
        let detail: String?
    }

    /// Measured here, and deleted by the runtime or a page of its own.
    static let areas: [StorageArea] = [.projects, .chats, .sessions, .sdks, .toolchains]
    /// Emptied by the host.
    static let purgeable: [StorageArea] = [.builds, .temporary, .exports, .logs, .backups]

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, content in
        self?.cell(in: table, content: content)
    }

    private var usage: [StorageArea: StorageUsage] = [:]
    private var disk: StorageDisk?
    private var measuring: [StorageArea: Task<Void, Never>] = [:]
    private var diskTask: Task<Void, Never>?
    private var working = false

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Storage")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.headerTitle = { [weak self] section in self?.header(for: section) }
        dataSource.footerTitle = { [weak self] section in self?.footer(for: section) }
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.measureAll() }, for: .valueChanged)
        }
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        measureAll()
    }

    /// Nothing is measured while the page is away: the walks stop with it.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        measuring.values.forEach { $0.cancel() }
        measuring.removeAll()
        diskTask?.cancel()
        diskTask = nil
    }

    // MARK: - Measuring

    private func measureAll() {
        measureDisk()
        for area in Self.areas + Self.purgeable {
            measure(area, children: false)
        }
        updateRows()
    }

    func measure(_ area: StorageArea, children: Bool) {
        measuring[area]?.cancel()
        measuring[area] = Task { [weak self] in
            let response = try? await LurosService.app.storageUsage(areas: [area], children: children)
            guard !Task.isCancelled, let self else { return }
            if let measured = response?.usage.first {
                usage[area] = measured
            }
            measuring[area] = nil
            refreshControl?.endRefreshing()
            updateRows()
        }
    }

    private func measureDisk() {
        diskTask?.cancel()
        diskTask = Task { [weak self] in
            let response = try? await LurosService.app.storageUsage(areas: [], includeDisk: true)
            guard !Task.isCancelled, let self else { return }
            disk = response?.disk
            updateRows()
        }
    }

    // MARK: - Rows

    private func header(for section: Section) -> String? {
        switch section {
        case .disk: nil
        case .areas: String(localized: "On This Device")
        case .purgeable: String(localized: "Can Be Cleared")
        }
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .disk:
            String(localized: "Measured when this page opens, one folder at a time.")
        case .areas:
            String(localized: """
            A project and a conversation are deleted here for good, with their Git history and their \
            messages. An SDK and a toolchain are removed on their own pages.
            """)
        case .purgeable:
            String(localized: """
            Luros empties these folders itself. A build folder written in the last hour is left alone, in \
            case a build is still using it.
            """)
        }
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .disk: [.disk]
        case .areas: Self.areas.map(Row.area)
        case .purgeable: Self.purgeable.map(Row.purge) + [.purgeAll]
        }
    }

    private func updateRows() {
        dataSource.update(Section.allCases.map { section in
            (section, rows(in: section).map(content(for:)))
        }, reconfigure: true)
    }

    private func content(for row: Row) -> RowContent {
        switch row {
        case .disk:
            return RowContent(row: row, detail: diskText)
        case let .area(area):
            return RowContent(row: row, detail: text(for: area))
        case let .purge(area):
            return RowContent(row: row, detail: text(for: area))
        case .purgeAll:
            return RowContent(row: row, detail: purgeableText)
        }
    }

    private var diskText: String? {
        guard let disk else { return String(localized: "Reading…") }
        let available = ByteCountFormatter.string(fromByteCount: disk.available, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: disk.total, countStyle: .file)
        return String(localized: "\(available) available of \(total)")
    }

    /// What every purgeable area would give back, once each has been measured.
    private var purgeableText: String? {
        if let failed = Self.purgeable.first(where: { usage[$0]?.failure != nil }) {
            return "\(Self.name(of: failed)) — \(String(localized: "Unable to Read"))"
        }
        let measured = Self.purgeable.compactMap { usage[$0] }
        guard measured.count == Self.purgeable.count else { return String(localized: "Reading…") }
        let bytes = measured.reduce(Int64(0)) { $0 + $1.bytes }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// A measured area's size, or why it has none yet.
    private func text(for area: StorageArea) -> String {
        if let measured = usage[area] {
            guard measured.failure == nil else { return String(localized: "Unable to Read") }
            return Self.format(measured.bytes)
        }
        return measuring[area] == nil ? "" : String(localized: "Reading…")
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func name(of area: StorageArea) -> String {
        switch area {
        case .builds: String(localized: "Builds")
        case .temporary: String(localized: "Temporary Files")
        case .exports: String(localized: "Exports")
        case .logs: String(localized: "Logs")
        case .backups: String(localized: "Editing Backups")
        case .projects: String(localized: "Projects")
        case .chats: String(localized: "Conversations")
        case .sessions: String(localized: "Session Records")
        case .sdks: String(localized: "SDKs")
        case .toolchains: String(localized: "Toolchains")
        }
    }

    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "storage")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "storage")
        var configuration = UIListContentConfiguration.valueCell()
        configuration.secondaryText = value.detail
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        switch value.row {
        case .disk:
            configuration.text = String(localized: "Device Storage")
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case let .area(area):
            configuration.text = Self.name(of: area)
        case let .purge(area):
            configuration.text = Self.name(of: area)
            configuration.textProperties.color = .systemRed
        case .purgeAll:
            configuration.text = String(localized: "Clear Everything Above")
            configuration.textProperties.color = .systemRed
        }
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.value(at: indexPath)?.row else { return false }
        switch row {
        case .disk: return false
        case .area, .purge, .purgeAll: return !working
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        switch row {
        case .disk:
            break
        case let .area(area):
            open(area)
        case let .purge(area):
            confirmPurge([area])
        case .purgeAll:
            confirmPurge(Self.purgeable)
        }
    }

    // MARK: - The pages of the areas holding a model

    private var runtime: ChatRuntime? {
        (view.window?.rootViewController as? RootInterfaceController)?.conversations
    }

    private func open(_ area: StorageArea) {
        switch area {
        case .projects:
            guard let runtime else { return }
            push(StorageProjectsController(runtime: runtime))
        case .chats:
            guard let runtime else { return }
            push(StorageConversationsController(runtime: runtime))
        case .sessions:
            confirmClearSessions()
        case .sdks:
            push(SDKListController())
        case .toolchains:
            push(ToolchainController())
        case .builds, .temporary, .exports, .logs, .backups:
            break
        }
    }

    private func push(_ page: UIViewController) {
        navigationController?.pushViewController(page, animated: true)
    }

    /// A session holds where a conversation was in its work, not its answers:
    /// every conversation stays readable and loses only the ability to pick up
    /// where it was.
    private func confirmClearSessions() {
        guard !(runtime?.hasWorkingConversations ?? false) else {
            presentNotice(
                title: "A Conversation Is Running",
                message: "Wait for it to finish, then clear the session records.",
            )
            return
        }
        presentTextInput(
            title: "Clear Session Records?",
            message: """
            Every conversation stays and reads as it does now, but none of them can be continued where it \
            was: the next message starts its session again. Type DELETE to clear them.
            """,
            placeholder: "DELETE",
            doneTitle: "Clear",
        ) { [weak self] typed in
            guard typed == "DELETE" else { return }
            self?.clearSessions()
        }
    }

    private func clearSessions() {
        guard !working else { return }
        working = true
        let folder = DataFolder.app
        Task { [weak self] in
            let removed = await Task.detached { () -> Int in
                let sessions = folder.sessions
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessions.path) else { return 0 }
                var count = 0
                for name in names {
                    let url = sessions.appendingPathComponent(name, isDirectory: true)
                    try? FileManager.default.removeItem(at: url)
                    count += 1
                }
                return count
            }.value
            guard let self else { return }
            working = false
            if removed > 0 {
                SPIndicator.present(title: String(localized: "Cleared"), preset: .done, haptic: .success)
            }
            measure(.sessions, children: false)
        }
    }

    // MARK: - Emptying the folders no model indexes

    private func confirmPurge(_ areas: [StorageArea]) {
        guard !areas.isEmpty, !working else { return }
        let bytes = areas.compactMap { usage[$0]?.failure == nil ? usage[$0] : nil }
            .reduce(Int64(0)) { $0 + $1.bytes }
        let size = Self.format(bytes)
        if areas.count == 1, let area = areas.first {
            presentConfirmation(
                title: "Clear \(Self.name(of: area))?",
                message: "\(size) is deleted. Nothing else is touched.",
                confirmTitle: "Clear",
                destructive: true,
            ) { [weak self] in
                self?.purge(areas)
            }
            return
        }
        presentConfirmation(
            title: "Clear Everything Above?",
            message: "Builds, temporary files, exports, logs and backups go: \(size) in all.",
            confirmTitle: "Clear",
            destructive: true,
        ) { [weak self] in
            self?.purge(areas)
        }
    }

    private func purge(_ areas: [StorageArea]) {
        guard !working else { return }
        working = true
        Task { [weak self] in
            do {
                _ = try await LurosService.app.storagePurge(areas)
                guard let self else { return }
                working = false
                SPIndicator.present(title: String(localized: "Cleared"), preset: .done, haptic: .success)
                measureDisk()
                for area in areas {
                    measure(area, children: false)
                }
            } catch {
                guard let self else { return }
                working = false
                presentNotice(title: "Unable to Clear", message: error.readableMessage)
            }
        }
    }
}
