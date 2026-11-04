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
/// text rather than not at all. A file opens to be read: no keyboard, and
/// nothing to type on, until the pencil on the bar is tapped. Closing asks
/// before an edit is thrown away, because a sheet that vanishes takes the
/// typing with it.
final class FileEditorController: UIViewController {
    /// Called after a save, so the page behind can show the new size.
    var onSaved: (() -> Void)?

    private let url: URL
    private let relativePath: String
    /// The line to put the caret on once the file is on screen: a content
    /// search opens a file where its text is, not at its first line.
    private let line: Int?
    private let textView = TextView().then {
        $0.showLineNumbers = true
        // opened to be read: the pencil on the bar makes it writable
        $0.isEditable = false
        $0.autocorrectionType = .no
        $0.autocapitalizationType = .none
        $0.smartQuotesType = .no
        $0.smartDashesType = .no
        $0.smartInsertDeleteType = .no
        $0.spellCheckingType = .no
        $0.keyboardDismissMode = .interactive
        if #available(iOS 16, *) { $0.isFindInteractionEnabled = true }
    }

    private let searchBar = UISearchBar().then {
        $0.placeholder = String(localized: "Search")
        $0.searchBarStyle = .minimal
        $0.showsBookmarkButton = true
        // The bookmark button becomes the case-sensitive toggle
        $0.setImage(UIImage(systemName: "textformat"), for: .bookmark, state: .normal)
    }

    private let theme = ApelinEditorTheme()
    /// What the file held when it was opened, to tell an edit from a redraw.
    /// `nil` until the file is on screen, and for a file that failed to load.
    private var openedText: String?

    /// Whether the file is open for writing. Not `isEditing`: that is
    /// `UIViewController`'s own, and this one says the file is being
    /// written, not the view.
    private var isWriting = false

    private var isDirty = false {
        didSet {
            guard isDirty != oldValue else { return }
            applyBarItem()
        }
    }

    /// Whether a save is running, so a second tap does not write twice.
    private var isSaving = false {
        didSet { applyBarItem() }
    }

    /// The keyboard's bottom inset, tracked to avoid covering the text.
    private var keyboardHeight: CGFloat = 0

    /// Whether case-sensitive search is on.
    private var isCaseSensitive = false

    /// The bar while nothing is unsaved: the way into writing, and out of it
    /// again before anything is typed.
    private lazy var editItem = UIBarButtonItem(
        image: UIImage(systemName: "pencil"),
        primaryAction: UIAction { [weak self] _ in self?.beginEditing() },
    ).then {
        $0.accessibilityLabel = String(localized: "Edit")
    }

    private lazy var saveItem = UIBarButtonItem(
        title: String(localized: "Save"),
        primaryAction: UIAction { [weak self] _ in self?.save() },
    ).then {
        $0.style = .done
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

    init(url: URL, relativePath: String, line: Int? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.line = line
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.backgroundColor
        title = (relativePath as NSString).lastPathComponent
        navigationItem.largeTitleDisplayMode = .never
        applyBarItem()
        // The sheet helper puts a cross here that would drop the edit; this
        // one asks first.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in self?.close() },
        ).then { $0.accessibilityLabel = String(localized: "Close") }

        // Keyboard toolbar with Done button
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let doneButton = UIBarButtonItem(
            title: String(localized: "Done"),
            style: .done,
            target: self,
            action: #selector(dismissKeyboard)
        )
        toolbar.items = [UIBarButtonItem.flexibleSpace(), doneButton]
        textView.inputAccessoryView = toolbar

        // Search bar setup
        searchBar.delegate = self
        view.addSubview(searchBar)

        view.addSubview(textView)
        view.addSubview(spinner)
        view.addSubview(failureLabel)
        
        searchBar.snp.makeConstraints { x in
            x.top.equalTo(view.safeAreaLayoutGuide)
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            // A search bar has no height of its own to trust: without this it
            // can lay out as a hairline the reader never sees.
            x.height.equalTo(52)
        }
        textView.snp.makeConstraints { x in
            x.top.equalTo(searchBar.snp.bottom)
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            x.bottom.equalTo(view.safeAreaLayoutGuide)
        }
        spinner.snp.makeConstraints { x in x.center.equalTo(view.safeAreaLayoutGuide) }
        failureLabel.snp.makeConstraints { x in
            x.center.equalTo(view.safeAreaLayoutGuide)
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(24)
        }

        // Keyboard notifications for avoiding obstruction
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )

        spinner.startAnimating()
        load()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func dismissKeyboard() {
        textView.resignFirstResponder()
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        keyboardHeight = frame.height
        updateTextViewInsets()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardHeight = 0
        updateTextViewInsets()
    }

    private func updateTextViewInsets() {
        textView.snp.updateConstraints { x in
            x.bottom.equalTo(view.safeAreaLayoutGuide).inset(keyboardHeight)
        }
        UIView.animate(withDuration: 0.25) {
            self.view.layoutIfNeeded()
        } completion: { [weak self] _ in
            self?.revealCaret()
        }
    }

    /// Brings the insertion point into the part of the page the keyboard leaves
    /// visible: tapping a line near the foot of a file would otherwise put the
    /// caret behind the keyboard, where nothing typed there can be read.
    private func revealCaret() {
        guard textView.isFirstResponder else { return }
        textView.scrollRangeToVisible(textView.selectedRange)
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
            // shown to be read: the keyboard is the pencil's, not the file's
            textView.isEditable = isWriting
            applyBarItem()
            if let line { reveal(line: line) }
        }
    }

    /// Puts the caret on a line and brings it into view: what a content search
    /// opens a file for.
    private func reveal(line: Int) {
        let text = textView.text as NSString
        var number = 1
        var location = 0
        while number < line, location < text.length {
            let found = text.range(
                of: "\n",
                range: NSRange(location: location, length: text.length - location),
            )
            guard found.location != NSNotFound else { break }
            location = found.location + 1
            number += 1
        }
        let range = NSRange(location: min(location, text.length), length: 0)
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
    }

    private func show(_ error: Error) {
        spinner.stopAnimating()
        failureLabel.isHidden = false
        failureLabel.text = error.readableMessage
        // A file the editor cannot show is still a file the reader may want
        // to know about; nothing here writes it, so there is nothing to edit.
        applyBarItem()
    }

    /// The bar's one action: the pencil while the file is only read, and
    /// Save once something was actually typed.
    private func applyBarItem() {
        let item = isDirty ? saveItem : editItem
        // Nothing to write before the file is on screen, or while a save runs.
        item.isEnabled = openedText != nil && !isSaving
        // The pencil takes the accent colour once the file is writable, so the
        // bar says which of its two states the sheet is in without a word.
        editItem.tintColor = isWriting ? .systemBlue : .label
        navigationItem.rightBarButtonItem = item
    }

    /// The pencil: the file becomes writable, but keyboard doesn't pop up
    /// automatically. Tapped again before anything is typed, it puts the state
    /// back to reading.
    private func beginEditing() {
        guard openedText != nil, !isSaving else { return }
        guard !isWriting else {
            stopEditing()
            return
        }
        isWriting = true
        textView.isEditable = true
        // No automatic keyboard: user taps where they want to edit
        applyBarItem()
    }

    /// Back to reading: the keyboard away, the file no longer writable, and
    /// the bar showing the pencil again.
    private func stopEditing() {
        isWriting = false
        textView.isEditable = false
        textView.resignFirstResponder()
        applyBarItem()
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
                // Saved: back to reading the file as it is on disk now.
                stopEditing()
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

    /// The caret moved, by a tap or by typing: keep it above the keyboard. The
    /// keyboard is already up in this case, so nothing waits on its animation —
    /// only on the next layout pass, which puts the text where it will stay.
    func textViewDidChangeSelection(_ textView: TextView) {
        guard textView.isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            self?.revealCaret()
        }
    }
}

extension FileEditorController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        performSearch()
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // Every letter searches: a field that only answers the keyboard's
        // Search key looks like a field that does nothing.
        performSearch()
    }

    func searchBarBookmarkButtonClicked(_ searchBar: UISearchBar) {
        isCaseSensitive.toggle()
        let iconName = isCaseSensitive ? "textformat.abc" : "textformat"
        searchBar.setImage(UIImage(systemName: iconName), for: .bookmark, state: .normal)
        if let text = searchBar.text, !text.isEmpty {
            performSearch()
        }
    }

    private func performSearch() {
        guard let searchText = searchBar.text, !searchText.isEmpty else {
            clearSearch()
            return
        }
        let text = textView.text
        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]

        if let range = text.range(of: searchText, options: options) {
            let nsRange = NSRange(range, in: text)
            textView.selectedRange = nsRange
            textView.scrollRangeToVisible(nsRange)
        }
    }

    private func clearSearch() {
        textView.selectedRange = NSRange(location: 0, length: 0)
    }
}
