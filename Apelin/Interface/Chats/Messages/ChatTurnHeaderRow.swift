import ListViewKit
import UIKit

/// The header of a turn, under the message that began it: whether the run is
/// going or done, and while it goes what it has done so far. One per turn, as
/// aimini draws a turn's header — a turn that writes a reply and then works
/// on is one turn, not a finished process, a reply, and a running process
/// after it. It is also the only way into the turn's process: folded, the
/// process rows are not in the transcript at all.
final class ChatTurnHeaderRow: ListRowView {
    /// The header was tapped: the turn's process is open now, or it is not.
    @objc dynamic var onToggle: (() -> Void)?

    private let state = ThinkingStatusLabel()
    /// What the turn has done so far, under the state and quieter than it.
    private let work = UILabel()
    private let chevron = UIImageView()
    private static let sizingState = UILabel()
    private static let sizingWork = UILabel()
    /// The turn this header belongs to, which is what the process is kept by.
    private var turnID: UUID?

    private enum Style {
        static let topSpacing: CGFloat = 2
        static let bottomSpacing: CGFloat = 2
        static let spacing: CGFloat = 6
        static let chevronSize: CGFloat = 14

        /// The state is the heading; what the turn has done is the detail,
        /// and is drawn smaller than it.
        static var stateFont: UIFont { .preferredFont(forTextStyle: .headline) }
        static var workFont: UIFont { .preferredFont(forTextStyle: .caption1) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        state.isAccessibilityElement = false
        addSubview(state)

        work.font = Style.workFont
        work.adjustsFontForContentSizeCategory = true
        work.textColor = .tertiaryLabel
        work.numberOfLines = 1
        work.lineBreakMode = .byTruncatingTail
        work.isAccessibilityElement = false
        addSubview(work)

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold),
        )
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.isAccessibilityElement = false
        addSubview(chevron)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        isAccessibilityElement = true
        accessibilityTraits = [.button, .header]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        state.isThinking = false
        state.animationIdentity = nil
        state.text = nil
        work.text = nil
        turnID = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        onToggle = nil
    }

    func show(_ message: ChatMessage) {
        guard case let .turn(running, _) = message.role else { return }
        turnID = message.turnMessageID ?? message.id
        let title = running ? String(localized: "Running") : String(localized: "Completed")
        state.animationIdentity = message.id
        state.font = Style.stateFont
        state.text = title
        // While the run goes the heading shimmers, as aimini's turn header
        // does; a finished one is drawn flat.
        state.isThinking = running
        // What the turn did so far is said while it runs; a finished turn
        // says only that it is done, and what it did is behind its steps.
        let detail = running ? message.text : ""
        work.font = Style.workFont
        work.text = detail.isEmpty ? nil : detail
        work.isHidden = detail.isEmpty
        let expanded = turnID.map(ChatTraceExpansion.isExpanded(turn:)) ?? false
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        accessibilityLabel = title
        accessibilityValue = detail.isEmpty ? nil : detail
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: expanded ? String(localized: "Collapse") : String(localized: "Expand"),
            ) { [weak self] _ in
                self?.toggle()
                return true
            },
        ]
        setNeedsLayout()
    }

    @objc private func toggle() {
        guard let turnID else { return }
        let expanded = !ChatTraceExpansion.isExpanded(turn: turnID)
        ChatTraceExpansion.setExpanded(turn: turnID, expanded)
        let turn = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        if window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2) { self.chevron.transform = turn }
        } else {
            chevron.transform = turn
        }
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: expanded ? String(localized: "Collapse") : String(localized: "Expand"),
            ) { [weak self] _ in
                self?.toggle()
                return true
            },
        ]
        onToggle?()
    }

    override func accessibilityActivate() -> Bool {
        toggle()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = bounds.inset(by: ChatMessageRow.insets(for: bounds.width))
        let textWidth = max(1, content.width)
        state.font = Style.stateFont
        work.font = Style.workFont
        let chevronRoom = Style.chevronSize + Style.spacing
        let stateHeight = ceil(state.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        ).height)
        let line = max(stateHeight, ceil(work.font.lineHeight))
        let y = content.minY + Style.topSpacing
        let stateWidth = min(
            textWidth,
            ceil(state.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).width),
        )
        state.frame = CGRect(x: content.minX, y: y, width: stateWidth, height: stateHeight)
        let workX = content.minX + stateWidth + Style.spacing
        let workWidth = max(0, content.maxX - chevronRoom - workX)
        work.frame = CGRect(x: workX, y: y, width: workWidth, height: line)
        chevron.frame = CGRect(
            x: content.maxX - Style.chevronSize,
            y: y + (line - Style.chevronSize) / 2,
            width: Style.chevronSize,
            height: Style.chevronSize,
        )
    }

    static func height(for message: ChatMessage, width: CGFloat) -> CGFloat {
        let insets = ChatMessageRow.insets(for: width)
        let textWidth = max(1, width - insets.left - insets.right)
        sizingState.font = Style.stateFont
        sizingState.numberOfLines = 1
        sizingState.text = "Completed"
        sizingWork.font = Style.workFont
        let state = ceil(sizingState.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        ).height)
        let line = max(state, ceil(sizingWork.font.lineHeight))
        return insets.top + Style.topSpacing + line + Style.bottomSpacing + insets.bottom
    }
}
