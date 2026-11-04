// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

extension ComposerInputView {
    protocol Delegate: AnyObject {
        func onComposerInputMoreButtonTapped()
        func onComposerInputBeginEditing()
        func onComposerInputEndEditing()
        func onComposerInputSubmitButtonTapped()
        /// Expand was tapped: the same draft, on a page tall enough for it.
        func onComposerInputExpandButtonTapped()
        func onComposerInputPasteAsAttachmentTapped()
        func onComposerInputTextChanged(text: String)
        func onComposerInputPastingLargeTextAsDocument(content: String)
        func onComposerInputPastingImage(image: UIImage)
    }
}
