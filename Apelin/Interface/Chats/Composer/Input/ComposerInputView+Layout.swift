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

    /// Expand takes the band's trailing corner while the text has outgrown it.
    /// Send is not here to compete for that corner: it belongs to the row
    /// under the band.
    private func placeExpand(in band: CGRect) {
        let shows = isOverflowing
        expandButton.alpha = shows ? 1 : 0
        expandButton.isUserInteractionEnabled = shows
        expandButton.frame = directionalFrame(CGRect(
            x: band.maxX - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        ))
    }

    /// The wand sits at the band's leading end of the tools row, above the
    /// text: a rewrite acts on what is typed, so it is read before it.
    private func placeRewrite(in tools: CGRect) {
        let shows = hasContent && !isBusy && showsComposerSend
        rewriteButton.alpha = shows ? 1 : 0
        rewriteButton.isUserInteractionEnabled = shows
        rewriteButton.frame = tools
    }

    /// The band is the text and nothing else: the icons that act on a finished
    /// draft — Send and the plus — live on the row beneath it, and the two
    /// tools that act on the draft itself live on the row above.
    private func placeText(fullWidth: Bool) -> CGRect {
        let width = fullWidth
            ? bounds.width - inset.left - inset.right
            : bounds.width - inset.left - inset.right - iconSize.width - iconSpacing
        let frame = textFrame(width: width)
        textView.frame = frame
        placeholderLabel.frame = frame
        placeExpand(in: frame)
        return frame
    }

    /// The tools row is as tall as its icons and sits over the text's end.
    private func toolsFrame() -> CGRect {
        CGRect(
            x: bounds.width - inset.right - iconSize.width * 2 - iconSpacing,
            y: 0,
            width: iconSize.width * 2 + iconSpacing,
            height: iconSize.height,
        )
    }

    func layoutAsEditingText() {
        cameraButton.frame = CGRect(
            x: 0 - inset.left - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        cameraButton.alpha = 0

        let frame = placeText(fullWidth: !isOverflowing)
        let tools = toolsFrame()
        // With text to work on, the wand takes the row's leading seat and
        // Expand its trailing one; neither is drawn when it has nothing to do.
        placeRewrite(in: CGRect(
            x: tools.minX - inset.right,
            y: 0,
            width: iconSize.width,
            height: iconSize.height,
        ))
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
        // Nothing typed: nothing to rewrite.
        rewriteButton.alpha = 0
        rewriteButton.isUserInteractionEnabled = false
    }

    func layoutAsStandard() {
        // camera | text | (tools row takes the trailing corner when it has
        // something to show)
        cameraButton.frame = directionalFrame(CGRect(
            x: inset.left,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        ))
        cameraButton.alpha = 1
        cameraButton.transform = .identity

        let frame = textFrame(
            width: bounds.width - inset.left - inset.right
                - iconSize.width - iconSpacing * 2,
        )
        textView.frame = CGRect(
            x: cameraButton.frame.maxX + iconSpacing,
            y: frame.origin.y,
            width: max(0, frame.width),
            height: frame.height,
        )
        textView.alpha = 1
        placeholderLabel.frame = textView.frame
        placeExpand(in: textView.frame)

        // A draft restored from another conversation is rewritten like a typed
        // one.
        placeRewrite(in: CGRect(
            x: textView.frame.maxX + iconSpacing * 0.5,
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
