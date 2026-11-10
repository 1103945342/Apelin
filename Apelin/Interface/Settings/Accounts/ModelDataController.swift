import ApelinCore
import UIKit

/// models.dev's catalog as this device keeps it: how many models the copy
/// names, when it was written, and the two things the user can do to it. A
/// conversation reads a model it has never heard of against this copy, and the
/// catalog Apelin ships when there is none.
final class ModelDataController: TableController {
    private enum Section: Hashable { case copy, actions }
    private enum Row: Hashable { case models, updated, update, delete }

    private struct Line: Equatable {
        let row: Row
        let text: String
        let detail: String?
        var busy = false
    }

    /// The copy on this device, once read: nil is no copy, or one that does
    /// not read.
    private var snapshot: ModelDataSnapshot?
    private var readCopy = false
    private var busy = false
    private var loader: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?

    private lazy var dataSource = TableDataSource<Section, Row, Line>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] _, _, line in
        guard let self else { return nil }
        switch line.row {
        case .update:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = line.text
            content.textProperties.color = line.busy ? .secondaryLabel : cell.tintColor
            cell.contentConfiguration = content
            cell.selectionStyle = line.busy ? .none : .default
            cell.accessoryView = line.busy ? self.spinner() : nil
            return cell
        case .delete:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = line.text
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
            return cell
        case .models, .updated:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = line.text
            content.secondaryText = line.detail
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
    }

    /// The row's own answer to a press in progress: a spinner nobody can
    /// press twice.
    private func spinner() -> UIView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.accessibilityLabel = String(localized: "Updating")
        return spinner
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model Data")
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        dataSource.footerTitle = { [weak self] section in
            switch section {
            case .copy:
                return String(localized: "models.dev’s catalog, trimmed to the figures Apelin reads and kept on this device, so a conversation reaches the network for neither.")
            case .actions:
                return self?.snapshot == nil
                    ? String(localized: "Download the copy to read models the catalog Apelin ships does not name.")
                    : String(localized: "Updating replaces the copy with models.dev’s current catalog. Deleting it leaves every conversation reading the catalog Apelin ships.")
            }
        }
        apply()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        loader?.cancel()
        let url = DataFolder.app.modelDataFile
        loader = Task { [weak self] in
            let snapshot = await Task.detached { ModelDataSnapshot.read(url) }.value
            guard !Task.isCancelled, let self else { return }
            self.snapshot = snapshot
            readCopy = true
            apply()
        }
    }

    private func apply() {
        let count = snapshot?.count
        let models = Line(
            row: .models,
            text: String(localized: "Models"),
            detail: !readCopy
                ? String(localized: "Reading…")
                : count.map { $0.formatted() } ?? String(localized: "Not Downloaded"),
        )
        let updated = Line(
            row: .updated,
            text: String(localized: "Updated"),
            detail: snapshot?.generatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—",
        )
        var copy = [models]
        if count != nil {
            copy.append(updated)
        }
        var actions = [Line(
            row: .update,
            text: String(localized: "Update Now"),
            detail: nil,
            busy: busy,
        )]
        if count != nil {
            actions.append(Line(row: .delete, text: String(localized: "Delete Copy"), detail: nil))
        }
        dataSource.update([(.copy, copy), (.actions, actions)], reconfigure: true)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row, !busy else { return }
        switch row {
        case .update: download()
        case .delete: confirmDelete()
        case .models, .updated: break
        }
    }

    private func download() {
        busy = true
        apply()
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            do {
                var request = URLRequest(url: ModelDataSnapshot.remoteURL)
                request.timeoutInterval = 120
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CocoaError(.fileReadUnknown) }
                let url = DataFolder.app.modelDataFile
                let snapshot = try await Task.detached { try ModelDataSnapshot.parse(modelsDev: data) }.value
                try await Task.detached { try snapshot.write(to: url) }.value
                guard let self else { return }
                adopt(snapshot)
            } catch {
                guard let self else { return }
                busy = false
                apply()
                guard !Task.isCancelled else { return }
                presentNotice(
                    title: "Unable to Update",
                    message: "models.dev’s catalog didn’t download. Check your connection and try again.",
                )
            }
        }
    }

    private func adopt(_ value: ModelDataSnapshot) {
        snapshot = value
        readCopy = true
        busy = false
        apply()
    }

    private func confirmDelete() {
        presentConfirmation(
            title: "Delete Model Data",
            message: "The copy on this device is removed and every conversation reads the catalog Apelin ships instead.",
            confirmTitle: "Delete",
            destructive: true,
        ) { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.removeItem(at: DataFolder.app.modelDataFile)
                snapshot = nil
                readCopy = true
                apply()
            } catch {
                presentNotice(title: "Unable to Delete", message: "The copy is still on this device.")
            }
        }
    }
}
