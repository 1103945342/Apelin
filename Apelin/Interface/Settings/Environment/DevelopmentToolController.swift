import ApelinProtocol
import UIKit

/// Settings ▸ Environment ▸ Third-Party Tools: the four programs Apelin's own
/// work needs — `ldid`, `git`, `dpkg-deb`, `uicache` — whether the device has
/// each one, and a way to install a missing one from the repositories it
/// already has. Nothing here parses a repository signature: the index is
/// trusted as the last `apt update` left it.
final class DevelopmentToolController: UITableViewController {
    private var rows: [DevelopmentToolRow] = []
    private var reading = true
    private var installing: String?
    private var task: Task<Void, Never>?

    init() {
        super.init(style: .insetGrouped)
        title = String(localized: "Third-Party Tools")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "tool")
        load()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        task?.cancel()
    }

    // MARK: - Reading

    private func load() {
        task?.cancel()
        reading = true
        tableView.reloadData()
        task = Task { [weak self] in
            let response = try? await ApelinService.app.developmentTools(DevelopmentToolsRequest())
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                rows = response?.tools ?? []
                reading = false
                tableView.reloadData()
            }
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "A missing tool installs from the repositories already on the device, with everything it needs.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "tool", for: indexPath)
        let row = rows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = row.id
        if let version = row.version {
            content.secondaryText = String(localized: "Installed") + " · " + version
        } else {
            content.secondaryText = reading ? nil : String(localized: "Not Installed")
        }
        cell.contentConfiguration = content
        if installing == row.id {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        } else {
            cell.accessoryView = nil
            cell.accessoryType = row.present ? .none : .disclosureIndicator
        }
        cell.selectionStyle = row.present || installing != nil ? .none : .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.row]
        guard !row.present, installing == nil else { return }
        confirm(row)
    }

    // MARK: - Installing

    /// What installing would add, then a question, then the install itself.
    private func confirm(_ row: DevelopmentToolRow) {
        installing = row.id
        tableView.reloadData()
        task = Task { [weak self] in
            let plan = try? await ApelinService.app.developmentTools(
                DevelopmentToolsRequest(install: row.id, dryRun: true),
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                installing = nil
                tableView.reloadData()
                guard let plan else {
                    presentFailure(String(localized: "The repositories on this device could not say what \(row.id) needs."), title: row.id)
                    return
                }
                if let failure = plan.failure {
                    presentFailure(failure, title: row.id)
                    return
                }
                guard !plan.packages.isEmpty else {
                    presentFailure(String(localized: "Nothing to install: the device already has \(row.id)."), title: row.id)
                    return
                }
                ask(row, adding: plan.packages)
            }
        }
    }

    private func ask(_ row: DevelopmentToolRow, adding packages: [String]) {
        let title = String(format: String(localized: "Install %@?"), row.id)
        let message = String(format: String(localized: "This adds: %@"), packages.joined(separator: ", "))
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Install"), style: .default) { [weak self] _ in
            self?.install(row)
        })
        present(alert, animated: true)
    }

    private func install(_ row: DevelopmentToolRow) {
        installing = row.id
        tableView.reloadData()
        task = Task { [weak self] in
            let response = try? await ApelinService.app.developmentTools(DevelopmentToolsRequest(install: row.id))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                installing = nil
                if let response {
                    rows = response.tools
                }
                tableView.reloadData()
                if let failure = response?.failure {
                    presentFailure(failure, title: row.id)
                }
            }
        }
    }

    private func presentFailure(_ message: String, title: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}
