import ListViewKit
import UIKit

/// A summary in the transcript: a thought as prose, a call as a line of its
/// own that opens into what it was told and what it answered. Its trace's own
/// page (`TraceController`) is one long press away. The turn's header above
/// it (`ChatTurnHeaderRow`) is what opens and folds the turn's process; this
/// row draws the stretch it was given, whole. The turn's latest summary
/// carries the output the run has received so far at the trailing end of its
/// title line, the title's first line fading out before it; a running
/// summary's newest call is the line under it. While the turn is folded, that
/// title and count are drawn on the header's line instead, and this row keeps
/// only the call it is on.
final class ChatActivityRow: ListRowView {
    /// A step inside was folded or unfolded: the list has to measure the row
    /// again.
    @objc dynamic var onToggle: (() -> Void)?
    /// The reader asked for the trace's page, where a step is shown whole.
    @objc dynamic var onOpenPage: (() -> Void)?
    private let header = ThinkingStatusLabel()
    private let sourceLabel = UILabel()
    private static let sizingSource = UILabel()
    /// Holds the title, and while the count shows fades its first line out
    /// before it (`titleMask`), so a long title runs under the count rather
    /// than into it. The title's own mask is its shimmer.
    private let titleView = UIView()
    private let titleMask = CALayer()
    private let titleFade = CAGradientLayer()
    private let titleRest = CALayer()
    private let received = ReceivedTokensView()
    private let bannerView = ToolCallBannerView()
    /// The summary's steps, under the line the run's newest call is on.
    private let expansion = ChatTraceSteps()
    /// The summary shown: its steps are what the expansion draws.
    private var message: ChatMessage?
    /// The message this row shows: only a change to it animates, never the
    /// row taking another message out of the pool.
    @objc dynamic private var shownID: UUID?
    /// Whether the count is meant to be on screen, while it fades too.
    @objc dynamic private var showsReceived = false
    private static let sizingHeader = ThinkingStatusLabel()
    /// Between the title's fade and the count.
    private static let receivedSpacing: CGFloat = 6
    /// How far the title fades out before the count.
    private static let titleFadeWidth: CGFloat = 20

    override init(frame: CGRect) {
        super.init(frame: frame)
        sourceLabel.font = .preferredFont(forTextStyle: .caption1)
        sourceLabel.adjustsFontForContentSizeCategory = true
        sourceLabel.textColor = .secondaryLabel
        sourceLabel.numberOfLines = 0
        sourceLabel.isHidden = true
        addSubview(sourceLabel)
        titleView.addSubview(header)
        addSubview(titleView)
        titleFade.colors = Self.opaqueFade
        titleRest.backgroundColor = UIColor.black.cgColor
        titleMask.addSublayer(titleFade)
        titleMask.addSublayer(titleRest)
        received.isHidden = true
        addSubview(received)
        bannerView.isHidden = true
        addSubview(bannerView)
        expansion.onExpansionChange = { [weak self] in self?.onToggle?() }
        expansion.isHidden = true
        addSubview(expansion)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(openPage(_:)))
        press.delegate = self
        addGestureRecognizer(press)
        header.onShownTextChange = { [weak self] _ in
            self?.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ message: ChatMessage) {
        let isSameMessage = shownID == message.id
        shownID = message.id
        self.message = message
        header.animationIdentity = message.id
        // A folded turn's title and count are the header's line, right after
        // its state: this row keeps only the call it is on.
        let title = ChatActivityContent.title(message)
        header.text = title
        sourceLabel.text = ChatActivityContent.source(message)
        sourceLabel.isHidden = sourceLabel.text == nil
        isAccessibilityElement = false
        header.accessibilityLabel = title.isEmpty ? nil : title
        var actions: [UIAccessibilityCustomAction] = []
        if Self.isReasoning(message) {
            actions.append(UIAccessibilityCustomAction(name: String(localized: "View Thoughts")) { [weak self] _ in
                self?.onOpenPage?()
                return true
            })
        }
        header.accessibilityTraits = .staticText
        header.accessibilityCustomActions = actions.isEmpty ? nil : actions
        if message.foldsProcessSteps {
            // A folded turn draws its whole process as this one line and the
            // call it is on: the steps under them are what opening the turn's
            // header is for, and rebuilding them here would be work nobody
            // sees, on every event of a run.
            expansion.isHidden = true
        } else {
            expansion.show(message)
            expansion.isHidden = false
        }
        let tokens = message.foldsProcessSteps ? nil : message.receivedTokens
        header.accessibilityValue = tokens.map(ReceivedTokensView.spoken)
        if let call = ChatActivityContent.banner(message) {
            bannerView.show(call, animated: isSameMessage)
            bannerView.isHidden = false
        } else {
            bannerView.reset()
            bannerView.isHidden = true
        }
        header.isThinking = message.role.isThinking
        showReceived(tokens, settles: message.receivedSettles,
                     animated: isSameMessage && !message.foldsProcessSteps && !title.isEmpty)
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        shownID = nil
        header.isThinking = false
        header.animationIdentity = nil
        header.text = nil
        sourceLabel.text = nil
        sourceLabel.isHidden = true
        header.accessibilityValue = nil
        showsReceived = false
        received.layer.removeAllAnimations()
        received.isHidden = true
        received.alpha = 1
        setTitleFade(false, animated: false)
        titleView.layer.mask = nil
        bannerView.reset()
        bannerView.isHidden = true
        expansion.isHidden = true
        expansion.alpha = 1
        expansion.transform = .identity
        message = nil
        onToggle = nil
        onOpenPage = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let message else { return }
        let insets = ChatMessageRow.insets(for: bounds.width)
        let textWidth = max(1, bounds.width - insets.left - insets.right)
        let sourceHeight = Self.sourceHeight(ChatActivityContent.source(message), width: textWidth)
        let titleHeight = Self.titleHeight(for: message, width: textWidth)
        let stepsHeight = expansion.isHidden ? 0 : expansion.fittingHeight(width: textWidth)
        let layout = ChatActivityLayout(
            source: sourceHeight, title: titleHeight,
            banner: bannerView.isHidden ? 0 : ToolCallBannerView.height, steps: stepsHeight,
            top: message.activityJoinsPrevious ? 0 : insets.top, bottom: insets.bottom,
        )
        sourceLabel.font = .preferredFont(forTextStyle: .caption1)
        sourceLabel.frame = CGRect(x: insets.left, y: layout.sourceY, width: textWidth, height: sourceHeight)
        titleView.isHidden = titleHeight == 0
        titleView.frame = CGRect(x: insets.left, y: layout.titleY, width: textWidth, height: titleHeight)
        header.frame = titleView.bounds
        layoutReceived(in: CGRect(x: insets.left, y: 0, width: textWidth, height: bounds.height))
        if !bannerView.isHidden {
            let padding = ChatMessageRow.horizontalPadding
            bannerView.frame = CGRect(
                x: insets.left - padding, y: layout.bannerY,
                width: textWidth + padding * 2, height: ToolCallBannerView.height,
            )
            bannerView.groundBleed = UIEdgeInsets(
                top: 0,
                left: max(0, bannerView.frame.minX),
                bottom: 0,
                right: max(0, bounds.width - bannerView.frame.maxX),
            )
        }
        expansion.frame = expansion.isHidden ? .zero : CGRect(
            x: insets.left, y: layout.stepsY, width: textWidth, height: stepsHeight,
        )
    }

    /// Across the title's first line, drawn at its trailing end; the title
    /// fades out before it, however long the title is.
    @objc dynamic private func layoutReceived(in content: CGRect) {
        guard !received.isHidden else { return }
        let line = ceil(header.font.lineHeight)
        let height = received.lineHeight
        received.frame = CGRect(
            x: content.minX,
            y: titleView.frame.minY + ((line - height) / 2).rounded(),
            width: content.width,
            height: height,
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = titleView.bounds
        titleMask.frame = bounds
        titleFade.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(line, bounds.height))
        titleRest.frame = CGRect(x: 0, y: titleFade.frame.maxY, width: bounds.width,
                                 height: max(0, bounds.height - titleFade.frame.maxY))
        // measured from the title's leading edge, whichever side that is
        let width = max(bounds.width, 1)
        let end = min(max((bounds.width - received.contentWidth - Self.receivedSpacing) / width, 0), 1)
        titleFade.locations = [NSNumber(value: Double(max(end - Self.titleFadeWidth / width, 0))), NSNumber(value: Double(end))]
        titleFade.startPoint = CGPoint(x: laysOutRightToLeft ? 1 : 0, y: 0.5)
        titleFade.endPoint = CGPoint(x: laysOutRightToLeft ? 0 : 1, y: 0.5)
        CATransaction.commit()
    }

    private static let opaqueFade = [UIColor.black.cgColor, UIColor.black.cgColor]
    private static let clearingFade = [UIColor.black.cgColor, UIColor.clear.cgColor]

    /// The title's first line fading before the count, or whole.
    @objc dynamic private func setTitleFade(_ fades: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        titleFade.colors = fades ? Self.clearingFade : Self.opaqueFade
        CATransaction.commit()
    }

    /// On the same summary the count climbs to each figure — from nothing
    /// when it appears — in five seconds while the summary runs and half a
    /// second once the reply after it has begun, and fades in and out. On
    /// another summary, off screen or under Reduce Motion it is there, or
    /// gone, at once.
    private func showReceived(_ tokens: Int?, settles: Bool, animated: Bool) {
        let moves = animated && window != nil && !UIAccessibility.isReduceMotionEnabled
        if let tokens {
            if !moves || !showsReceived {
                received.show(tokens)
            } else {
                received.climb(to: tokens, within: settles ? TokenClimb.settling : TokenClimb.running)
            }
        }
        let shows = tokens != nil
        guard shows != showsReceived else { return }
        showsReceived = shows
        received.layer.removeAllAnimations()
        if shows {
            received.isHidden = false
            titleView.layer.mask = titleMask
            // in place before it fades in, not moving in from elsewhere
            setNeedsLayout()
            layoutIfNeeded()
            received.alpha = moves ? 0 : 1
            setTitleFade(true, animated: moves)
            if moves {
                UIView.animate(withDuration: 0.2) { self.received.alpha = 1 }
            }
        } else if moves {
            setTitleFade(false, animated: true)
            UIView.animate(withDuration: 0.2) {
                self.received.alpha = 0
            } completion: { _ in
                guard !self.showsReceived else { return }
                self.received.isHidden = true
                self.received.alpha = 1
                self.titleView.layer.mask = nil
            }
        } else {
            received.isHidden = true
            received.alpha = 1
            setTitleFade(false, animated: false)
            titleView.layer.mask = nil
        }
    }

    static func height(for message: ChatMessage, width: CGFloat) -> CGFloat {
        let insets = ChatMessageRow.insets(for: width)
        let width = max(1, width - insets.left - insets.right)
        return ChatActivityLayout(
            source: sourceHeight(ChatActivityContent.source(message), width: width),
            title: titleHeight(for: message, width: width),
            banner: ChatActivityContent.banner(message) == nil ? 0 : ToolCallBannerView.height,
            steps: message.foldsProcessSteps ? 0 : ChatTraceSteps.height(for: message, width: width),
            top: message.activityJoinsPrevious ? 0 : insets.top, bottom: insets.bottom,
        ).height
    }

    private static func titleHeight(for message: ChatMessage, width: CGFloat) -> CGFloat {
        let title = ChatActivityContent.title(message)
        let hasTokens = !message.foldsProcessSteps && message.receivedTokens != nil
        guard !title.isEmpty || hasTokens else { return 0 }
        sizingHeader.font = .preferredFont(forTextStyle: .body)
        sizingHeader.text = title
        let height = title.isEmpty ? 0 : ceil(
            sizingHeader.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height,
        )
        return max(height, hasTokens ? ceil(sizingHeader.font.lineHeight) : 0)
    }

    @objc dynamic private static func sourceHeight(_ text: String?, width: CGFloat) -> CGFloat {
        guard let text else { return 0 }
        sizingSource.font = .preferredFont(forTextStyle: .caption1)
        sizingSource.numberOfLines = 0
        sizingSource.text = text
        return ceil(sizingSource.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private static func isReasoning(_ message: ChatMessage) -> Bool {
        if case .thinking = message.role {
            return true
        }
        return false
    }

    /// The trace's own page, where a step is shown whole and copied.
    @objc private func openPage(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, onOpenPage != nil else { return }
        onOpenPage?()
    }
}

/// A touch inside the steps belongs to the call under it, never to the
/// summary over it: opening one call must not fold away the others.
extension ChatActivityRow: UIGestureRecognizerDelegate {
    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        return !(view === expansion || view.isDescendant(of: expansion))
    }
}
