// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

extension ComposerInputView {
    protocol Delegate: AnyObject {
        func onComposerInputMoreButtonTapped()
        func onComposerInputBeginEditing()
        func onComposerInputEndEditing()
        func onComposerInputSubmitButtonTapped()
        /// The wand was tapped, with the draft as it stood.
        func onComposerInputRewriteRequested(draft: String)
        /// The wand was tapped again while a rewrite ran.
        func onComposerInputRewriteCancelled()
        func onComposerInputPasteAsAttachmentTapped()
        func onComposerInputTextChanged(text: String)
        func onComposerInputPastingLargeTextAsDocument(content: String)
        func onComposerInputPastingImage(image: UIImage)
    }
}
