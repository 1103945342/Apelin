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

    /// The text's end, on the band's own row: the expand, once a draft has
    /// outgrown the band. It sits beside the words it acts on — the expand on
    /// a draft too long to see — and keeps its frame while faded out, so the
    /// band never moves the words as it appears.
    private func placeTools(after textWidth: CGFloat) {
        expandButton.alpha = isOverflowing ? 1 : 0
        expandButton.isUserInteractionEnabled = isOverflowing

        expandButton.frame = CGRect(
            x: textWidth + iconSpacing,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
    }

    /// One shape, whatever the state: the text takes the band's row, and the
    /// one tool that acts on it takes the end of that row when it has
    /// something to do. What happens to a finished draft — the send and the
    /// plus — lives on the row beneath, which the model bar draws, and the
    /// wand lives there with them.
    func layoutTextBand() {
        // The tool's room is only taken when it is there to take it: a band
        // that fits its words gives them the whole row.
        let toolsRoom: CGFloat = isOverflowing ? iconSize.width + iconSpacing : 0
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
