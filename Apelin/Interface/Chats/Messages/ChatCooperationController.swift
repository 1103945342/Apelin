import UIKit

/// What another conversation's agent sent this one, opened from its row
/// (`ChatCooperationRow`): the whole message, selectable, in a sheet.
final class ChatCooperationController: UIViewController {
    private let sender: String?
    private let text: String
    private let textView = UITextView()

    init(sender: String?, text: String) {
        self.sender = sender
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(sender:text:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = sender ?? String(localized: "From another chat")
        view.backgroundColor = .pageBackground
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.textContainer.lineFragmentPadding = 0
        let side = ChatMessageRow.horizontalPadding
        textView.textContainerInset = UIEdgeInsets(top: side, left: side, bottom: side, right: side)
        textView.text = text
        view.addSubview(textView)
        setContentScrollView(textView)
        if #available(iOS 26, *) {
            textView.topEdgeEffect.style = .soft
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        textView.frame = view.bounds
    }
}
