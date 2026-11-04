import UIKit

/// The draft, on a page of its own: opened from the band once the text has
/// outgrown it, and writing back as it is typed, so folding it away leaves the
/// composer holding the newest text.
///
/// A page rather than a taller box: on a phone in landscape the band would take
/// more than the screen, and a keyboard over a box that tall leaves nothing to
/// read what was written.
final class ComposerFullScreenEditor: UIViewController {
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let doneButton = UIBarButtonItem()

    private(set) var text: String
    private let placeholderText: String
    private let onDismiss: (String) -> Void

    /// - Parameters:
    ///   - text: what the composer holds now.
    ///   - placeholderText: what to say while it is empty.
    ///   - onDismiss: the text as it stands, every time the page goes away.
    init(text: String, placeholderText: String, onDismiss: @escaping (String) -> Void) {
        self.text = text
        self.placeholderText = placeholderText
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(text:placeholderText:onDismiss:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        title = String(localized: "Draft")

        doneButton.style = .done
        doneButton.target = self
        doneButton.action = #selector(finish)
        doneButton.accessibilityLabel = String(localized: "Done")
        navigationItem.rightBarButtonItem = doneButton
        doneButton.title = String(localized: "Done")

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.alwaysBounceVertical = true
        textView.text = text
        textView.delegate = self
        textView.accessibilityLabel = placeholderText
        view.addSubview(textView)

        placeholderLabel.text = placeholderText
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        view.addSubview(placeholderLabel)

        updatePlaceholder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let inset = view.safeAreaInsets
        let frame = view.bounds.inset(by: UIEdgeInsets(
            top: inset.top + (navigationController?.navigationBar.frame.maxY ?? 0),
            left: inset.left,
            bottom: inset.bottom,
            right: inset.right
        ))
        textView.frame = frame
        placeholderLabel.frame = CGRect(
            x: frame.minX + 16,
            y: frame.minY + 16,
            width: max(0, frame.width - 32),
            height: 0
        )
        placeholderLabel.sizeToFit()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onDismiss(text)
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    @objc private func finish() {
        text = textView.text ?? ""
        dismiss(animated: true)
    }
}

extension ComposerFullScreenEditor: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        text = textView.text ?? ""
        updatePlaceholder()
    }
}
