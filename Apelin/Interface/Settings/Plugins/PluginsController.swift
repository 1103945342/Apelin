import UIKit

/// Settings ▸ Plugins: what connects something outside Apelin to an agent on
/// this device. One plugin so far, WeChat's ClawBot, and its page is where it
/// is signed in and turned on. The list answers no request of its own, so
/// opening Settings never starts a bot.
final class PluginsController: TableController {
    private enum Section: Hashable {
        case plugins
    }

    private enum Row: Hashable {
        case wechat
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
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
        title = String(localized: "Plugins")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.footerTitle = { _ in
            String(localized: "Plugins connect something outside Apelin, a chat app today, to an agent on this device.")
        }
        dataSource.update([(.plugins, [.wechat])])
    }

    private func cell(in tableView: UITableView, row _: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "plugin")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "plugin")
        var content = UIListContentConfiguration.valueCell()
        content.text = String(localized: "WeChat ClawBot")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case .wechat:
            navigationController?.pushViewController(ClawBotController(), animated: true)
        }
    }
}
