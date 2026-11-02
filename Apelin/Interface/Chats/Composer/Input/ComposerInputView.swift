// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Combine
import UIKit

/// The composer's text band: the text view between its icons, laid out one
/// of three ways. At rest, the camera, the text and More;
/// focused and empty, the camera goes and the text takes its room; with
/// text, More gives way to Send. Right to left, the band is mirrored.
///
/// The band is as tall as the text, from one line to `maxTextEditorHeight`;
/// past that the text scrolls inside it and Expand appears at its corner.
class ComposerInputView: ComposerSectionView {
    let font = UIFont.preferredFont(forTextStyle: .body)
    let textHeight: CurrentValueSubject<CGFloat, Never> = .init(0)
    let maxTextEditorHeight: CGFloat = ComposerMetrics.Input.maxHeight

    let elementClipper = UIView()

    let cameraButton = ComposerIconButton(iconName: "ComposerCamera", label: String(localized: "Camera"))
    let textView = TextEditorView()
    let placeholderLabel = UILabel()
    /// Rewrites the draft: beside Send, only while there is something to
    /// rewrite and no run to interrupt.
    let rewriteButton = ComposerRewriteButton()
    /// Shown once the text has outgrown the band, at its trailing corner: the
    /// same draft, on a page tall enough to see it.
    let expandButton = ComposerIconButton(
        symbolName: "arrow.up.left.and.arrow.down.right",
        label: String(localized: "Expand"),
    )

    /// The tools that act on the draft itself, above it and to its end: a
    /// rewrite of what is typed, and a page to finish it on. They sit outside
    /// the text's own band so neither takes a corner from the words.
    let draftToolsRow = UIView()

    let inset: UIEdgeInsets = ComposerMetrics.Input.inset
    let iconSpacing: CGFloat = ComposerMetrics.Input.iconSpacing
    let iconSize = CGSize(
        width: ComposerMetrics.Input.iconSize,
        height: ComposerMetrics.Input.iconSize,
    )

    enum LayoutStatus {
        case standard
        case preFocusText
        case editingText
    }

    var layoutStatus: LayoutStatus = .standard {
        didSet {
            guard oldValue != layoutStatus else { return }
            setNeedsLayout()
        }
    }

    weak var delegate: Delegate?

    /// Send and the plus belong to the row under the band, not to the band:
    /// they are what happens to a finished draft, not part of typing one.
    var showsComposerSend = true

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
        }
    }

    /// Something would be sent: typed text or an attachment. What decides
    /// whether the send button draws as able.
    var hasContent: Bool = false {
        didSet {
            guard hasContent != oldValue else { return }
            updateSendButton()
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
    /// that opened it folds it away.
    func showPanelState(_ open: Bool) {
        _ = open
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

        cameraButton.tapAction = { [weak self] in
            self?.delegate?.onComposerInputCameraButtonTapped()
        }
        addSubview(elementClipper)
        elementClipper.clipsToBounds = true
        elementClipper.addSubview(cameraButton)
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
                return max(textLayoutHeight(textHeight), iconSize.height)
                    + inset.top + inset.bottom
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

        switch layoutStatus {
        case .standard:
            layoutAsStandard()
        case .preFocusText:
            layoutAsPreEditingText()
        case .editingText:
            layoutAsEditingText()
        }
        // laid out left to right; right to left the camera is on the right
        // and the tools on the left, as the placeholder reads
        elementClipper.mirrorForLayoutDirection(
            [cameraButton, textView, placeholderLabel, expandButton, rewriteButton],
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
