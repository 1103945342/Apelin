import UIKit

/// The pill under the composer: what this run is allowed to do, tapped to
/// change it. Build, plan, automatic, in that order, wrapping round.
///
/// The pill is the only place the setting is changed, and it says what a run
/// will do before one is sent, which is the answer a reader wants from a
/// control they are about to press.
final class ComposerModePill: UIControl {
    private let label = UILabel()

    private(set) var mode: ComposerMode = ComposerModeStore.mode {
        didSet { applyMode() }
    }

    /// Told after the pill changed itself, with the value it took.
    var onChange: ((ComposerMode) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true

        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
        // `primaryActionTriggered` reaches a plain UIControl only when the
        // system decides it is a button; on some versions it does not. The
        // touch itself is the one event that always arrives.
        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        applyMode()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// The setting as something else left it, without telling the delegate.
    func set(mode: ComposerMode) {
        guard self.mode != mode else { return }
        self.mode = mode
    }

    /// The widest the pill grows, whatever the language calls the mode: three
    /// short words at most, so the marks after it keep their place in the row
    /// from one mode to the next, and a long one shrinks inside the badge.
    private static let maxWidth: CGFloat = 96

    override var intrinsicContentSize: CGSize {
        let height = max(label.font.lineHeight + ComposerMetrics.Spacing.sm, 24)
        let width = max(42, label.intrinsicContentSize.width + ComposerMetrics.Spacing.md * 2)
        return CGSize(width: ceil(min(width, Self.maxWidth)), height: ceil(height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: ComposerMetrics.Spacing.xs, dy: 2)
    }

    private func applyMode() {
        let colours = ComposerPalette.mode(for: mode)
        backgroundColor = colours.fill
        label.textColor = colours.label
        label.text = title
        accessibilityLabel = String(localized: "Run Mode")
        accessibilityValue = spokenTitle
        accessibilityHint = String(localized: "Changes what this run may do.")
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The word the pill draws: the mode's own name in the reader's language —
    /// 规划, 构建, 自动模式 — because the badge is the only place the setting is
    /// named and a word nobody can read there names nothing. The screen reader
    /// says the same word.
    private var title: String {
        switch mode {
        case .plan: String(localized: "Plan")
        case .build: String(localized: "Build")
        case .auto: String(localized: "Automatic Mode")
        }
    }

    /// What the screen reader says the setting is.
    private var spokenTitle: String {
        title
    }

    @objc private func tapped() {
        // Two events are registered, and a tap can deliver both: take the
        // first only.
        guard !isTrackingTap else { return }
        isTrackingTap = true
        DispatchQueue.main.async { [weak self] in self?.isTrackingTap = false }
        mode = mode.next
        ComposerModeStore.mode = mode
        onChange?(mode)
    }

    private var isTrackingTap = false

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.6 : 1
            if !isHighlighted, oldValue {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    override func accessibilityActivate() -> Bool {
        tapped()
        return true
    }
}
