import UIKit

/// How full the conversation's context is, at the end of the composer's
/// model row: a ring with the share inside it, tapped to open what the context
/// holds. Hidden until the agent has recorded a figure.
final class ContextUsageButton: UIControl {
    static let size: CGFloat = 24

    private let ring = ProgressRing()
    private let label = UILabel()
    private(set) var usage: ChatContextUsage?

    /// The panel under the row is open: the arc thickens and a chevron takes
    /// the figure's place, so the ring itself answers whether a tap will fold
    /// what it shows.
    private var isExpanded = false
    private let chevron = UIImageView()

    /// Asked for when it is tapped, whatever the ring shows.
    var tapAction: () -> Void = {}

    /// Whether the chat can compact right now, which the panel's button reads.
    /// It has nothing to do with opening the panel: the ring is the way in to
    /// what the context holds, and a running chat has just as much to say.
    var isAvailable = true {
        didSet {
            guard isAvailable != oldValue else { return }
            accessibilityTraits = isAvailable ? .button : [.button, .notEnabled]
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        ring.isUserInteractionEnabled = false
        addSubview(ring)

        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.isUserInteractionEnabled = false
        addSubview(label)

        chevron.image = UIImage(systemName: "chevron.up")?
            .withRenderingMode(.alwaysTemplate)
        chevron.contentMode = .scaleAspectFit
        chevron.isHidden = true
        chevron.isUserInteractionEnabled = false
        addSubview(chevron)

        addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
        // `primaryActionTriggered` reaches a plain `UIControl` only when the
        // system decides it is a button, and on the versions this ships to it
        // does not: the touch itself is the event that always arrives.
        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Context")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.size, height: Self.size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        label.frame = bounds.insetBy(dx: 3, dy: 3)
        let chevronSize = bounds.width * 0.5
        chevron.frame = CGRect(
            x: (bounds.width - chevronSize) / 2,
            y: (bounds.height - chevronSize) / 2,
            width: chevronSize,
            height: chevronSize,
        )
    }

    /// The panel under the row opens or folds: what the ring shows follows.
    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        chevron.isHidden = !expanded
        chevron.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.up")?
            .withRenderingMode(.alwaysTemplate)
        label.isHidden = expanded
        chevron.tintColor = tintColor
        accessibilityValue = expanded
            ? String(localized: "Expanded")
            : usage?.spoken
        accessibilityHint = expanded
            ? String(localized: "Folds the context details.")
            : String(localized: "Opens the context details.")
    }

    /// The tint the arc and the figure share: quiet until the room runs
    /// short, then the colour of a warning.
    private var levelColor: UIColor {
        switch usage?.fraction ?? 0 {
        case 0.9...: .systemRed
        case 0.75...: .systemOrange
        default: .secondaryLabel
        }
    }

    func set(_ usage: ChatContextUsage?) {
        let hadFigure = self.usage != nil
        self.usage = usage
        isHidden = usage == nil
        guard let usage else { return }
        tintColor = levelColor
        label.textColor = levelColor
        chevron.tintColor = levelColor
        label.text = usage.percentText
        accessibilityValue = isExpanded ? String(localized: "Expanded") : usage.spoken
        ring.set(.progress(usage.fraction), animated: hadFigure)
    }

    @objc private func tapped() {
        guard !isHidden else { return }
        // Two events are registered, and a tap can deliver both: take the
        // first only, or the panel would open and shut in one touch.
        guard !isTrackingTap else { return }
        isTrackingTap = true
        DispatchQueue.main.async { [weak self] in self?.isTrackingTap = false }
        tapAction()
    }

    private var isTrackingTap = false

    override var isHighlighted: Bool {
        didSet { updateAlpha() }
    }

    private func updateAlpha() {
        alpha = isHighlighted ? 0.4 : (isAvailable ? 1 : 0.5)
    }

    /// VoiceOver's double tap arrives here through the button trait, and
    /// `primaryActionTriggered` is not sent for it.
    override func accessibilityActivate() -> Bool {
        guard !isHidden else { return false }
        tapAction()
        return true
    }
}
