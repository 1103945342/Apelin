import ApelinCore
import UIKit

/// The conversation's todo list, folded above the composer: what the agent
/// means to do, what it is doing, and what it has done.
///
/// Read from the store the agent writes, not from the events: a list that
/// arrived as a tool result would be missing anything the agent wrote before
/// the app opened, and the panel is worth more as the whole list than as the
/// last change to it.
final class ComposerTodoPanel: ComposerPanel {
    private let stack = UIStackView()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let summaryLabel = UILabel()

    private var list = TodoList()

    private var rowHeight: CGFloat {
        max(22, UIFont.preferredFont(forTextStyle: .footnote).lineHeight + ComposerMetrics.Spacing.xs)
    }

    override func initializeViews() {
        super.initializeViews()

        setCollapsible(true)
        collapseAction = { [weak self] in self?.setExpanded(false) }

        progressTrack.backgroundColor = UIColor.tertiarySystemFill
        progressTrack.layer.cornerRadius = 2
        progressTrack.layer.cornerCurve = .continuous
        progressTrack.clipsToBounds = true
        body.addSubview(progressTrack)
        progressFill.backgroundColor = .systemGreen
        progressFill.layer.cornerRadius = 2
        progressFill.layer.cornerCurve = .continuous
        progressTrack.addSubview(progressFill)

        summaryLabel.font = .preferredFont(forTextStyle: .caption2)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textColor = .secondaryLabel
        body.addSubview(summaryLabel)

        stack.axis = .vertical
        stack.spacing = ComposerMetrics.Spacing.xs
        stack.alignment = .fill
        body.addSubview(stack)

        updateSubtitle()
    }

    /// The list as the store has it. Read when the conversation moves, so an
    /// agent that changed the list while the app was elsewhere is seen when the
    /// page comes back.
    func show(_ list: TodoList) {
        guard list.items != self.list.items else { return }
        self.list = list
        rebuild()
        updateSubtitle()
        heightPublisher.send(isExpanded ? preferredHeight : 0)
        setNeedsLayout()
    }

    private func updateSubtitle() {
        let total = list.items.count
        let done = list.completed.count
        setTitle(String(localized: "To Do"))
        summaryLabel.text = total == 0
            ? String(localized: "Nothing planned")
            : String(localized: "\(done) of \(total) done")
        summaryLabel.isHidden = total == 0
    }

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for item in list.items {
            let row = TodoRow()
            row.show(item)
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            stack.addArrangedSubview(row)
        }
    }

    override var preferredHeight: CGFloat {
        let rows = CGFloat(list.items.count) * (rowHeight + ComposerMetrics.Spacing.xs)
        let shown = min(rows, ComposerMetrics.Panel.maxBodyHeight)
        let progressRoom: CGFloat = list.items.isEmpty ? 0 : 10
        return ComposerMetrics.Spacing.sm
            + headerHeight
            + progressRoom
            + shown
            + ComposerMetrics.Spacing.sm
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = body.frame.width
        var y = body.frame.minY

        if !list.items.isEmpty {
            progressTrack.frame = CGRect(x: 0, y: y + 2, width: width, height: 4)
            let fraction = list.fraction ?? 0
            progressFill.frame = CGRect(x: 0, y: 0, width: width * fraction, height: 4)
            y = progressTrack.frame.maxY + ComposerMetrics.Spacing.sm
        }

        stack.frame = CGRect(
            x: body.frame.minX,
            y: y,
            width: width,
            height: min(max(0, body.frame.maxY - y), ComposerMetrics.Panel.maxBodyHeight)
        )
    }
}

/// One item: a mark for where it stands, then what it says.
private final class TodoRow: UIView {
    private let markView = UIImageView()
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        markView.contentMode = .scaleAspectFit
        markView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(scale: .small)
        markView.setContentHuggingPriority(.required, for: .horizontal)
        markView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .footnote)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        for view in [markView, titleLabel] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ item: TodoRecord) {
        let symbol: String
        switch item.status {
        case .pending: symbol = "circle"
        // `circle.lefthalf.filled` is newer than this app's floor; a clock says
        // "under way" with a mark that has been there since iOS 13.
        case .inProgress: symbol = "clock"
        case .completed: symbol = "checkmark.circle.fill"
        case .blocked: symbol = "xmark.circle"
        }
        markView.image = UIImage(systemName: symbol)
        markView.tintColor = colour(for: item.status)
        titleLabel.text = item.title
        titleLabel.textColor = item.status == .completed ? .secondaryLabel : .label
        // The mark is a state drawn, never read: the label says what it means.
        accessibilityLabel = "\(spoken(item.status)), \(item.title)"
        setNeedsLayout()
    }

    private func colour(for status: TodoStatus) -> UIColor {
        switch status {
        case .pending: .tertiaryLabel
        case .inProgress: .systemBlue
        case .completed: .systemGreen
        case .blocked: .systemRed
        }
    }

    private func spoken(_ status: TodoStatus) -> String {
        switch status {
        case .pending: String(localized: "Not started")
        case .inProgress: String(localized: "In progress")
        case .completed: String(localized: "Done")
        case .blocked: String(localized: "Blocked")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let markSize = max(14, titleLabel.font.lineHeight * 0.8)
        markView.frame = CGRect(
            x: 0,
            y: (bounds.height - markSize) / 2,
            width: markSize,
            height: markSize
        )
        titleLabel.frame = directionalFrame(CGRect(
            x: markSize + ComposerMetrics.Spacing.sm,
            y: 0,
            width: max(0, bounds.width - markSize - ComposerMetrics.Spacing.sm),
            height: bounds.height
        ))
    }
}
