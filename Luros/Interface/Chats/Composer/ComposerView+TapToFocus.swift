// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// A tap anywhere on the card puts the keyboard up: the ground around the
/// draft, the empty ends of the model row, the air between the bands. The text
/// band was the only place a tap was answered, and the band is shorter than the
/// card it sits on — most of what a reader sees is not it.
///
/// What is already a control keeps its own tap, and the words keep theirs: a
/// tap in the text places the caret where it landed, which is not a keyboard
/// this gesture has to bring up.
extension ComposerView: UIGestureRecognizerDelegate {
    /// Installed once, from `initializeViews`.
    func installFocusTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap))
        tap.delegate = self
        // The bands under it still get their touches: this only adds the
        // keyboard, it never takes a tap away from what was under it.
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    @objc private func handleFocusTap() {
        guard !inputEditor.textView.isFirstResponder else { return }
        beginEditing()
        // The caret a view keeps while it is not first responder can be older
        // than the draft — a restored one is typed nowhere — so the tap puts it
        // at the end, where a reader who tapped the card means to go on.
        let end = (inputEditor.textView.text as NSString).length
        inputEditor.textView.selectedRange = NSRange(location: end, length: 0)
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // A request is being answered: the card is the request's, and the
        // keyboard would cover it.
        guard !approvalSection.isPresentingRequest else { return false }
        var view: UIView? = touch.view
        while let current = view, current !== self {
            // A control acts on its own tap; the text places its own caret.
            if current is UIControl { return false }
            if current === inputEditor.textView { return false }
            // The bars and panels above the card are read, not typed in — and
            // the import panel is a grid of its own controls, so the whole band
            // is left alone rather than each button in it.
            if current === attachmentsBar || current === rewriteBar
                || current === controlPanel || current === contextPanel
                || current === queuePanel || current === todoPanel
                || current === commandMenu || current === mentionMenu
            {
                return false
            }
            view = current.superview
        }
        return true
    }
}
