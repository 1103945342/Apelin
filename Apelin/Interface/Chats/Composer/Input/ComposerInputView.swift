// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Combine
import UIKit

/// The composer's text band: the text, with the expand at its right end on
/// the first row, above the row under it that carries what goes out. The band
/// is as tall as the text, from one line to `maxTextEditorHeight`; past that
/// the text scrolls inside it and Expand stays at its corner. Right to left,
/// the band is mirrored.
class ComposerInputView: ComposerSectionView {
    let font = UIFont.preferredFont(forTextStyle: .body)
    let textHeight: CurrentValueSubject<CGFloat, Never> = .init(0)
    let maxTextEditorHeight: CGFloat = ComposerMetrics.Input.maxHeight

    let elementClipper = UIView()

    let textView = TextEditorView()
    let placeholderLabel = UILabel()
    /// At the text's trailing corner, once the draft has outgrown the band:
    /// the same text, on a page tall enough to see it.
    let expandButton = ComposerIconButton(
        symbolName: "arrow.up.left.and.arrow.down.right",
        label: String(localized: "Expand"),
    )

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
            // The placeholder says what a send means now; the band is laid out
            // again for the text it draws.
            setNeedsLayout()
        }
    }

    /// Something would be sent: typed text or an attachment. What decides
    /// whether the send button draws as able.
    var hasContent: Bool = false {
        didSet {
            guard hasContent != oldValue else { return }
            updateSendButton()
            // Nothing in the band draws it any more — the send and the wand
            // are on the row beneath — but the band's own height follows what
            // it is asked to say.
            setNeedsLayout()
        }
    }

    /// The draft is longer than the band: Expand shows.
    var isOverflowing = false {
        didSet {
            guard isOverflowing != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// The import panel is open: the plus draws as a close, so the same tap
    /// that opened it folds it away. The button lives on the row below, which
    /// the composer tells; nothing here draws it any more.
    func showPanelState(_ open: Bool) {
        showsPanelOpen = open
    }

    /// The placeholder says what a send means right now: a message, or one
    /// that waits its turn.
    func updatePlaceholder() {
        let text = isBusy
            ? String(localized: "Message for the next step")
            : String(localized: "Ask anything")
        placeholderLabel.text = text
        textView.accessibilityLabel = text
        updatePlaceholderAlpha()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        delegate = nil
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    override func initializeViews() {
        super.initializeViews()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateReturnKeyType),
            name: .composerBehaviorChanged,
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
        expandButton.tapAction = { [weak self] in
            self?.delegate?.onComposerInputExpandButtonTapped()
        }
        expandButton.alpha = 0
        elementClipper.addSubview(expandButton)

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
        // laid out left to right; right to left the band is mirrored, and the
        // tools follow the text's end as the placeholder reads
        elementClipper.mirrorForLayoutDirection(
            [textView, placeholderLabel, expandButton],
        )

        updatePlaceholderAlpha()
    }

    func set(text: String) {
        textView.text = text
        updatePlaceholderAlpha()
        switchToRequiredStatus()
        updateTextHeight()
        updateOverflowState()
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
}
