import UIKit

/// The magic wand beside the draft: a tap asks for the message to be rewritten,
/// and a tap while that runs stops it.
///
/// A rewrite replaces what was typed, so it is offered as something to undo:
/// the reader who does not like the answer must be able to get their own words
/// back, and the composer keeps them for exactly that.
final class ComposerRewriteButton: ComposerIconButton {
    /// A rewrite was asked for, with the draft as it stood.
    var onRewrite: ((String) -> Void)?
    /// The running rewrite was asked to stop.
    var onCancel: (() -> Void)?

    /// Set by the owner: a rewrite is running, so a tap stops rather than
    /// starts one.
    var isRewriting = false {
        didSet {
            guard isRewriting != oldValue else { return }
            updateAppearance()
        }
    }

    /// The text the draft will be read from, asked at the moment of the tap.
    var draftProvider: (() -> String)?

    /// The ring that turns round the stop while a rewrite runs: the stop says
    /// what a tap does, the ring says the answer is still on its way.
    private let spinner = CAShapeLayer()
    private static let spinnerKey = "rewriteSpinner"

    required init() {
        super.init()
        // The same disc as the send, so all the icons that act on the draft are
        // drawn alike: the wand, the plus, the send.
        iconInset = (ComposerMetrics.Send.diameter - ComposerMetrics.Send.iconSize) / 2
        spinner.fillColor = nil
        spinner.lineWidth = 2
        spinner.lineCap = .round
        spinner.strokeStart = 0
        spinner.strokeEnd = 0.72
        spinner.isHidden = true
        // Under the mark, so the stop is drawn on top of the ring's opening.
        layer.insertSublayer(spinner, below: iconView.layer)
        tapAction = { [weak self] in self?.tap() }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    private func tap() {
        if isRewriting {
            onCancel?()
            return
        }
        guard let draft = draftProvider?(), !draft.isEmpty else { return }
        onRewrite?(draft)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The ring is drawn in the button's own coordinates and turns about
        // its centre, so it keeps the same circle at any size the row gives it.
        spinner.frame = bounds
        spinner.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Off screen the ring has nobody to tell: it stops, and picks the turn
        // up again when the composer is back.
        guard window != nil else {
            spinner.removeAnimation(forKey: Self.spinnerKey)
            return
        }
        updateAppearance()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previous) else { return }
        updateAppearance()
    }

    private func updateAppearance() {
        iconView.image = UIImage(systemName: isRewriting ? "stop.fill" : "wand.and.stars")?
            .withRenderingMode(.alwaysTemplate)
        tintColor = isRewriting ? .systemRed : .secondaryLabel
        accessibilityLabel = isRewriting
            ? String(localized: "Stop Rewriting")
            : String(localized: "Rewrite This Message")

        spinner.strokeColor = (isRewriting ? UIColor.systemRed : UIColor.clear)
            .resolvedColor(with: traitCollection).cgColor
        spinner.isHidden = !isRewriting
        guard isRewriting else {
            spinner.removeAnimation(forKey: Self.spinnerKey)
            return
        }
        startSpinning()
    }

    /// The ring turns one way for as long as the rewrite runs, and rests for
    /// anyone who asked the system not to animate: it is then a still circle,
    /// which is the same thing said without movement.
    private func startSpinning() {
        spinner.removeAnimation(forKey: Self.spinnerKey)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = CGFloat.pi * 2
        turn.duration = 0.9
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        spinner.add(turn, forKey: Self.spinnerKey)
    }
}

/// The line above the draft that says a rewrite happened and offers the words
/// back. Present only while there is something to go back to.
final class ComposerRewriteBar: UIView {
    private let label = UILabel()
    private let undoButton = UIButton(type: .system)

    var onUndo: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        label.text = String(localized: "Rewritten")
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel

        undoButton.setTitle(String(localized: "Undo"), for: .normal)
        undoButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        undoButton.titleLabel?.adjustsFontForContentSizeCategory = true
        undoButton.addTarget(self, action: #selector(undoTapped), for: .primaryActionTriggered)
        undoButton.accessibilityLabel = String(localized: "Undo the Rewrite")

        addSubview(label)
        addSubview(undoButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    @objc private func undoTapped() {
        onUndo?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let height = max(label.font.lineHeight, undoButton.intrinsicContentSize.height)
        label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width * 0.6, height: height)
        let undoWidth = undoButton.intrinsicContentSize.width
        undoButton.frame = directionalFrame(CGRect(
            x: bounds.width - undoWidth,
            y: (bounds.height - height) / 2,
            width: undoWidth,
            height: height
        ))
    }
}
