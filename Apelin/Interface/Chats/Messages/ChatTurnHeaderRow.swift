import ListViewKit
import UIKit

/// The header of a turn, under the message that began it: whether the run is
/// going or done. One per turn, as aimini draws a turn's header — a turn that
/// writes a reply and then works on is one turn, not a finished process, a
/// reply, and a running process after it. It is also the only way into the
/// turn's process: folded, the process rows are not in the transcript at all.
/// What the turn did is not on this line: a count of seconds and calls over
/// the process reads worse than the process, and is not shown once it is done.
final class ChatTurnHeaderRow: ListRowView {
    /// The header was tapped: the turn's process is open now, or it is not.
    @objc dynamic var onToggle: (() -> Void)?

    private let state = ThinkingStatusLabel()
    private let chevron = UIImageView()
    private static let sizingState = UILabel()
    /// The turn this header belongs to, which is what the process is kept by.
    private var turnID: UUID?
    /// Which state the custom action was built for: it is rebuilt when that
    /// changes, never on every event of a run.
    private var actionsExpanded: Bool?

    private enum Style {
        static let topSpacing: CGFloat = 2
        static let bottomSpacing: CGFloat = 2
        static let chevronSize: CGFloat = 14

        static var stateFont: UIFont { .preferredFont(forTextStyle: .headline) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        state.isAccessibilityElement = false
        addSubview(state)

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
        turnID = nil
        accessibilityLabel = nil
        accessibilityCustomActions = nil
        actionsExpanded = nil
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
        let expanded = turnID.map(ChatTraceExpansion.isExpanded(turn:)) ?? false
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        accessibilityLabel = title
        if actionsExpanded != expanded {
            actionsExpanded = expanded
            accessibilityCustomActions = [Self.expandAction(expanded: expanded, owner: self)]
        }
        setNeedsLayout()
    }

    /// The one custom action a header offers: open its process, or fold it.
    private static func expandAction(
        expanded: Bool,
        owner: ChatTurnHeaderRow,
    ) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(
            name: expanded ? String(localized: "Collapse") : String(localized: "Expand"),
        ) { [weak owner] _ in
            owner?.toggle()
            return true
        }
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
        accessibilityCustomActions = [Self.expandAction(expanded: expanded, owner: self)]
        actionsExpanded = expanded
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
        let stateWidth = min(
            textWidth,
            ceil(state.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).width),
        )
        let stateHeight = ceil(state.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        ).height)
        let y = content.minY + Style.topSpacing
        state.frame = CGRect(x: content.minX, y: y, width: stateWidth, height: stateHeight)
        chevron.frame = CGRect(
            x: content.maxX - Style.chevronSize,
            y: y + (stateHeight - Style.chevronSize) / 2,
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
        let state = ceil(sizingState.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        ).height)
        return insets.top + Style.topSpacing + state + Style.bottomSpacing + insets.bottom
    }
}
