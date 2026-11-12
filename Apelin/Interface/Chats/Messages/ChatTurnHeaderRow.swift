import ListViewKit
import UIKit

/// One disclosure per turn. A folded running turn shows its state and token
/// count only; thought/tool activity belongs to the process, not this line.
final class ChatTurnHeaderRow: ListRowView {
    @objc dynamic var onToggle: (() -> Void)?

    private let state = ThinkingStatusLabel()
    private let received = ReceivedTokensView()
    private let chevron = UIImageView()
    private static let sizingState = UILabel()
    private static let sizingTokens = ReceivedTokensView()
    private var turnID: UUID?
    private var actionsExpanded: Bool?
    @objc dynamic private var shownID: UUID?
    @objc dynamic private var showsReceived = false

    private enum Style {
        static let topSpacing: CGFloat = 2
        static let bottomSpacing: CGFloat = 2
        static var stateFont: UIFont { .preferredFont(forTextStyle: .headline) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        state.isAccessibilityElement = false
        state.clipsToBounds = true
        addSubview(state)
        received.isHidden = true
        addSubview(received)
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
        shownID = nil
        state.isThinking = false
        state.animationIdentity = nil
        state.text = nil
        showsReceived = false
        received.layer.removeAllAnimations()
        received.isHidden = true
        received.alpha = 1
        turnID = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityCustomActions = nil
        actionsExpanded = nil
        onToggle = nil
    }

    func show(_ message: ChatMessage) {
        guard case let .turn(running, _) = message.role else { return }
        let isSameMessage = shownID == message.id
        shownID = message.id
        turnID = message.turnMessageID ?? message.id
        let title = running ? String(localized: "Running") : String(localized: "Completed")
        state.animationIdentity = message.id
        state.font = Style.stateFont
        state.text = title
        state.isThinking = running
        showReceived(
            message.headerReceivedTokens,
            settles: message.headerReceivedSettles,
            animated: isSameMessage,
        )
        let expanded = turnID.map(ChatTraceExpansion.isExpanded(turn:)) ?? false
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        accessibilityLabel = title
        accessibilityValue = message.headerReceivedTokens.map(ReceivedTokensView.spoken)
        if actionsExpanded != expanded {
            actionsExpanded = expanded
            accessibilityCustomActions = [Self.expandAction(expanded: expanded, owner: self)]
        }
        setNeedsLayout()
    }

    private func showReceived(_ tokens: Int?, settles: Bool, animated: Bool) {
        let moves = animated && window != nil && !UIAccessibility.isReduceMotionEnabled
        if let tokens {
            if !moves {
                received.show(tokens)
            } else {
                if !showsReceived {
                    received.show(0)
                }
                received.climb(to: tokens, within: settles ? TokenClimb.settling : TokenClimb.running)
            }
        }
        let shows = tokens != nil
        guard shows != showsReceived else { return }
        showsReceived = shows
        received.layer.removeAllAnimations()
        if shows {
            received.isHidden = false
            setNeedsLayout()
            layoutIfNeeded()
            received.alpha = moves ? 0 : 1
            if moves {
                UIView.animate(withDuration: 0.2) { self.received.alpha = 1 }
            }
        } else if moves {
            UIView.animate(withDuration: 0.2) {
                self.received.alpha = 0
            } completion: { _ in
                guard !self.showsReceived else { return }
                self.received.isHidden = true
                self.received.alpha = 1
            }
        } else {
            received.isHidden = true
            received.alpha = 1
        }
        setNeedsLayout()
    }

    @objc dynamic private static func expandAction(
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

    @objc dynamic private func toggle() {
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
        if state.font != Style.stateFont {
            state.font = Style.stateFont
        }
        let size = state.sizeThatFits(CGSize(width: max(1, content.width), height: .greatestFiniteMagnitude))
        let line = max(ceil(size.height), received.isHidden ? 0 : received.lineHeight)
        let slots = ChatHeaderLayout(
            width: content.width, stateWidth: ceil(size.width), showsTokens: !received.isHidden,
        )
        let y = content.minY + Style.topSpacing
        state.frame = directionalFrame(CGRect(
            x: content.minX, y: y + (line - ceil(size.height)) / 2,
            width: slots.stateWidth, height: ceil(size.height),
        ))
        received.frame = directionalFrame(CGRect(
            x: content.minX + slots.tokensX, y: y + (line - received.lineHeight) / 2,
            width: slots.tokensWidth, height: received.lineHeight,
        ))
        let arrow = directionalFrame(CGRect(
            x: content.minX + slots.chevronX, y: y + (line - slots.chevronWidth) / 2,
            width: slots.chevronWidth, height: slots.chevronWidth,
        ))
        // Setting a rotated view's frame uses its transformed bounding box.
        // Bounds and centre leave the reserved slot unchanged during rotation.
        chevron.bounds.size = arrow.size
        chevron.center = CGPoint(x: arrow.midX, y: arrow.midY)
    }

    static func height(for message: ChatMessage, width: CGFloat) -> CGFloat {
        let insets = ChatMessageRow.insets(for: width)
        sizingState.font = Style.stateFont
        sizingState.numberOfLines = 1
        sizingState.text = "Completed"
        var line = ceil(sizingState.sizeThatFits(
            CGSize(width: max(1, width - insets.left - insets.right), height: .greatestFiniteMagnitude),
        ).height)
        if message.headerReceivedTokens != nil {
            line = max(line, sizingTokens.lineHeight)
        }
        return insets.top + Style.topSpacing + line + Style.bottomSpacing + insets.bottom
    }
}
