import ApelinCore
import ApelinProtocol
import SPIndicator
import Then
import UIKit

/// Settings ▸ Apps: every app under the bootstrap's `Applications` — the ones
/// Apelin installed from an `.ipa`, the ones a package owns, the ones another
/// tool put there — and the registrations LaunchServices still holds for a
/// bundle that is gone. A removable row is deleted with a trailing swipe,
/// after a confirmation: its registration first, then its files. The icon
/// stays on the Home Screen until SpringBoard restarts, so the page asks.
final class AppsController: TableController {
    private enum Row: Equatable {
        case app(ApplicationSummary)
        case empty
    }

    private lazy var dataSource = TableDataSource<String, String, Row>(
        tableView: tableView,
        identifier: { row in
            switch row {
            case let .app(app): "app:" + app.bundleID + "\u{1f}" + (app.path ?? "-")
            case .empty: "empty"
            }
        },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private var listing: [ApplicationSummary] = []
    private var loader: Task<Void, Never>?
    private var removing = false

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Apps")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.headerTitle = { _ in String(localized: "Installed") }
        dataSource.footerTitle = { _ in
            String(localized: """
            The apps under the bootstrap's Applications folder: what Apelin installed, what a package owns, \
            and registrations whose bundle is gone. An app iOS keeps in its own container is not listed.
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

    // MARK: - Reading

    @objc private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let response = try await ApelinService.app.applicationList()
                guard !Task.isCancelled, let self else { return }
                show(response.applications)
            } catch {
                guard !Task.isCancelled, let self else { return }
                refreshControl?.endRefreshing()
                if listing.isEmpty {
                    tableView.backgroundView = EmptyStateView(
                        symbolName: "exclamationmark.triangle",
                        title: String(localized: "Error"),
                        text: ToolchainController.unavailableText(error),
                    )
                }
            }
        }
    }

    private func show(_ apps: [ApplicationSummary]) {
        listing = apps
        refreshControl?.endRefreshing()
        tableView.backgroundView = nil
        dataSource.update([("apps", apps.isEmpty ? [.empty] : apps.map(Row.app))], reconfigure: true)
    }

    // MARK: - Rows

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "app")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "app")
        var content = UIListContentConfiguration.subtitleCell()
        switch row {
        case let .app(app):
            content.text = app.name
            content.textProperties.numberOfLines = 1
            content.secondaryText = [Self.describe(app), app.reason]
                .compactMap { $0 }
                .joined(separator: "\n")
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessoryType = .none
            cell.selectionStyle = .none
            // The cell draws both lines itself, so it is the one element.
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = app.name
            cell.accessibilityValue = [Self.describe(app), app.reason].compactMap { $0 }.joined(separator: ", ")
            cell.accessibilityTraits = .staticText
        case .empty:
            content.text = String(localized: "No apps")
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
        }
        cell.contentConfiguration = content
        return cell
    }

    /// One line under the name: where it came from, its identifier and its
    /// version.
    private static func describe(_ app: ApplicationSummary) -> String {
        let source: String = if app.path == nil {
            String(localized: "Registration only")
        } else {
            switch app.source {
            case .apelin: String(localized: "Installed by Apelin")
            case .package: String(localized: "From a package")
            case .other: String(localized: "Added by another tool")
            }
        }
        return [source, app.bundleID, app.version.isEmpty ? nil : app.version]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        false
    }

    // MARK: - Removing

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard case let .app(app)? = dataSource.value(at: indexPath), app.removable else { return nil }
        let remove = UIContextualAction(
            style: .destructive,
            title: String(localized: "Remove"),
        ) { [weak self] _, _, completion in
            // the row goes when the list is read again
            completion(false)
            self?.confirmRemoval(of: app)
        }
        remove.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [remove])
    }

    private func confirmRemoval(of app: ApplicationSummary) {
        if let path = app.path {
            presentConfirmation(
                title: "Remove \(app.name)?",
                message: "Its bundle at \(path) is deleted from the device, and its registration removed.",
                confirmTitle: "Remove",
                destructive: true,
            ) { [weak self] in
                self?.remove(app)
            }
        } else {
            presentConfirmation(
                title: "Forget \(app.name)?",
                message: """
                LaunchServices still registers it at \(app.registeredPath ?? "") where nothing is left. Only the \
                registration is removed.
                """,
                confirmTitle: "Remove",
                destructive: true,
            ) { [weak self] in
                self?.remove(app)
            }
        }
    }

    private func remove(_ app: ApplicationSummary) {
        guard !removing else { return }
        removing = true
        Task { [weak self] in
            do {
                try await ApelinService.app.applicationRemove(bundleID: app.bundleID, path: app.path)
                guard let self else { return }
                removing = false
                SPIndicator.present(title: String(localized: "Removed"), preset: .done, haptic: .success)
                load()
                askToRestart()
            } catch {
                guard let self else { return }
                removing = false
                presentNotice(title: "Unable to Remove App", message: error.readableMessage)
            }
        }
    }

    /// The bundle is gone but its icon is not: SpringBoard holds it until it
    /// restarts.
    private func askToRestart() {
        presentConfirmation(
            title: "Restart the Home Screen?",
            message: "The icon stays until SpringBoard restarts.",
            cancelTitle: "Later",
            confirmTitle: "Restart",
        ) {
            Task { try? await ApelinService.app.respring() }
        }
    }
}
