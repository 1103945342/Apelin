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
                attributes: [.font: font]
            ),
            usingWidth: width
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
            height: height
        )
    }

    /// The text's end, on the band's own row: the wand first, then the expand.
    /// Both sit beside the words they act on — a rewrite works on what is
    /// typed, the expand on a draft that has outgrown the band — and neither
    /// gives up its place to the other, because each has its own.
    private func placeTools(after textWidth: CGFloat) {
        let showsRewrite = hasContent && !isBusy
        rewriteButton.alpha = showsRewrite ? 1 : 0
        rewriteButton.isUserInteractionEnabled = showsRewrite

        expandButton.alpha = isOverflowing ? 1 : 0
        expandButton.isUserInteractionEnabled = isOverflowing

        // The wand is a 36 pt disc, the same measure as the send under it; the
        // expand, the one that leaves when there is room, keeps the band's icon
        // size. Both at the text's end, the wand first, the expand beside it.
        let rewriteSize = ComposerMetrics.Send.diameter
        rewriteButton.frame = CGRect(
            x: textWidth + iconSpacing,
            y: inset.top,
            width: rewriteSize,
            height: rewriteSize
        )
        expandButton.frame = CGRect(
            x: rewriteButton.frame.maxX + iconSpacing,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
    }

    /// One shape, whatever the state: the text takes the band's row, and the
    /// two tools that act on it take the end of that row when they have
    /// something to do. What happens to a finished draft — the send and the
    /// plus — lives on the row beneath, which the model bar draws.
    func layoutTextBand() {
        // The tools' room is only taken when one of them is there to take it:
        // a band with nothing to rewrite gives the words the whole row. The
        // wand takes the send's diameter, the expand the band's icon size.
        let toolsShown = (hasContent && !isBusy) || isOverflowing
        let rewriteRoom = toolsShown ? ComposerMetrics.Send.diameter + iconSpacing : 0
        let expandRoom = toolsShown ? iconSize.width + iconSpacing : 0
        let toolsRoom = rewriteRoom + expandRoom
        let width = bounds.width - inset.left - inset.right - toolsRoom
        let frame = textFrame(width: width)
        textView.frame = frame
        placeholderLabel.frame = frame
        placeTools(after: frame.maxX)
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
