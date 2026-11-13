// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Combine
import UIKit

/// The composer's text band: the text, with the wand and the expand at its
/// right end on the first row, above the row under it that carries what goes
/// out. The band is as tall as the text, from one line to `maxTextEditorHeight`;
/// past that the text scrolls inside it and Expand stays at its corner. Right
/// to left, the band is mirrored.
class ComposerInputView: ComposerSectionView {
    let font = UIFont.preferredFont(forTextStyle: .body)
    let textHeight: CurrentValueSubject<CGFloat, Never> = .init(0)
    let maxTextEditorHeight: CGFloat = ComposerMetrics.Input.maxHeight

    let elementClipper = UIView()

    let textView = TextEditorView()
    let placeholderLabel = UILabel()
    /// The tips the empty box shows in place of a placeholder, rolled under
    /// the label every few seconds. Made in `initializeViews`.
    private var tipRoller: ComposerTipRoller?
    /// Whether the placeholder is the thing the band is showing, as the text
    /// last decided. Kept because a roll animates the label's own alpha, and
    /// a layout pass must not cut that animation short.
    private var showsPlaceholder = true
    /// Rewrites the draft, beside the text's end on the band's own row:
    /// visible while there is something to rewrite and no run to interrupt.
    let rewriteButton = ComposerRewriteButton()

    let inset: UIEdgeInsets = ComposerMetrics.Input.inset
    let iconSpacing: CGFloat = ComposerMetrics.Input.iconSpacing
    let iconSize = CGSize(
        width: ComposerMetrics.Input.iconSize,
        height: ComposerMetrics.Input.iconSize,
    )

    weak var delegate: Delegate?

    /// The import panel is open, as the row below draws its plus.
    private(set) var showsPanelOpen = false

    var hasAttachments = false {
        didSet {
            if hasAttachments != oldValue {
                switchToRequiredStatus()
            }
        }
    }

    /// A run is going: the send button becomes the run's stop while nothing is
    /// typed, and keeps sending (a message that waits its turn) while there is.
    var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            updateSendButton()
            // The wand leaves while a run is going, as it does when the draft
            // empties: the frame it leaves behind is laid out again.
            setNeedsLayout()
        }
    }

    /// Something would be sent: typed text or an attachment. What decides
    /// whether the send button draws as able.
    var hasContent: Bool = false {
        didSet {
            guard hasContent != oldValue else { return }
            updateSendButton()
            setNeedsLayout()
        }
    }

    /// The import panel is open: the plus draws as a close, so the same tap
    /// that opened it folds it away. The button lives on the row below, which
    /// the composer tells; nothing here draws it any more.
    func showPanelState(_ open: Bool) {
        showsPanelOpen = open
    }

    /// Something in the transcript is open — a turn's process, a thought, a
    /// call — so the box leads with the tip about folding it back. Led once
    /// per opening, not on every layout.
    var showsExpandedProcess = false {
        didSet {
            guard showsExpandedProcess, !oldValue else { return }
            tipRoller?.lead(ComposerTips.collapseHint)
        }
    }

    /// The placeholder is a tip now, and it rolls while the box is empty. What
    /// a send means right now — a message, or one that waits its turn — is
    /// drawn on the send button, so this line is free to teach.
    func updatePlaceholder() {
        refreshTipRotation()
    }

    /// The roll follows the text: it runs while the box is empty and rests on
    /// the tip it reached once there is something typed over it.
    func refreshTipRotation() {
        tipRoller?.setActive(textView.text.isEmpty)
    }

    /// Shows or hides the tip, as the text decides. A change here cuts short
    /// a roll that was running its own fade: the text outranks the animation,
    /// and the next roll starts clean from the line it is on.
    func setPlaceholderVisible(_ visible: Bool) {
        refreshTipRotation()
        guard visible != showsPlaceholder else { return }
        showsPlaceholder = visible
        placeholderLabel.layer.removeAllAnimations()
        placeholderLabel.transform = .identity
        placeholderLabel.alpha = visible ? 1 : 0
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        tipRoller?.stop()
        delegate = nil
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // Off the page nobody reads it: the clock stops with the view, and
        // comes back on the line it left.
        tipRoller?.setActive(newWindow != nil && textView.text.isEmpty)
    }

    override func initializeViews() {
        super.initializeViews()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateReturnKeyType),
            name: .composerBehaviorChanged,
            object: nil,
        )
        // VoiceOver stops the roll while it runs; this is what starts it again
        // once it is off.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(voiceOverStatusChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil,
        )

        addSubview(elementClipper)
        elementClipper.clipsToBounds = true
        textView.font = font
        textView.delegate = self
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.alwaysBounceHorizontal = false
        textView.textColor = .label
        textView.textAlignment = .natural
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineBreakMode = .byTruncatingTail
        textView.textContainer.lineFragmentPadding = .zero
        textView.textContainer.maximumNumberOfLines = 0
        textView.clipsToBounds = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.isEditable = true
        textView.onReturnKeyPressed = { [weak self] in
            guard let self else { return }
            if ComposerBehavior.useConfirmationOnSend {
                textView.insertText("\n")
            } else {
                delegate?.onComposerInputSubmitButtonTapped()
            }
        }
        textView.onCommandReturnKeyPressed = { [weak self] in
            self?.delegate?.onComposerInputSubmitButtonTapped()
        }
        textView.onImagePasted = { [weak self] image in
            self?.delegate?.onComposerInputPastingImage(image: image)
        }
        elementClipper.addSubview(textView)
        placeholderLabel.font = font
        placeholderLabel.textColor = .placeholderText
        // the text view is named by it instead; read twice otherwise
        placeholderLabel.isAccessibilityElement = false
        elementClipper.addSubview(placeholderLabel)

        // The tips the empty box shows, rolled in place of a placeholder.
        let roller = ComposerTipRoller(label: placeholderLabel, tips: ComposerTips.all)
        roller.isVisible = { [weak self] in
            guard let self else { return false }
            return textView.text.isEmpty && window != nil
        }
        roller.onShow = { [weak self] tip in
            // the text view is named by the placeholder instead, and it is
            // the one thing a reader can focus
            self?.textView.accessibilityLabel = tip
        }
        tipRoller = roller
        elementClipper.addSubview(rewriteButton)
        rewriteButton.draftProvider = { [weak self] in self?.textView.text ?? "" }
        rewriteButton.onRewrite = { [weak self] draft in
            self?.delegate?.onComposerInputRewriteRequested(draft: draft)
        }
        rewriteButton.onCancel = { [weak self] in
            self?.delegate?.onComposerInputRewriteCancelled()
        }

        // the icons and the rest of the band share a height of 30;
        // the band is max(30, textHeight) plus the insets
        textHeight.removeDuplicates()
            .compactMap { [weak self] textHeight -> CGFloat? in
                guard let self else { return nil }
                // Room to write before a word is typed, and the band grows
                // from there: it is the one thing in the card a reader writes
                // in, and the row under it is theirs to read.
                return max(
                    max(textLayoutHeight(textHeight), iconSize.height) + inset.top + inset.bottom,
                    ComposerMetrics.Input.minHeight,
                )
            }
            .ensureMainThread()
            .sink { [weak self] height in self?.heightPublisher.send(height) }
            .store(in: &cancellables)
        updatePlaceholder()
        updateReturnKeyType()
        updateTextHeight()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        elementClipper.frame = bounds

        layoutTextBand()
        elementClipper.mirrorForLayoutDirection(
            [textView, placeholderLabel, rewriteButton],
        )

        updatePlaceholderAlpha()
    }

    func set(text: String) {
        textView.text = text
        updatePlaceholderAlpha()
        switchToRequiredStatus()
        updateTextHeight()
    }

    /// The send is drawn on the row beneath the band; this band only reports
    /// what a send would mean, and the row paints it.
    func updateSendButton() {
        updatePlaceholder()
    }

    @objc func updateReturnKeyType() {
        switch ComposerBehavior.useConfirmationOnSend {
        case true:
            textView.returnKeyType = .default
        case false:
            textView.returnKeyType = .send
        }
    }

    /// VoiceOver turned on or off: the roll holds still while it runs, and
    /// starts from the tip it was on once it is off.
    @objc dynamic func voiceOverStatusChanged() {
        tipRoller?.setActive(textView.text.isEmpty)
    }
}
