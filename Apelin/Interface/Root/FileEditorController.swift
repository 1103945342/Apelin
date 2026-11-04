import AlertController
import Runestone
import RunestoneLanguageSupport
import SnapKit
import Then
import UIKit

/// One of a project's files, open for reading and writing in the sidebar's
/// files page.
///
/// Runestone draws it, so a Swift file is highlighted as Swift and a
/// `Makefile` as make; a file the editor has no grammar for opens as plain
/// text rather than not at all. Closing asks before an edit is thrown away,
/// because a sheet that vanishes takes the typing with it.
final class FileEditorController: UIViewController {
    /// Called after a save, so the page behind can show the new size.
    var onSaved: (() -> Void)?

    private let url: URL
    private let relativePath: String
    private let textView = TextView().then {
        $0.showLineNumbers = true
        $0.autocorrectionType = .no
        $0.autocapitalizationType = .none
        $0.smartQuotesType = .no
        $0.smartDashesType = .no
        $0.smartInsertDeleteType = .no
        $0.spellCheckingType = .no
        $0.keyboardDismissMode = .interactive
        if #available(iOS 16, *) { $0.isFindInteractionEnabled = true }
    }

    private let theme = ApelinEditorTheme()
    /// What the file held when it was opened, to tell an edit from a redraw.
    private var openedText: String?

    private var isDirty = false {
        didSet {
            guard isDirty != oldValue else { return }
            saveItem.isEnabled = isDirty
        }
    }

    /// Whether a save is running, so a second tap does not write twice.
    private var isSaving = false

    private lazy var saveItem = UIBarButtonItem(
        title: String(localized: "Save"),
        primaryAction: UIAction { [weak self] _ in self?.save() },
    ).then {
        $0.style = .done
        $0.isEnabled = false
    }

    private lazy var spinner = UIActivityIndicatorView(style: .medium).then {
        $0.hidesWhenStopped = true
    }

    private lazy var failureLabel = UILabel().then {
        $0.font = UIFont.preferredFont(forTextStyle: .callout)
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.numberOfLines = 0
        $0.isHidden = true
    }

    init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.backgroundColor
        title = (relativePath as NSString).lastPathComponent
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = saveItem
        // The sheet helper puts a cross here that would drop the edit; this
        // one asks first.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.close() },
        ).then { $0.accessibilityLabel = String(localized: "Close") }

        view.addSubview(textView)
        view.addSubview(spinner)
        view.addSubview(failureLabel)
        textView.snp.makeConstraints { x in
            x.edges.equalTo(view.safeAreaLayoutGuide)
        }
        spinner.snp.makeConstraints { x in x.center.equalTo(view.safeAreaLayoutGuide) }
        failureLabel.snp.makeConstraints { x in
            x.center.equalTo(view.safeAreaLayoutGuide)
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(24)
        }

        spinner.startAnimating()
        load()
    }

    private func load() {
        let url = url
        Task { [weak self] in
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try ProjectFileContent.read(at: url)
                }.value
                self?.show(text)
            } catch {
                self?.show(error)
            }
        }
    }

    /// Builds the highlighted state off the main thread: a large file parsed
    /// for the first time would otherwise hold the sheet blank while it did.
    private func show(_ text: String) {
        openedText = text
        let theme = theme
        let fileName = relativePath
        Task { [weak self] in
            let state = await Task.detached(priority: .userInitiated) {
                if let language = RunestoneLanguage(fileName: fileName) {
                    return TextViewState(text: text, theme: theme, language: language.treeSitterLanguage)
                }
                return TextViewState(text: text, theme: theme)
            }.value
            guard let self else { return }
            spinner.stopAnimating()
            textView.backgroundColor = theme.backgroundColor
            textView.setState(state)
            textView.editorDelegate = self
            textView.becomeFirstResponder()
        }
    }

    private func show(_ error: Error) {
        spinner.stopAnimating()
        failureLabel.isHidden = false
        failureLabel.text = error.readableMessage
        // A file the editor cannot show is still a file the reader may want
        // to know about; nothing here writes it.
        saveItem.isEnabled = false
    }

    private func save() {
        guard isDirty, !isSaving else { return }
        isSaving = true
        let text = textView.text
        let url = url
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ProjectFileContent.write(text, to: url)
                }.value
                guard let self else { return }
                isSaving = false
                openedText = text
                isDirty = false
                onSaved?()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                guard let self else { return }
                isSaving = false
                presentNotice(title: "Unable to Save", message: error.readableMessage)
            }
        }
    }

    /// Leaves, asking about an edit that is not saved: a sheet closed by
    /// accident should not take a file's changes with it, and one closed on
    /// purpose should not save what the reader meant to drop.
    private func close() {
        guard isDirty else {
            dismiss(animated: true)
            return
        }
        let alert = AlertViewController(
            title: "Save Changes?",
            message: "“\((relativePath as NSString).lastPathComponent)” has changes that are not saved.",
        ) { [weak self] context in
            guard let self else { return }
            context.addAction(title: "Cancel") { context.dispose() }
            context.addAction(title: "Discard") {
                context.dispose { [weak self] in self?.dismiss(animated: true) }
            }
            context.addAction(title: "Save", attribute: .accent) {
                context.dispose { [weak self] in
                    guard let self else { return }
                    save()
                    dismiss(animated: true)
                }
            }
        }
        present(alert, animated: true)
    }
}

extension FileEditorController: TextViewDelegate {
    func textViewDidChange(_ textView: TextView) {
        guard let openedText else { return }
        isDirty = textView.text != openedText
    }
}
