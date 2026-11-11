import ApelinCore
import UIKit

/// Settings ▸ Agent ▸ Prompt Injection: the switch, and the text every
/// conversation opened from here on carries before the rest of its prompt.
/// Both save as they change — there is nothing to confirm, and a page that
/// asked for a Save button would keep a half-typed prompt out of the next
/// chat.
final class PromptInjectionController: TableController, UITextViewDelegate {
    private enum Row: Equatable {
        case enabled
        case text
    }

    private lazy var dataSource = TableDataSource<Int, String, Row>(
        tableView: tableView,
        identifier: { row in
            switch row {
            case .enabled: "enabled"
            case .text: "text"
            }
        },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private let switchView = UISwitch()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private lazy var textCell = fieldCell(textView, minimumHeight: 220)

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Prompt Injection")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.keyboardDismissMode = .interactive
        switchView.isOn = Preferences.PromptInjection.enabled
        switchView.accessibilityLabel = String(localized: "Prompt Injection")
        switchView.addAction(
            UIAction { [weak self] _ in self?.switchChanged() },
            for: .valueChanged,
        )
        textView.text = Preferences.PromptInjection.text
        textView.accessibilityLabel = String(localized: "Injected Prompt")
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        placeholder.text = String(localized: "What should every conversation be told first?")
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0
        placeholder.isAccessibilityElement = false
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: textView.frameLayoutGuide.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: textView.frameLayoutGuide.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: textView.frameLayoutGuide.topAnchor),
        ])
        dataSource.headerTitle = { _ in nil }
        dataSource.footerTitle = { _ in
            String(localized: """
            This text goes at the top of the system prompt, before everything else, for every conversation \
            opened from now on. The switch turns it off without losing what you wrote.
            """)
        }
        dataSource.update([(0, [.enabled, .text])])
        updatePlaceholder()
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        switch row {
        case .enabled:
            let cell = tableView.dequeueReusableCell(withIdentifier: "switch")
                ?? UITableViewCell(style: .default, reuseIdentifier: "switch")
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Enabled")
            cell.contentConfiguration = content
            cell.accessoryView = switchView
            cell.selectionStyle = .none
            return cell
        case .text:
            return textCell
        }
    }

    private func fieldCell(_ field: UIView, minimumHeight: CGFloat) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            field.topAnchor.constraint(equalTo: margins.topAnchor),
            field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight),
        ])
        return cell
    }

    @objc private dynamic func switchChanged() {
        Preferences.PromptInjection.enabled = switchView.isOn
    }

    @objc dynamic func textViewDidChange(_: UITextView) {
        Preferences.PromptInjection.text = textView.text
        updatePlaceholder()
        // The cell's height follows the text it holds.
        tableView.beginUpdates()
        tableView.endUpdates()
    }

    @objc private dynamic func updatePlaceholder() {
        placeholder.isHidden = !textView.text.isEmpty
        textView.accessibilityHint = placeholder.isHidden ? nil : placeholder.text
    }
}
