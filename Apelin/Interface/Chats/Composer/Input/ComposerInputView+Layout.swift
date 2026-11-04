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
        // The band no longer has three shapes to choose between — the text
        // takes the whole row whatever the state — but a caller setting the
        // text twice still asks for a layout, and the height it publishes
        // follows.
        setNeedsLayout()
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

    /// The wand at the band's trailing corner, visible when there is something
    /// to rewrite and no run to interrupt.
    private func placeRewriteButton() {
        let showsRewrite = hasContent && !isBusy
        rewriteButton.alpha = showsRewrite ? 1 : 0
        rewriteButton.isUserInteractionEnabled = showsRewrite

        let rewriteSize = ComposerMetrics.Send.diameter
        let x = bounds.width - inset.right - rewriteSize
        rewriteButton.frame = CGRect(
            x: x,
            y: inset.top,
            width: rewriteSize,
            height: rewriteSize,
        )
    }

    /// One shape, whatever the state: the text takes the band's row, and the
    /// wand sits at the trailing corner when there is something to rewrite.
    func layoutTextBand() {
        // The wand takes the send's diameter when visible; text uses the rest.
        let toolsShown = hasContent && !isBusy
        let rewriteRoom = toolsShown ? ComposerMetrics.Send.diameter + iconSpacing : 0
        let width = bounds.width - inset.left - inset.right - rewriteRoom
        let frame = textFrame(width: width)
        textView.frame = frame
        placeholderLabel.frame = frame
        placeRewriteButton()
    }

    func updateOverflowState() {
        // No-op: expand button removed, overflow state no longer tracked
    }
}
