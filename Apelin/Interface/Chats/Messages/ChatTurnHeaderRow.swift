import ListViewKit
import UIKit

/// The header of a turn, under the message that began it: whether the run is
/// going or done, and — while the turn is folded and running — what it is
/// doing now, on the same line: "Running: Thinking…" with the output tokens
/// the run has received so far after it. One per turn, as aimini draws a
/// turn's header — a turn that writes a reply and then works on is one turn,
/// not a finished process, a reply, and a running process after it. It is
/// also the only way into the turn's process: folded, the process rows are
/// not in the transcript at all. What the turn did is not on this line: a
/// count of seconds and calls over the process reads worse than the process,
/// and is not shown once it is done.
final class ChatTurnHeaderRow: ListRowView {
    /// The header was tapped: the turn's process is open now, or it is not.
    @objc dynamic var onToggle: (() -> Void)?

    private let state = ThinkingStatusLabel()
    /// The folded summary's title, after the state and its separator, on a
    /// running header only; a finished turn's header says its state alone.
    private let activityLabel = UILabel()
    private let received = ReceivedTokensView()
    private let chevron = UIImageView()
    private static let sizingState = UILabel()
    private static let sizingActivity = UILabel()
    private static let sizingTokens = ReceivedTokensView()
    /// The turn this header belongs to, which is what the process is kept by.
    private var turnID: UUID?
    /// Which state the custom action was built for: it is rebuilt when that
    /// changes, never on every event of a run.
    private var actionsExpanded: Bool?
    /// The message shown: only a change to it animates, never the row taking
    /// another message out of the pool.
    @objc dynamic private var shownID: UUID?
    /// Whether the count is meant to be on screen, while it fades too.
    @objc dynamic private var showsReceived = false

    private enum Style {
        static let topSpacing: CGFloat = 2
        static let bottomSpacing: CGFloat = 2
        static let chevronSize: CGFloat = 14
        /// Between the count and the chevron.
        static let chevronSpacing: CGFloat = 6
        /// Between the title and the count.
        static let tokensSpacing: CGFloat = 6

        static var stateFont: UIFont { .preferredFont(forTextStyle: .headline) }
        static var activityFont: UIFont { .preferredFont(forTextStyle: .body) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        state.isAccessibilityElement = false
        addSubview(state)

        activityLabel.font = Style.activityFont
        activityLabel.adjustsFontForContentSizeCategory = true
        activityLabel.textColor = .secondaryLabel
        activityLabel.numberOfLines = 1
        activityLabel.lineBreakMode = .byTruncatingTail
        activityLabel.isAccessibilityElement = false
        activityLabel.isHidden = true
        addSubview(activityLabel)

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
        activityLabel.text = nil
        activityLabel.isHidden = true
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
        // While the run goes the heading shimmers, as aimini's turn header
        // does; a finished one is drawn flat.
        state.isThinking = running
        // What the folded turn is doing now sits after the state, as its own
        // words: the state keeps its weight and the activity reads dimmer.
        let activity = message.headerActivityTitle
        activityLabel.font = Style.activityFont
        activityLabel.text = activity.isEmpty ? nil : String(localized: ": \(activity)")
        activityLabel.isHidden = activityLabel.text == nil
        showReceived(
            message.headerReceivedTokens,
            settles: message.headerReceivedSettles,
            animated: isSameMessage,
        )
        let expanded = turnID.map(ChatTraceExpansion.isExpanded(turn:)) ?? false
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        accessibilityLabel = activity.isEmpty ? title : title + String(localized: ": \(activity)")
        accessibilityValue = message.headerReceivedTokens.map(ReceivedTokensView.spoken)
        if actionsExpanded != expanded {
            actionsExpanded = expanded
            accessibilityCustomActions = [Self.expandAction(expanded: expanded, owner: self)]
        }
        setNeedsLayout()
    }

    /// On the same header the count climbs to each figure — from nothing when
    /// it appears — as the summary under it does, and fades in and out; on
    /// another header, off screen or under Reduce Motion it is there, or
    /// gone, at once.
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
            // in place before it fades in, not moving in from elsewhere
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
        // Setting the font redraws the label and marks it for layout again
        // (`ThinkingStatusLabel.updateText`), so it is set only when it
        // differs: setting it on every pass would relayout forever.
        if state.font != Style.stateFont {
            state.font = Style.stateFont
        }
        if activityLabel.font != Style.activityFont {
            activityLabel.font = Style.activityFont
        }
        let stateWidth = min(
            textWidth,
            ceil(state.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).width),
        )
        let stateHeight = ceil(state.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        ).height)
        let y = content.minY + Style.topSpacing
        state.frame = CGRect(x: content.minX, y: y, width: stateWidth, height: stateHeight)

        // the count ends where the chevron begins, and the title ends before
        // the count: the figure sits against the arrow, at the line's end
        let chevronX = content.maxX - Style.chevronSize
        let countEnd = chevronX - Style.chevronSpacing
        received.frame = CGRect(
            x: content.minX,
            y: y + ((stateHeight - received.lineHeight) / 2).rounded(),
            width: max(1, countEnd - content.minX),
            height: received.lineHeight,
        )
        if !activityLabel.isHidden {
            // set on the state's baseline, so the two read as one line
            let baseline = y + state.font.ascender
            let start = content.minX + stateWidth
            let end = received.isHidden
                ? countEnd
                : countEnd - received.contentWidth - Style.tokensSpacing
            activityLabel.frame = CGRect(
                x: start,
                y: baseline - Style.activityFont.ascender,
                width: max(0, end - start),
                height: ceil(activityLabel.sizeThatFits(
                    CGSize(width: max(1, end - start), height: .greatestFiniteMagnitude),
                ).height),
            )
        }
        chevron.frame = CGRect(
            x: chevronX,
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
        var line = ceil(sizingState.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        ).height)
        if !message.headerActivityTitle.isEmpty {
            sizingActivity.font = Style.activityFont
            sizingActivity.numberOfLines = 1
            sizingActivity.text = "Thinking…"
            line = max(line, ceil(sizingActivity.sizeThatFits(
                CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            ).height))
        }
        if message.headerReceivedTokens != nil {
            line = max(line, sizingTokens.lineHeight)
        }
        return insets.top + Style.topSpacing + line + Style.bottomSpacing + insets.bottom
    }
}
