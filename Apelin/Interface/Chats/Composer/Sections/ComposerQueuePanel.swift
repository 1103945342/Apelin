import UIKit

/// The messages waiting their turn: sent while a run was going, taken at its
/// next step. Above the composer, folded by a tap.
///
/// The queue is the session's, not the composer's: the host holds it and says
/// what is in it, so this panel reads and never writes. Reordering or dropping
/// one here would be a promise the app cannot keep — the list would come back
/// from the next event as the host had it.
final class ComposerQueuePanel: ComposerPanel {
    private let stack = UIStackView()
    private var messages: [ChatMessage] = []

    private var rowHeight: CGFloat {
        max(20, UIFont.preferredFont(forTextStyle: .footnote).lineHeight + ComposerMetrics.Spacing.xs)
    }

    override func initializeViews() {
        super.initializeViews()

        stack.axis = .vertical
        stack.spacing = ComposerMetrics.Spacing.xs
        stack.alignment = .fill
        body.addSubview(stack)

        setCollapsible(true)
        collapseAction = { [weak self] in self?.setExpanded(false) }
        updateTitle()
    }

    func show(_ queued: [ChatMessage]) {
        guard queued.map(\.id) != messages.map(\.id) else { return }
        messages = queued
        rebuild()
        updateTitle()
        heightPublisher.send(isExpanded ? preferredHeight : 0)
        setNeedsLayout()
    }

    private func updateTitle() {
        let count = messages.count
        setTitle(
            count == 1
                ? String(localized: "1 Message Waiting")
                : String(localized: "\(count) Messages Waiting")
        )
    }

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, message) in messages.enumerated() {
            let row = QueueRow()
            row.show(message, number: index + 1)
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            stack.addArrangedSubview(row)
        }
    }

    override var preferredHeight: CGFloat {
        let rows = CGFloat(messages.count) * (rowHeight + ComposerMetrics.Spacing.xs)
        let shown = min(rows, ComposerMetrics.Panel.maxQueueHeight)
        return ComposerMetrics.Spacing.sm
            + headerHeight
            + shown
            + ComposerMetrics.Spacing.sm
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        stack.frame = CGRect(
            x: body.frame.minX,
            y: body.frame.minY,
            width: body.frame.width,
            height: min(body.frame.height, ComposerMetrics.Panel.maxQueueHeight)
        )
    }
}

/// One waiting message: its place in the queue, then what it says.
private final class QueueRow: UIView {
    private let numberLabel = UILabel()
    private let textLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        numberLabel.font = .preferredFont(forTextStyle: .footnote)
        numberLabel.adjustsFontForContentSizeCategory = true
        numberLabel.textColor = .tintColor
        numberLabel.setContentHuggingPriority(.required, for: .horizontal)
        numberLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textLabel.font = .preferredFont(forTextStyle: .footnote)
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.textColor = .secondaryLabel
        textLabel.numberOfLines = 1
        textLabel.lineBreakMode = .byTruncatingTail

        for label in [numberLabel, textLabel] {
            label.isUserInteractionEnabled = false
            addSubview(label)
        }

        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ message: ChatMessage, number: Int) {
        numberLabel.text = "\(number)"
        textLabel.text = message.text
        accessibilityLabel = String(localized: "Waiting message \(number): \(message.text)")
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let numberWidth = numberLabel.intrinsicContentSize.width
        numberLabel.frame = CGRect(x: 0, y: 0, width: numberWidth, height: bounds.height)
        textLabel.frame = directionalFrame(CGRect(
            x: numberWidth + ComposerMetrics.Spacing.sm,
            y: 0,
            width: max(0, bounds.width - numberWidth - ComposerMetrics.Spacing.sm),
            height: bounds.height
        ))
    }
}
