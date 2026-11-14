import UIKit

/// A page of answers with the one in use ticked, pushed as every setting here
/// is; the page stays open after a tap so the reader sees what they picked.
///
/// It is this folder's own copy of the shape `SettingChoiceController` has:
/// that one is private to SettingsViewController.swift and cannot be reached
/// from here.
final class ClawBotChoiceController: TableController {
    private enum Section: Hashable {
        case options
    }

    private struct Row: Equatable {
        let index: Int
        let title: String
        let selected: Bool
    }

    private let titles: [String]
    private let footerText: String?
    private let choose: (Int) -> Void
    private var selected: Int

    private lazy var dataSource = TableDataSource<Section, Int, Row>(
        tableView: tableView,
        identifier: { $0.index },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    init(
        title: String,
        options: [String],
        selected: Int,
        footer: String? = nil,
        choose: @escaping (Int) -> Void,
    ) {
        titles = options
        self.selected = selected
        footerText = footer
        self.choose = choose
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:options:selected:footer:choose:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.footerTitle = { [weak self] _ in self?.footerText }
        updateRows()
    }

    @objc private dynamic func updateRows() {
        dataSource.update([(.options, titles.enumerated().map { index, title in
            Row(index: index, title: title, selected: index == selected)
        })], reconfigure: true)
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clawbot-choice")
            ?? UITableViewCell(style: .default, reuseIdentifier: "clawbot-choice")
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        cell.contentConfiguration = content
        // The tick is drawn, the trait is what VoiceOver says.
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
