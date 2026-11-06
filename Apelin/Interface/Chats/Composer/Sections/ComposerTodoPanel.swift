import ApelinCore
import UIKit

/// The conversation's to-do list above the composer, as aimini's
/// `TodoDashboardBar` has it: shown only while the agent keeps a list for
/// this chat, folded to one line by default (a checklist mark, "To Do", how
/// many are done, the item under way), opened by a tap on that line to the
/// whole list, and put away with its ✕ until the agent writes a new list.
///
/// Read from the store the agent writes, not from the events: a list that
/// arrived as a tool result would be missing anything the agent wrote before
/// the app opened, and the panel is worth more as the whole list than as the
/// last change to it.
final class ComposerTodoPanel: ComposerPanel {
    /// The ✕ was tapped: the controller asks, then hides this list.
    var onHide: (() -> Void)?

    private let summary = UIControl()
    private let checkMark = UIImageView()
    private let nameLabel = UILabel()
    private let badge = UILabel()
    private let currentLabel = UILabel()
    private let fold = UIImageView()
    private let hideButton = UIButton(type: .system)
    private let scroll = UIScrollView()
    private var rows: [TodoRow] = []

    private var list = TodoList()
    private var sessionID: String?
    /// The chats whose list the reader left open, so coming back to one finds
    /// it as it was; a chat starts folded.
    private var openSessions: Set<String> = []
    /// Typing or answering a request: the list folds out of the way, and a tap
    /// on its line still opens it.
    private var isHeldFolded = false

    private static var summaryFont: UIFont { .preferredFont(forTextStyle: .footnote) }

    override func initializeViews() {
        super.initializeViews()
        // The panel draws its own line in place of the base header: it stays
        // when folded, and carries the count, the current item and the ✕.
        setHeaderless()

        checkMark.image = UIImage(systemName: "checklist")
        checkMark.tintColor = .tintColor
        checkMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        checkMark.contentMode = .center

        nameLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .bold))
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.text = String(localized: "To Do")
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        badge.font = .preferredFont(forTextStyle: .caption2)
        badge.adjustsFontForContentSizeCategory = true
        badge.textAlignment = .center
        badge.layer.cornerRadius = 4
        badge.layer.cornerCurve = .continuous
        badge.clipsToBounds = true

        currentLabel.font = .preferredFont(forTextStyle: .caption1)
        currentLabel.adjustsFontForContentSizeCategory = true
        currentLabel.textColor = .secondaryLabel
        currentLabel.lineBreakMode = .byTruncatingTail

        fold.image = UIImage(systemName: "chevron.down")
        fold.tintColor = .secondaryLabel
        fold.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        fold.contentMode = .center

        for view in [checkMark, nameLabel, badge, currentLabel, fold] as [UIView] {
            view.isUserInteractionEnabled = false
            summary.addSubview(view)
        }
        summary.isAccessibilityElement = true
        summary.accessibilityTraits = .button
        summary.accessibilityLabel = String(localized: "To Do")
        summary.addTarget(self, action: #selector(summaryTapped), for: .primaryActionTriggered)
        addSubview(summary)

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        configuration.baseForegroundColor = .secondaryLabel
        configuration.contentInsets = .zero
        hideButton.configuration = configuration
        hideButton.accessibilityLabel = String(localized: "Hide To-Do List")
        hideButton.addAction(UIAction { [weak self] _ in self?.onHide?() }, for: .touchUpInside)
        addSubview(hideButton)

        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        body.addSubview(scroll)

        collapseAction = { [weak self] in self?.close() }
    }

    /// `list` as the store has it for `sessionID`: read whenever the
    /// conversation moves, so a list the agent changed while the app was
    /// elsewhere is seen when the page comes back. An empty list takes the
    /// panel away.
    func show(_ list: TodoList, for sessionID: String?) {
        let movedChat = sessionID != self.sessionID
        guard movedChat || list.items != self.list.items else { return }
        let wasAllDone = self.list.isAllDone
        self.sessionID = sessionID
        self.list = list
        if movedChat {
            setExpanded(!isHeldFolded && (sessionID.map(openSessions.contains) ?? false))
        } else if list.isAllDone, !wasAllDone {
            // Done once: the list folds, and stays open if the reader opens it
            // again to look back.
            close()
        }
        rebuild()
        updateSummary()
        publishHeight()
        setNeedsLayout()
    }

    /// Folds the list while the reader types or answers a request, and leaves
    /// it as they had it after.
    func holdFolded(_ held: Bool) {
        guard held != isHeldFolded else { return }
        isHeldFolded = held
        if held {
            setExpanded(false)
        } else if let sessionID, openSessions.contains(sessionID), !list.items.isEmpty {
            setExpanded(true)
        }
        updateSummary()
    }

    private func close() {
        if let sessionID {
            openSessions.remove(sessionID)
        }
        setExpanded(false)
        updateSummary()
    }

    @objc private func summaryTapped() {
        guard !isSuppressed, !list.items.isEmpty else { return }
        let open = !isExpanded
        if let sessionID {
            if open { openSessions.insert(sessionID) } else { openSessions.remove(sessionID) }
        }
        setExpanded(open)
        updateSummary()
    }

    private func rebuild() {
        for row in rows {
            row.removeFromSuperview()
        }
        rows = list.items.map { item in
            let row = TodoRow()
            row.show(item)
            scroll.addSubview(row)
            return row
        }
    }

    /// The host folded every panel (a tap on the page, a send): the line
    /// says so too.
    override func expansionDidChange() {
        updateSummary()
    }

    private func updateSummary() {
        let total = list.items.count
        let done = list.completed.count
        let allDone = list.isAllDone
        let count = "\(done.formatted())/\(total.formatted())"
        badge.text = allDone ? String(localized: "All Done") : count
        badge.textColor = allDone ? .systemGreen : .tintColor
        badge.backgroundColor = (allDone ? UIColor.systemGreen : UIColor.tintColor).withAlphaComponent(0.14)

        let open = isExpanded && !isSuppressed
        let current = list.items.first { $0.status == .inProgress }
        currentLabel.text = current?.title
        currentLabel.isHidden = open || current == nil

        let angle: CGFloat = open ? 0 : (laysOutRightToLeft ? .pi / 2 : -.pi / 2)
        fold.transform = CGAffineTransform(rotationAngle: angle)

        var parts = [allDone ? String(localized: "All Done") : String(localized: "\(done) of \(total) done")]
        if let current, !open {
            parts.append(String(localized: "In progress: \(current.title)"))
        }
        parts.append(open ? String(localized: "Expanded") : String(localized: "Collapsed"))
        summary.accessibilityValue = parts.joined(separator: ", ")
        setNeedsLayout()
    }

    // MARK: Measures

    private var summaryHeight: CGFloat {
        max(ceil(Self.summaryFont.lineHeight), 20) + ComposerMetrics.Spacing.xs
    }

    override var foldedHeight: CGFloat {
        guard !list.items.isEmpty else { return 0 }
        return ComposerMetrics.Spacing.sm * 2 + summaryHeight
    }

    /// The rows' height at the width they were last laid out at; before the
    /// first layout, one line each.
    private var listWidth: CGFloat {
        body.bounds.width > 0 ? body.bounds.width : max(0, bounds.width - ComposerMetrics.Spacing.md * 2)
    }

    private var listHeight: CGFloat {
        guard !rows.isEmpty else { return 0 }
        let width = listWidth
        return rows.map { $0.height(forWidth: width) }.reduce(0, +) + CGFloat(rows.count - 1) * Self.rowSpacing
    }

    private static let rowSpacing = ComposerMetrics.Spacing.xs

    override var preferredHeight: CGFloat {
        guard !list.items.isEmpty else { return 0 }
        // The folded line, then the list under it, then the panel's foot.
        return foldedHeight + ComposerMetrics.Spacing.xs + min(listHeight, ComposerMetrics.Panel.maxBodyHeight)
    }

    private var lastWidth: CGFloat = 0

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // A new text size changes every row's height and the line's.
        if traitCollection.preferredContentSizeCategory != previous?.preferredContentSizeCategory {
            publishHeight()
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let inset = ComposerMetrics.Spacing.md
        let top = ComposerMetrics.Spacing.sm
        let lineHeight = summaryHeight
        let buttonSize = max(lineHeight, 22)
        let line = CGRect(x: inset, y: top, width: max(0, bounds.width - inset * 2), height: lineHeight)

        hideButton.frame = directionalFrame(CGRect(
            x: line.maxX - buttonSize,
            y: line.midY - buttonSize / 2,
            width: buttonSize,
            height: buttonSize,
        ))
        summary.frame = directionalFrame(CGRect(
            x: line.minX,
            y: line.minY,
            width: max(0, line.width - buttonSize - ComposerMetrics.Spacing.xs),
            height: lineHeight,
        ))

        // The line, left to right inside the summary, mirrored after.
        let height = summary.bounds.height
        var x: CGFloat = 0
        let markSize = checkMark.intrinsicContentSize
        checkMark.frame = CGRect(x: x, y: (height - markSize.height) / 2, width: markSize.width, height: markSize.height)
        x = checkMark.frame.maxX + ComposerMetrics.Spacing.xs
        let name = nameLabel.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: height))
        nameLabel.frame = CGRect(x: x, y: (height - name.height) / 2, width: ceil(name.width), height: ceil(name.height))
        x = nameLabel.frame.maxX + ComposerMetrics.Spacing.sm
        let badgeText = badge.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: height))
        let badgeSize = CGSize(width: ceil(badgeText.width) + 12, height: ceil(badgeText.height) + 4)
        badge.frame = CGRect(x: x, y: (height - badgeSize.height) / 2, width: badgeSize.width, height: badgeSize.height)
        x = badge.frame.maxX + ComposerMetrics.Spacing.xs
        let foldSize = fold.intrinsicContentSize
        let foldX = summary.bounds.width - foldSize.width
        fold.frame = CGRect(x: foldX, y: (height - foldSize.height) / 2, width: foldSize.width, height: foldSize.height)
        currentLabel.frame = CGRect(
            x: x,
            y: 0,
            width: max(0, foldX - ComposerMetrics.Spacing.xs - x),
            height: height,
        )
        summary.mirrorForLayoutDirection([checkMark, nameLabel, badge, currentLabel, fold])

        // The list starts under the line, where the folded panel ends.
        let bodyTop = foldedHeight - top + ComposerMetrics.Spacing.xs
        body.frame = CGRect(
            x: inset,
            y: bodyTop,
            width: line.width,
            height: max(0, bounds.height - bodyTop - top),
        )
        scroll.frame = body.bounds
        var y: CGFloat = 0
        for row in rows {
            let rowHeight = row.height(forWidth: body.bounds.width)
            row.frame = CGRect(x: 0, y: y, width: body.bounds.width, height: rowHeight)
            y += rowHeight + Self.rowSpacing
        }
        scroll.contentSize = CGSize(width: body.bounds.width, height: max(0, y - Self.rowSpacing))

        // A row that wraps at the width it really has makes the panel taller.
        if body.bounds.width != lastWidth {
            lastWidth = body.bounds.width
            publishHeight()
        }
    }
}

private extension TodoList {
    var isAllDone: Bool {
        !items.isEmpty && items.allSatisfy { $0.status == .completed }
    }
}

/// One item, as aimini's `TodoItemRow` draws it: a tick for done, a pulsing
/// dot and "In progress" for the one under way, a ring for one not started,
/// a cross for one blocked; done items greyed and struck through.
private final class TodoRow: UIView {
    private let markView = UIImageView()
    private let dot = UIView()
    private let titleLabel = UILabel()
    private let capsule = UILabel()
    private var status: TodoStatus = .pending

    private static let markWidth: CGFloat = 16
    private static var titleFont: UIFont { .preferredFont(forTextStyle: .footnote) }

    override init(frame: CGRect) {
        super.init(frame: frame)

        markView.contentMode = .center
        markView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)

        dot.layer.cornerRadius = 4
        dot.backgroundColor = .tintColor

        titleLabel.font = Self.titleFont
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        capsule.font = .preferredFont(forTextStyle: .caption2)
        capsule.adjustsFontForContentSizeCategory = true
        capsule.text = String(localized: "In progress")
        capsule.textColor = .tintColor
        capsule.backgroundColor = UIColor.tintColor.withAlphaComponent(0.14)
        capsule.textAlignment = .center
        capsule.layer.cornerRadius = 4
        capsule.layer.cornerCurve = .continuous
        capsule.clipsToBounds = true

        for view in [markView, dot, titleLabel, capsule] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }

        isAccessibilityElement = true
        accessibilityTraits = .staticText
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updatePulse),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ item: TodoRecord) {
        status = item.status
        switch item.status {
        case .completed:
            markView.image = UIImage(systemName: "checkmark")
            markView.tintColor = .systemGreen
        case .pending:
            markView.image = UIImage(systemName: "circle")
            markView.tintColor = .secondaryLabel
        case .blocked:
            markView.image = UIImage(systemName: "xmark")
            markView.tintColor = .systemRed
        case .inProgress:
            markView.image = nil
        }
        markView.isHidden = item.status == .inProgress
        dot.isHidden = item.status != .inProgress
        capsule.isHidden = item.status != .inProgress

        let done = item.status == .completed
        titleLabel.attributedText = NSAttributedString(string: item.title, attributes: [
            .font: Self.titleFont,
            .foregroundColor: done ? UIColor.tertiaryLabel : UIColor.label,
            .strikethroughStyle: done ? NSUnderlineStyle.single.rawValue : 0,
        ])
        // The mark is a state drawn, never read: the label says what it means.
        accessibilityLabel = item.title
        accessibilityValue = spoken(item.status)
        updatePulse()
        setNeedsLayout()
    }

    private func spoken(_ status: TodoStatus) -> String {
        switch status {
        case .pending: String(localized: "Not started")
        case .inProgress: String(localized: "In progress")
        case .completed: String(localized: "Done")
        case .blocked: String(localized: "Blocked")
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Core Animation drops a repeating animation when the view leaves its
        // window or the app goes to the background; it is put back here.
        updatePulse()
    }

    @objc private func updatePulse() {
        dot.layer.removeAnimation(forKey: "pulse")
        guard status == .inProgress, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.65
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer.add(pulse, forKey: "pulse")
    }

    private var capsuleSize: CGSize {
        guard !capsule.isHidden else { return .zero }
        let text = capsule.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        return CGSize(width: ceil(text.width) + 12, height: ceil(text.height) + 2)
    }

    private func titleWidth(in width: CGFloat) -> CGFloat {
        let capsuleRoom = capsule.isHidden ? 0 : capsuleSize.width + ComposerMetrics.Spacing.xs
        return max(0, width - Self.markWidth - ComposerMetrics.Spacing.sm - capsuleRoom)
    }

    /// The row's height at `width`: its title on up to two lines.
    func height(forWidth width: CGFloat) -> CGFloat {
        let title = titleLabel.sizeThatFits(CGSize(width: titleWidth(in: width), height: .greatestFiniteMagnitude))
        return max(ceil(title.height), ceil(Self.titleFont.lineHeight), capsuleSize.height) + 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let firstLine = ceil(Self.titleFont.lineHeight)
        let lineMid = 1 + firstLine / 2
        markView.frame = CGRect(x: 0, y: lineMid - Self.markWidth / 2, width: Self.markWidth, height: Self.markWidth)
        dot.frame = CGRect(x: (Self.markWidth - 8) / 2, y: lineMid - 4, width: 8, height: 8)
        let titleX = Self.markWidth + ComposerMetrics.Spacing.sm
        let width = titleWidth(in: bounds.width)
        let title = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        titleLabel.frame = CGRect(x: titleX, y: 1, width: width, height: min(ceil(title.height), bounds.height))
        let size = capsuleSize
        capsule.frame = CGRect(x: bounds.width - size.width, y: lineMid - size.height / 2, width: size.width, height: size.height)
        mirrorForLayoutDirection([markView, dot, titleLabel, capsule])
    }
}
