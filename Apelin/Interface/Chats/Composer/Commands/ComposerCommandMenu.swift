import UIKit

/// The list that opens on a leading slash: what can be run, filtered by what
/// has been typed, one row each. A skill says so, since the same name shape
/// comes from two places and only one of them is a skill.
final class ComposerCommandMenu: UIView {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private(set) var commands: [ComposerCommand] = []

    /// Chosen by tap: the row's own name.
    var onPick: ((ComposerCommand) -> Void)?

    private let rowHeight: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        let glass = GlassSurfaceView(cornerRadius: ComposerMetrics.Radius.lg)
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)
        layer.cornerRadius = ComposerMetrics.Radius.lg
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor
        clipsToBounds = true

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorInset = UIEdgeInsets(
            top: 0, left: ComposerMetrics.Spacing.md, bottom: 0, right: 0,
        )
        tableView.rowHeight = rowHeight
        tableView.register(CommandCell.self, forCellReuseIdentifier: "command")
        tableView.keyboardDismissMode = .none
        addSubview(tableView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ commands: [ComposerCommand]) {
        let changed = commands.map(\.id) != self.commands.map(\.id)
        self.commands = commands
        if changed {
            tableView.reloadData()
        }
        isHidden = commands.isEmpty
        setNeedsLayout()
    }

    /// As tall as the rows, up to a limit past which it scrolls.
    var preferredHeight: CGFloat {
        guard !commands.isEmpty else { return 0 }
        let rows = CGFloat(min(commands.count, 4)) * rowHeight
        return rows + ComposerMetrics.Spacing.xs * 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tableView.frame = bounds.insetBy(dx: 0, dy: ComposerMetrics.Spacing.xs)
    }
}

extension ComposerCommandMenu: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        commands.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "command", for: indexPath)
        guard let cell = cell as? CommandCell else { return cell }
        cell.show(commands[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard commands.indices.contains(indexPath.row) else { return }
        onPick?(commands[indexPath.row])
    }
}

private final class CommandCell: UITableViewCell {
    private let nameLabel = UILabel()
    private let summaryLabel = UILabel()
    private let kindLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .default

        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .tintColor
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        summaryLabel.font = .preferredFont(forTextStyle: .caption1)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.lineBreakMode = .byTruncatingTail

        kindLabel.font = .preferredFont(forTextStyle: .caption2)
        kindLabel.adjustsFontForContentSizeCategory = true
        kindLabel.textColor = .tintColor

        for label in [nameLabel, summaryLabel, kindLabel] {
            label.isUserInteractionEnabled = false
            contentView.addSubview(label)
        }
        // The cell joins three labels into one sentence, which UIKit only reads
        // when the cell is the element; a cell it does not treat as one is
        // walked past and its subviews read instead.
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:reuseIdentifier:)")
    }

    func show(_ command: ComposerCommand) {
        nameLabel.text = command.display
        summaryLabel.text = command.summary
        kindLabel.text = command.kind == .skill ? String(localized: "Skill") : nil
        kindLabel.isHidden = command.kind != .skill
        let kind = command.kind == .skill ? String(localized: "Skill") : String(localized: "Command")
        accessibilityLabel = [command.display, command.summary, kind].joined(separator: ", ")
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let inset = ComposerMetrics.Spacing.md
        let kindWidth = kindLabel.isHidden ? 0 : kindLabel.intrinsicContentSize.width
        let kindRoom = kindLabel.isHidden ? 0 : kindWidth + ComposerMetrics.Spacing.sm

        nameLabel.frame = CGRect(
            x: inset,
            y: 6,
            width: max(0, contentView.bounds.width - inset * 2 - kindRoom),
            height: nameLabel.font.lineHeight,
        )
        kindLabel.frame = directionalFrame(CGRect(
            x: contentView.bounds.width - inset - kindWidth,
            y: nameLabel.frame.minY,
            width: kindWidth,
            height: nameLabel.font.lineHeight,
        ))
        summaryLabel.frame = CGRect(
            x: inset,
            y: nameLabel.frame.maxY + 2,
            width: max(0, contentView.bounds.width - inset * 2),
            height: summaryLabel.font.lineHeight,
        )
    }
}
