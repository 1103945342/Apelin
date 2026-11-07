import UIKit

/// The files behind an `@`, filtered by what has been typed, one row each.
/// Paths are shown relative to the project, which is how they are written into
/// the message.
final class ComposerMentionMenu: UIView {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private(set) var state: ComposerMentionState = .idle

    var onPick: ((String) -> Void)?

    private let rowHeight: CGFloat = 36

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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "mention")
        addSubview(tableView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ state: ComposerMentionState) {
        let changed = !sameRows(state, self.state)
        self.state = state
        if changed {
            tableView.reloadData()
        }
        isHidden = preferredHeight == 0
        setNeedsLayout()
    }

    private func sameRows(_ lhs: ComposerMentionState, _ rhs: ComposerMentionState) -> Bool {
        switch (lhs, rhs) {
        case let (.ready(a), .ready(b)): a == b
        case (.loading, .loading), (.unavailable, .unavailable), (.idle, .idle): true
        case let (.failed(a), .failed(b)): a == b
        default: false
        }
    }

    /// The rows on offer; one row for a sentence when there is nothing to pick.
    private var rows: [String] {
        switch state {
        case .idle: []
        case .loading: [String(localized: "Reading the project…")]
        case let .ready(files): files
        case .unavailable: [String(localized: "This conversation has no project")]
        case let .failed(message): [message]
        }
    }

    private var isPickable: Bool {
        if case .ready = state { return true }
        return false
    }

    var preferredHeight: CGFloat {
        let count = rows.count
        guard count > 0 else { return 0 }
        return CGFloat(min(count, 5)) * rowHeight + ComposerMetrics.Spacing.xs * 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tableView.frame = bounds.insetBy(dx: 0, dy: ComposerMetrics.Spacing.xs)
    }
}

extension ComposerMentionMenu: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "mention", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = rows[indexPath.row]
        content.textProperties.font = .preferredFont(forTextStyle: .footnote)
        content.textProperties.color = isPickable ? .label : .secondaryLabel
        content.textProperties.numberOfLines = 1
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        cell.contentConfiguration = content
        cell.selectionStyle = isPickable ? .default : .none
        cell.accessibilityLabel = content.text
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard isPickable, rows.indices.contains(indexPath.row) else { return }
        onPick?(rows[indexPath.row])
    }
}
