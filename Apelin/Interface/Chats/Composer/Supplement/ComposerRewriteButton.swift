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

    required init() {
        super.init()
        iconInset = 5
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

    private func updateAppearance() {
        iconView.image = UIImage(systemName: isRewriting ? "stop.fill" : "wand.and.stars")?
            .withRenderingMode(.alwaysTemplate)
        tintColor = isRewriting ? .systemRed : .secondaryLabel
        accessibilityLabel = isRewriting
            ? String(localized: "Stop Rewriting")
            : String(localized: "Rewrite This Message")
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
            height: height,
        ))
    }
}
