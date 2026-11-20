import LurosProtocol
import UIKit

/// Settings ▸ Environment ▸ Third-Party Tools: the four packages Luros's own
/// work needs — `ldid`, `git`, `dpkg-deb` and `uikittools` (whose `uicache`
/// registers a built app) — and whether this device has each one.
///
/// Nothing installs from here: a missing package is the user's package
/// manager's, so the row offers to open that package's page and leaves the
/// decision there.
final class DevelopmentToolController: UITableViewController {
    private var rows: [DevelopmentToolRow] = []
    private var reading = true
    private var task: Task<Void, Never>?

    /// Tried in order: Sileo on most devices, Irisin where that is the
    /// bootstrap's own manager.
    private static let openers = ["sileo", "irisin"]

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
            let response = try? await LurosService.app.developmentTools()
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
        String(localized: "A missing tool is installed from your package manager.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "tool", for: indexPath)
        let row = rows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = row.packageID
        if let version = row.version {
            content.secondaryText = String(localized: "Installed") + " · " + version
        } else {
            content.secondaryText = reading ? nil : String(localized: "Not Installed")
        }
        cell.contentConfiguration = content
        cell.accessoryType = row.present ? .none : .disclosureIndicator
        cell.selectionStyle = row.present ? .none : .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.row]
        guard !row.present else { return }
        ask(row)
    }

    // MARK: - Opening the package's page

    private func ask(_ row: DevelopmentToolRow) {
        let title = row.packageID
        let message = String(format: String(localized: "Install %@ from your package manager."), row.packageID)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Open Sileo"), style: .default) { [weak self] _ in
            self?.open(package: row.packageID, trying: Self.openers)
        })
        present(alert, animated: true)
    }

    private func open(package id: String, trying schemes: [String]) {
        guard let scheme = schemes.first, let url = URL(string: "\(scheme)://package/\(id)") else {
            reportNoManager()
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in self?.open(package: id, trying: Array(schemes.dropFirst())) }
        }
    }

    private func reportNoManager() {
        let alert = UIAlertController(
            title: String(localized: "Third-Party Tools"),
            message: String(localized: "No package manager is installed on this device."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "Close"), style: .default))
        present(alert, animated: true)
    }
}
