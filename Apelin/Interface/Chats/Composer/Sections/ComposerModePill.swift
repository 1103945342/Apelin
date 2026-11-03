import UIKit

/// The pill under the composer: what this run is allowed to do, tapped to
/// change it. Plan, build, automatic, in that order, wrapping round.
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

        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true

        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)

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

    override var intrinsicContentSize: CGSize {
        let height = max(label.font.lineHeight + ComposerMetrics.Spacing.sm, 26)
        let width = max(46, label.intrinsicContentSize.width + ComposerMetrics.Spacing.md * 2)
        return CGSize(width: ceil(width), height: ceil(height))
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

    /// The pill's own word, in capitals, made from the spoken one: a literal
    /// spelled in capitals reads as a string-table key, which `make check`
    /// refuses and for good reason — it is what a SHOUTING_KEY looks like.
    private var title: String {
        spokenTitle.uppercased()
    }

    /// The pill shows a word in capitals; the spoken value is the sentence,
    /// which the screen reader would otherwise spell out letter by letter.
    private var spokenTitle: String {
        switch mode {
        case .plan: String(localized: "Plan")
        case .build: String(localized: "Build")
        case .auto: String(localized: "Automatic")
        }
    }

    @objc private func tapped() {
        mode = mode.next
        ComposerModeStore.mode = mode
        onChange?(mode)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func accessibilityActivate() -> Bool {
        tapped()
        return true
    }
}
