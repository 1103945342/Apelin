import UIKit

/// The ruler at the list's trailing edge while the chat scrolls: one tick
/// for each message the reader sent, evenly spaced (owner, 2026-11-06), the
/// one at the top of the page drawn longer and tinted. Dragging along it
/// moves the list from one of the reader's messages to the next, with a
/// card beside the finger saying which one and how it began.
///
/// It shows while the reader moves the list or the ruler, and fades a moment
/// after; with fewer than two of the reader's messages there is nothing to
/// move between, and the system's scroll indicator is left in its place.
/// VoiceOver reaches the same messages through the chat's "Your Messages"
/// rotor, so the ruler itself is drawn only.
final class ChatMessageRuler: UIView {
    struct Entry: Equatable {
        let id: ChatMessage.ID
        let text: String
        let sentAt: Date?
    }

    /// The width the ruler takes at the list's edge: what the finger lands on.
    static let width: CGFloat = 28

    /// The reader dragged onto entry `index`; `settled` once the finger lifts.
    var onSelect: ((_ index: Int, _ settled: Bool) -> Void)?
    /// A drag on the ruler began: the list stops where it is.
    var onScrubBegan: (() -> Void)?

    private(set) var entries: [Entry] = []
    private(set) var isScrubbing = false
    private var currentIndex = 0

    private let track = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let ticks = CAShapeLayer()
    private let current = CAShapeLayer()
    private let preview = RulerPreview()
    private let feedback = UISelectionFeedbackGenerator()
    private var hideWork: DispatchWorkItem?
    private var shown = false

    private static let maximumSpacing: CGFloat = 22
    private static let trackInset: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        alpha = 0
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true

        track.layer.cornerRadius = 4
        track.layer.cornerCurve = .continuous
        track.clipsToBounds = true
        track.isUserInteractionEnabled = false
        addSubview(track)

        ticks.strokeColor = UIColor.secondaryLabel.cgColor
        ticks.lineCap = .round
        layer.addSublayer(ticks)
        current.strokeColor = UIColor.tintColor.cgColor
        current.lineCap = .round
        current.lineWidth = 3
        layer.addSublayer(current)

        preview.alpha = 0
        addSubview(preview)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(scrubbed(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(press)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// The reader's messages in the list, oldest first.
    func show(_ entries: [Entry]) {
        guard entries != self.entries else { return }
        let otherChat = entries.first?.id != self.entries.first?.id
        self.entries = entries
        currentIndex = min(currentIndex, max(0, entries.count - 1))
        if entries.count < 2 || (otherChat && !isScrubbing) {
            setShown(false, animated: false)
        }
        setNeedsLayout()
    }

    /// The entry at the top of the page now, as the list scrolls.
    func setCurrent(_ index: Int) {
        guard !isScrubbing, index != currentIndex, entries.indices.contains(index) else { return }
        currentIndex = index
        drawTicks()
    }

    /// The list is moving under the reader's hand, or has just stopped.
    func listMoved(_ moving: Bool) {
        guard entries.count >= 2 else { return }
        if moving {
            setShown(true, animated: true)
        } else if !isScrubbing {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isScrubbing else { return }
            setShown(false, animated: true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func setShown(_ shown: Bool, animated: Bool) {
        hideWork?.cancel()
        let alpha: CGFloat = shown ? 1 : 0
        guard shown != self.shown || self.alpha != alpha else { return }
        self.shown = shown
        // Only a ruler that can be seen takes a touch: the list keeps its edge
        // the rest of the time.
        isUserInteractionEnabled = shown
        let change = { self.alpha = alpha }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            change()
            return
        }
        UIView.animate(
            withDuration: shown ? 0.15 : 0.3,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: change,
        )
    }

    // MARK: Layout

    /// The y of entry `index`, in this view: evenly spaced, at most
    /// `maximumSpacing` apart, the whole set centred on the track.
    private func position(of index: Int) -> CGFloat {
        let span = trackSpan
        guard entries.count > 1 else { return span.midY }
        let spacing = min(Self.maximumSpacing, span.height / CGFloat(entries.count - 1))
        let used = spacing * CGFloat(entries.count - 1)
        return span.midY - used / 2 + spacing * CGFloat(index)
    }

    private var trackSpan: CGRect {
        bounds.insetBy(dx: 0, dy: Self.trackInset + 4)
    }

    /// The entry nearest `y`.
    private func index(at y: CGFloat) -> Int {
        guard entries.count > 1 else { return 0 }
        let first = position(of: 0)
        let last = position(of: entries.count - 1)
        let fraction = (y - first) / max(1, last - first)
        return min(max(Int((fraction * CGFloat(entries.count - 1)).rounded()), 0), entries.count - 1)
    }

    /// The edge the ticks hang from: the trailing one.
    private var edgeX: CGFloat {
        laysOutRightToLeft ? 6 : bounds.width - 6
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let first = position(of: 0) - Self.trackInset
        let last = position(of: max(0, entries.count - 1)) + Self.trackInset
        track.frame = CGRect(
            x: laysOutRightToLeft ? 1 : bounds.width - 15,
            y: first,
            width: 14,
            height: max(0, last - first),
        )
        drawTicks()
        placePreview()
    }

    private func drawTicks() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let spacing = entries.count > 1 ? abs(position(of: 1) - position(of: 0)) : Self.maximumSpacing
        ticks.lineWidth = spacing >= 4 ? 2 : 1
        let outward: CGFloat = laysOutRightToLeft ? 1 : -1
        let path = UIBezierPath()
        for index in entries.indices where index != currentIndex {
            let y = position(of: index)
            path.move(to: CGPoint(x: edgeX, y: y))
            path.addLine(to: CGPoint(x: edgeX + outward * 6, y: y))
        }
        ticks.path = path.cgPath
        let mark = UIBezierPath()
        if entries.indices.contains(currentIndex) {
            let y = position(of: currentIndex)
            mark.move(to: CGPoint(x: edgeX, y: y))
            mark.addLine(to: CGPoint(x: edgeX + outward * 12, y: y))
        }
        current.path = mark.cgPath
        ticks.strokeColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
        current.strokeColor = tintColor.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        drawTicks()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        drawTicks()
        setNeedsLayout()
    }

    // MARK: Scrubbing

    @objc private func scrubbed(_ press: UILongPressGestureRecognizer) {
        guard !entries.isEmpty else { return }
        let y = press.location(in: self).y
        switch press.state {
        case .began:
            isScrubbing = true
            hideWork?.cancel()
            feedback.prepare()
            onScrubBegan?()
            select(index(at: y), settled: false, force: true)
            setPreviewShown(true)
        case .changed:
            select(index(at: y), settled: false, force: false)
        case .ended, .cancelled, .failed:
            isScrubbing = false
            onSelect?(currentIndex, true)
            setPreviewShown(false)
            scheduleHide()
        default:
            break
        }
    }

    private func select(_ index: Int, settled: Bool, force: Bool) {
        guard force || index != currentIndex else { return }
        if index != currentIndex {
            feedback.selectionChanged()
            feedback.prepare()
        }
        currentIndex = index
        drawTicks()
        preview.show(entries[index], number: index + 1, of: entries.count)
        placePreview()
        onSelect?(index, settled)
    }

    private func setPreviewShown(_ shown: Bool) {
        let change = { self.preview.alpha = shown ? 1 : 0 }
        guard !UIAccessibility.isReduceMotionEnabled else {
            change()
            return
        }
        UIView.animate(withDuration: shown ? 0.12 : 0.2, delay: 0, options: [.beginFromCurrentState], animations: change)
    }

    /// The card beside the ruler, level with the entry, kept on the track.
    private func placePreview() {
        guard entries.indices.contains(currentIndex) else { return }
        let width = min(260, max(160, (superview?.bounds.width ?? 320) * 0.62))
        let size = preview.size(forWidth: width)
        let y = min(max(position(of: currentIndex) - size.height / 2, 0), max(0, bounds.height - size.height))
        let x = laysOutRightToLeft ? bounds.width + 8 : -size.width - 8
        preview.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// A touch on the card is the list's: only the ruler's own strip scrubs.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }
}

/// The card shown while the ruler is dragged: which of the reader's messages
/// it is, when it was sent, and how it began.
private final class RulerPreview: UIView {
    private let ground = GlassSurfaceView(cornerRadius: 12)
    private let headLabel = UILabel()
    private let textLabel = UILabel()
    private static let padding = UIEdgeInsets(top: 8, left: 12, bottom: 9, right: 12)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(ground)

        headLabel.font = .preferredFont(forTextStyle: .caption2)
        headLabel.adjustsFontForContentSizeCategory = true
        headLabel.textColor = .secondaryLabel
        headLabel.numberOfLines = 1
        addSubview(headLabel)

        textLabel.font = .preferredFont(forTextStyle: .footnote)
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.textColor = .label
        textLabel.numberOfLines = 3
        textLabel.lineBreakMode = .byTruncatingTail
        addSubview(textLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ entry: ChatMessageRuler.Entry, number: Int, of total: Int) {
        var head = String(localized: "Message \(number) of \(total)")
        if let sent = entry.sentAt {
            let time = Calendar.current.isDateInToday(sent)
                ? sent.formatted(date: .omitted, time: .shortened)
                : sent.formatted(date: .abbreviated, time: .shortened)
            head += " · " + time
        }
        headLabel.text = head
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        textLabel.text = text.isEmpty ? String(localized: "Attachment") : text
        textLabel.textAlignment = laysOutRightToLeft ? .right : .left
        headLabel.textAlignment = textLabel.textAlignment
        setNeedsLayout()
    }

    func size(forWidth width: CGFloat) -> CGSize {
        let inner = width - Self.padding.left - Self.padding.right
        let head = headLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude))
        let text = textLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude))
        let used = min(inner, max(ceil(head.width), ceil(text.width)))
        return CGSize(
            width: used + Self.padding.left + Self.padding.right,
            height: ceil(head.height) + 2 + ceil(text.height) + Self.padding.top + Self.padding.bottom,
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ground.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
        let inner = bounds.inset(by: Self.padding)
        let head = headLabel.sizeThatFits(CGSize(width: inner.width, height: .greatestFiniteMagnitude))
        headLabel.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: ceil(head.height))
        textLabel.frame = CGRect(
            x: inner.minX,
            y: headLabel.frame.maxY + 2,
            width: inner.width,
            height: max(0, inner.maxY - headLabel.frame.maxY - 2),
        )
    }
}
