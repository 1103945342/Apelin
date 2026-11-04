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
    /// The word a content search found the file by: marked everywhere it
    /// appears, with the hit's own line in view.
    private let highlight: String?

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

    /// The text and its highlighted state, read before the sheet is on screen:
    /// a sheet that arrives empty and fills in a moment later reads as a
    /// flash, and at night that flash is a white page.
    private var preloaded: (text: String, state: TextViewState)?

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

    /// Every place the search found, and which of them is on screen. The
    /// reader steps through them rather than being shown only the first.
    private var matches: [NSRange] = []
    private var matchIndex = 0
    /// Past this many matches the rest are left out: a page of highlights is
    /// as much as anyone steps through, and the count stops growing.
    private static let matchLimit = 2000

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

    /// "3 / 12": how far through the matches the reader is.
    private lazy var matchCountLabel = UILabel().then {
        $0.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.isAccessibilityElement = true
    }

    private lazy var previousMatchItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.up"),
        style: .plain,
        target: self,
        action: #selector(goToPreviousMatch),
    ).then {
        $0.accessibilityLabel = String(localized: "Previous Match")
        $0.isEnabled = false
    }

    private lazy var nextMatchItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.down"),
        style: .plain,
        target: self,
        action: #selector(goToNextMatch),
    ).then {
        $0.accessibilityLabel = String(localized: "Next Match")
        $0.isEnabled = false
    }

    /// The keyboard's own bar over the text: one way out of it.
    private lazy var textToolbar: UIToolbar = {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem.flexibleSpace(),
            UIBarButtonItem(
                title: String(localized: "Done"),
                style: .done,
                target: self,
                action: #selector(dismissKeyboard),
            ),
        ]
        return toolbar
    }()

    /// The bar over the search field: step through the matches, see how many
    /// there are, and leave.
    private lazy var searchToolbar: UIToolbar = {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            previousMatchItem,
            nextMatchItem,
            UIBarButtonItem.flexibleSpace(),
            UIBarButtonItem(customView: matchCountLabel),
            UIBarButtonItem.flexibleSpace(),
            UIBarButtonItem(
                title: String(localized: "Done"),
                style: .done,
                target: self,
                action: #selector(dismissKeyboard),
            ),
        ]
        return toolbar
    }()

    init(url: URL, relativePath: String, line: Int? = nil, highlight: String? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.line = line
        self.highlight = highlight
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reads the file and builds its highlighted state before there is a sheet
    /// to put them in. The page then has its text on the first frame it draws,
    /// instead of a blank one that fills in a moment later.
    static func prepare(
        url: URL,
        relativePath: String,
        line: Int?,
        highlight: String? = nil,
    ) async -> FileEditorController? {
        // A trailing closure inside a `guard` condition does not parse under
        // Swift 6.4: the task is made first, and its value asked for after.
        let reading = Task.detached(priority: .userInitiated) {
            try ProjectFileContent.read(at: url)
        }
        guard let text = try? await reading.value else { return nil }
        let theme = ApelinEditorTheme()
        let state = await Task.detached(priority: .userInitiated) {
            highlightedState(for: text, theme: theme, fileName: relativePath)
        }.value
        let controller = FileEditorController(
            url: url,
            relativePath: relativePath,
            line: line,
            highlight: highlight,
        )
        controller.preloaded = (text, state)
        return controller
    }

    /// The text drawn in its language's colours: built off the main thread,
    /// because a large file parsed for the first time would otherwise hold the
    /// page blank while it did.
    nonisolated private static func highlightedState(
        for text: String,
        theme: ApelinEditorTheme,
        fileName: String,
    ) -> TextViewState {
        if let language = RunestoneLanguage(fileName: fileName) {
            return TextViewState(text: text, theme: theme, language: language.treeSitterLanguage)
        }
        return TextViewState(text: text, theme: theme)
    }

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

        textView.inputAccessoryView = textToolbar
        searchBar.delegate = self
        searchBar.searchTextField.inputAccessoryView = searchToolbar
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

        // The keyboard takes the bottom of the page with it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil,
        )

        // A white text view under a dark page is the flash the sheet opens
        // with: it takes the theme's ground before anything is drawn on it.
        textView.backgroundColor = theme.backgroundColor

        if let preloaded {
            show(preloaded.text, state: preloaded.state)
        } else {
            spinner.startAnimating()
            load()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func dismissKeyboard() {
        if textView.isFirstResponder { textView.resignFirstResponder() }
        if searchBar.searchTextField.isFirstResponder { searchBar.resignFirstResponder() }
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // Only the text view moves: the search bar sits at the top and keeps
        // its place while the reader steps through matches.
        guard textView.isFirstResponder else { return }
        keyboardHeight = frame.height
        updateTextViewInsets()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard keyboardHeight != 0 else { return }
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

    /// Brings a range into view, as little scrolling as gets it there.
    private func scrollToVisible(_ range: NSRange) {
        textView.scrollRangeToVisible(range)
    }

    /// Brings the insertion point into the part of the page the keyboard leaves
    /// visible: tapping a line near the foot of a file would otherwise put the
    /// caret behind the keyboard, where nothing typed there can be read.
    private func revealCaret() {
        guard textView.isFirstResponder else { return }
        scrollToVisible(textView.selectedRange)
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
    /// for the first time would otherwise hold the page blank while it did.
    private func show(_ text: String) {
        let theme = theme
        let fileName = relativePath
        Task { [weak self] in
            let state = await Task.detached(priority: .userInitiated) {
                Self.highlightedState(for: text, theme: theme, fileName: fileName)
            }.value
            self?.show(text, state: state)
        }
    }

    /// The file, ready to draw. A sheet `prepare` made arrives here on its
    /// first frame; one that started empty arrives once its state is built.
    private func show(_ text: String, state: TextViewState) {
        openedText = text
        spinner.stopAnimating()
        textView.backgroundColor = theme.backgroundColor
        textView.setState(state)
        textView.editorDelegate = self
        // shown to be read: the keyboard is the pencil's, not the file's
        textView.isEditable = isWriting
        applyBarItem()
        if let highlight, !highlight.isEmpty {
            // Opened from a content search: the word is marked everywhere it
            // appears, and the hit's own line is the one on screen.
            mark(needle: highlight, caseSensitive: false, focusAt: line)
        } else if let line {
            reveal(line: line)
        }
    }

    /// Puts the caret on a line and brings it into view: what a content search
    /// opens a file for.
    private func reveal(line: Int) {
        guard let location = Self.location(ofLine: line, in: textView.text) else { return }
        let range = NSRange(location: location, length: 0)
        textView.selectedRange = range
        scrollToVisible(range)
    }

    /// Where a 1-based line starts, or nil past the end of the text.
    private static func location(ofLine line: Int, in text: String) -> Int? {
        guard line > 1 else { return 0 }
        var number = 1
        var index = text.startIndex
        while number < line, index < text.endIndex {
            guard let newline = text[index...].firstIndex(of: "\n") else { return nil }
            index = text.index(after: newline)
            number += 1
        }
        return number == line ? text.distance(from: text.startIndex, to: index) : nil
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

    // MARK: - Search

    /// Finds every place `needle` appears, marks them all, and puts the one
    /// asked for on screen.
    @discardableResult
    private func mark(needle: String, caseSensitive: Bool, focusAt line: Int?) -> Int {
        let text = textView.text
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var found: [NSRange] = []
        var cursor = text.startIndex
        while found.count < Self.matchLimit,
              let range = text.range(of: needle, options: options, range: cursor ..< text.endIndex)
        {
            found.append(NSRange(range, in: text))
            cursor = range.upperBound
            if cursor >= text.endIndex { break }
        }
        matches = found
        if let line, let start = Self.location(ofLine: line, in: text) {
            // The hit the file was opened for, not merely the first one.
            matchIndex = found.firstIndex { $0.location >= start } ?? 0
        } else {
            matchIndex = 0
        }
        paintMatches()
        focusCurrentMatch()
        updateMatchCount()
        return found.count
    }

    /// Every match in yellow, the one on screen in a deeper shade: the reader
    /// sees both where they are and what else there is.
    private func paintMatches() {
        guard !matches.isEmpty else {
            textView.highlightedRanges = []
            return
        }
        textView.highlightedRanges = matches.enumerated().map { index, range in
            HighlightedRange(
                id: "match-\(index)",
                range: range,
                color: index == matchIndex
                    ? UIColor.systemYellow.withAlphaComponent(0.55)
                    : UIColor.systemYellow.withAlphaComponent(0.22),
                cornerRadius: 2,
            )
        }
    }

    private func focusCurrentMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        let range = matches[matchIndex]
        textView.selectedRange = range
        scrollToVisible(range)
    }

    private func updateMatchCount() {
        let hasMatches = !matches.isEmpty
        previousMatchItem.isEnabled = hasMatches
        nextMatchItem.isEnabled = hasMatches
        if hasMatches {
            let text = "\(matchIndex + 1) / \(matches.count)"
            matchCountLabel.text = text
            matchCountLabel.accessibilityLabel = String(localized: "Match") + " " + text
        } else {
            matchCountLabel.text = searchBar.text?.isEmpty == false ? String(localized: "None") : nil
            matchCountLabel.accessibilityLabel = matchCountLabel.text
        }
    }

    @objc private func goToNextMatch() {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + 1) % matches.count
        paintMatches()
        focusCurrentMatch()
        updateMatchCount()
    }

    @objc private func goToPreviousMatch() {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + matches.count - 1) % matches.count
        paintMatches()
        focusCurrentMatch()
        updateMatchCount()
    }

    /// What the search field holds now: every match marked, the first on
    /// screen. Empty clears what the last search left.
    private func performSearch() {
        let needle = searchBar.text ?? ""
        guard !needle.isEmpty else {
            matches = []
            matchIndex = 0
            textView.highlightedRanges = []
            updateMatchCount()
            return
        }
        mark(needle: needle, caseSensitive: isCaseSensitive, focusAt: nil)
    }
}

extension FileEditorController: TextViewDelegate {
    func textViewDidChange(_ textView: TextView) {
        guard let openedText else { return }
        isDirty = textView.text != openedText
        // The text moved under the search: what was marked is no longer where
        // it was marked. Ask again, but only when there is a search to keep.
        if searchBar.text?.isEmpty == false {
            performSearch()
        }
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
        performSearch()
    }
}
