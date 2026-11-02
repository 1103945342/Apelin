// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

extension ComposerInputView {
    func textLayoutHeight(_ input: CGFloat) -> CGFloat {
        var finalHeight = input
        finalHeight = max(font.lineHeight, finalHeight)
        finalHeight = min(finalHeight, maxTextEditorHeight)
        return ceil(finalHeight)
    }

    /// How tall the text would be were the band as wide as it is: what tells
    /// the band its text has outgrown it.
    ///
    /// Counted rather than guessed from line breaks: a long paragraph wraps
    /// without one, and a band that measured by newlines would show Expand only
    /// once the reader pressed return.
    private func measuredTextHeight() -> CGFloat {
        let width = textView.bounds.width
        guard width > 0, let text = textView.text, !text.isEmpty else { return font.lineHeight }
        let measured = TextMeasurement.shared.measureSize(
            of: NSAttributedString(
                string: text,
                attributes: [.font: font],
            ),
            usingWidth: width,
        ).height
        return ceil(max(measured, font.lineHeight))
    }

    /// One line's worth of room inside the band, either side of the text.
    private var textRoomHeight: CGFloat {
        maxTextEditorHeight - inset.top - inset.bottom
    }

    func switchToRequiredStatus() {
        assert(Thread.isMainThread)
        // avoid flickering animation if set twice
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(switchToRequiredStatusEx),
            object: nil,
        )
        perform(#selector(switchToRequiredStatusEx), with: nil, afterDelay: 0.1)
    }

    @objc private func switchToRequiredStatusEx() {
        doWithAnimation { [self] in
            cameraButton.transform = .identity
            moreButton.transform = .identity
            sendButton.transform = .identity
            if textView.isFirstResponder {
                if textView.text.isEmpty, !hasAttachments {
                    layoutStatus = .preFocusText
                } else {
                    layoutStatus = .editingText
                }
            } else {
                if textView.text.isEmpty, !hasAttachments {
                    layoutStatus = .standard
                } else {
                    layoutStatus = .editingText
                }
            }
        }
    }

    /// Where the text starts: the band's own inset, and the text sits against
    /// the top rather than centred, so a growing draft grows downward and the
    /// first line stays where the reader left it.
    private func textFrame(width: CGFloat) -> CGRect {
        let height = textLayoutHeight(textHeight.value)
        return CGRect(
            x: inset.left,
            y: inset.top,
            width: max(0, width),
            height: height,
        )
    }

    /// Expand takes a corner of the band only while the text has outgrown it,
    /// and never while Send has that corner.
    private func placeExpand(in band: CGRect) {
        let shows = isOverflowing && sendButton.alpha == 0
        expandButton.alpha = shows ? 1 : 0
        expandButton.isUserInteractionEnabled = shows
        expandButton.frame = CGRect(
            x: band.maxX - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
    }

    /// The wand sits just before Send, and shows only when there is something
    /// to rewrite and nothing else is holding the band: a rewrite during a run
    /// would race the message the run is taking.
    private func placeRewrite(before send: CGRect) {
        let shows = hasContent && !isBusy && send.alpha > 0
        rewriteButton.alpha = shows ? 1 : 0
        rewriteButton.isUserInteractionEnabled = shows
        rewriteButton.frame = CGRect(
            x: send.minX - iconSize.width - iconSpacing * 0.5,
            y: send.minY,
            width: iconSize.width,
            height: iconSize.height,
        )
    }

    func layoutAsEditingText() {
        // textField | sendButton
        let corner = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: bounds.height - iconSize.height - inset.bottom,
            width: iconSize.width,
            height: iconSize.height,
        )
        sendButton.frame = corner
        sendButton.alpha = 1
        moreButton.frame = corner
        defer { moreButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        moreButton.alpha = 0

        let trailingRoom = sendButton.frame.minX - inset.left - iconSpacing
        let frame = textFrame(width: trailingRoom)
        textView.frame = frame
        placeholderLabel.frame = frame
        placeExpand(in: frame)
        placeRewrite(before: sendButton.frame)

        // invisible element
        cameraButton.frame = CGRect(
            x: 0 - inset.left - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        cameraButton.alpha = 0
    }

    func layoutAsPreEditingText() {
        defer { cameraButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        defer { sendButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }

        // invisible elements
        cameraButton.frame = CGRect(
            x: 0 - inset.left - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        cameraButton.alpha = 0

        moreButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        moreButton.alpha = 1
        // reset textField width to fill the space
        let frame = textFrame(width: moreButton.frame.minX - inset.left - iconSpacing)
        textView.frame = frame
        textView.alpha = 1
        placeholderLabel.frame = frame
        placeExpand(in: frame)

        // invisible element
        sendButton.frame = CGRect(
            x: bounds.width + iconSpacing + inset.right,
            y: bounds.height - iconSize.height - inset.bottom,
            width: iconSize.width,
            height: iconSize.height,
        )
        sendButton.alpha = 0
        // Nothing typed: nothing to rewrite.
        rewriteButton.alpha = 0
        rewriteButton.isUserInteractionEnabled = false
    }

    func layoutAsStandard() {
        defer { sendButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }

        // captureButton | textField | moreButton
        cameraButton.frame = CGRect(
            x: inset.left,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        cameraButton.alpha = 1
        moreButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        moreButton.alpha = 1
        moreButton.transform = .identity
        // reset textField width to fill the space
        let frame = textFrame(
            width: moreButton.frame.minX - cameraButton.frame.maxX - iconSpacing * 2,
        )
        textView.frame = CGRect(
            x: cameraButton.frame.maxX + iconSpacing,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height,
        )
        textView.alpha = 1
        placeholderLabel.frame = textView.frame
        placeExpand(in: textView.frame)

        // invisible element
        sendButton.frame = CGRect(
            x: bounds.width + inset.right,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        sendButton.alpha = 0
        // A draft restored from another conversation is rewritten like a typed
        // one.
        placeRewrite(before: CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        ))
    }

    /// The text outgrew the band: rewrite what is drawn, then measure up. Called
    /// on every edit, from `textViewDidChange`.
    func updateOverflowState() {
        let overflows = measuredTextHeight() > textRoomHeight
        guard overflows != isOverflowing else { return }
        isOverflowing = overflows
        expandButton.accessibilityLabel = overflows
            ? String(localized: "Expand")
            : nil
    }
}
