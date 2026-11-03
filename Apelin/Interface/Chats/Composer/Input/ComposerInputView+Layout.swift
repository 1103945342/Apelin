// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT I WANT.

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

    /// The text's end, on the band's own row: the wand first, then the expand.
    /// Both sit beside the words they act on — a rewrite works on what is
    /// typed, the expand on a draft that has outgrown the band — and neither
    /// gives up its place to the other, because each has its own.
    private func placeTools(after textWidth: CGFloat) {
        let showsRewrite = hasContent && !isBusy && showsComposerSend
        rewriteButton.alpha = showsRewrite ? 1 : 0
        rewriteButton.isUserInteractionEnabled = showsRewrite

        expandButton.alpha = isOverflowing ? 1 : 0
        expandButton.isUserInteractionEnabled = isOverflowing

        // Leading to trailing: the wand, then the expand, at the text's end.
        // Both keep their frames even while faded out, so the band never moves
        // the words as either appears.
        rewriteButton.frame = CGRect(
            x: textWidth + iconSpacing * 0.5,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        expandButton.frame = CGRect(
            x: rewriteButton.frame.maxX + iconSpacing * 0.5,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
    }

    /// The band is the text and the two tools that act on it; what happens to
    /// a finished draft — the send and the plus — lives on the row beneath,
    /// which the model bar draws.
    private func placeText(fullWidth: Bool) -> CGRect {
        // The tools' room is only taken when one of them is there to take it:
        // a band with nothing to rewrite gives the words the whole row.
        let toolsShown = (hasContent && !isBusy && showsComposerSend) || isOverflowing
        let toolsRoom: CGFloat = toolsShown
            ? iconSize.width * 2 + iconSpacing * 2
            : 0
        let width = fullWidth
            ? bounds.width - inset.left - inset.right
            : bounds.width - inset.left - inset.right - toolsRoom
        let frame = textFrame(width: width)
        textView.frame = frame
        placeholderLabel.frame = frame
        placeTools(after: frame.maxX)
        return frame
    }

    func layoutAsEditingText() {
        cameraButton.frame = CGRect(
            x: 0 - inset.left - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        cameraButton.alpha = 0

        placeText(fullWidth: false)
    }

    func layoutAsPreEditingText() {
        defer { cameraButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }

        cameraButton.frame = CGRect(
            x: 0 - inset.left - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        cameraButton.alpha = 0

        placeText(fullWidth: false)
    }

    func layoutAsStandard() {
        // camera | text | (wand, expand at the text's end)
        cameraButton.frame = directionalFrame(CGRect(
            x: inset.left,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        ))
        cameraButton.alpha = 1
        cameraButton.transform = .identity

        let toolsShown = (hasContent && !isBusy && showsComposerSend) || isOverflowing
        let toolsRoom: CGFloat = toolsShown
            ? iconSize.width * 2 + iconSpacing * 2
            : 0
        let frame = textFrame(
            width: bounds.width - inset.left - inset.right
                - iconSize.width - iconSpacing - toolsRoom,
        )
        textView.frame = CGRect(
            x: cameraButton.frame.maxX + iconSpacing,
            y: frame.origin.y,
            width: max(0, frame.width),
            height: frame.height,
        )
        textView.alpha = 1
        placeholderLabel.frame = textView.frame
        placeTools(after: textView.frame.maxX)
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
