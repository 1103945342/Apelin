import ApelinCore
import ApelinProtocol
import Combine
import GhosttyTerminal
import SnapKit
import Then
import UIKit

/// The full-screen terminal: one shell on screen, and the bar's list of the
/// others this page has opened — a popover where the width is regular, a sheet
/// otherwise.
///
/// The page is a thin host: the grid, the keyboard, the selection and the
/// pointer belong to `UITerminalView`, which ghostty draws; this controller
/// feeds it the session's events and says plainly what is happening while no
/// shell is on screen. Closing the page detaches the surface and leaves the
/// shell running (`TerminalSession`); opening it again replays.
@MainActor
final class TerminalPageController: UIViewController {
    private(set) var identity: TerminalIdentity

    private let appearance = TerminalAppearance.shared
    private var current: TerminalSession?

    private let terminalHolder = UIView()
    private var terminalView: TerminalView?
    private var terminalState: TerminalViewState?

    private let statusStack = UIStackView()
    private let statusTitle = UILabel()
    private let statusDetail = UILabel()
    private let statusButton = UIButton(type: .system)
    private let banner = UILabel()

    private var sessionsItem: UIBarButtonItem?
    private weak var sessionsList: TerminalSessionsListController?
    private var surfaceCancellables: Set<AnyCancellable> = []
    private var focusRequested = false
    private var isShownOnce = false
    /// The reader deleted the last terminal. Nothing is opened behind their
    /// back: not on a re-entry, not when the app comes back to the front.
    private var isShowingEmptyState = false

    init(identity: TerminalIdentity) {
        self.identity = identity
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Terminal")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Whether this page is still the one on screen; the presenter switches it
    /// rather than presenting a second terminal over it.
    var isShown: Bool {
        viewIfLoaded?.window != nil || presentingViewController != nil
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyBackground()
        if !isShownOnce {
            isShownOnce = true
            attachCurrentIfNeeded()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let closing = isBeingDismissed
            || navigationController?.isBeingDismissed == true
            || isMovingFromParent
        if closing {
            current?.detach()
            teardownSurface()
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            applyBackground()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The page is already open and the caller asked for another folder: the
    /// same folder is a no-op, a different one moves the page there and leaves
    /// the shells it had running.
    func show(identity newIdentity: TerminalIdentity) {
        guard newIdentity != identity else { return }
        current?.detach()
        teardownSurface()
        identity = newIdentity
        current = nil
        isShowingEmptyState = false
        attachCurrentIfNeeded()
    }

    // MARK: - Interface

    private func buildInterface() {
        view.backgroundColor = appearance.background

        terminalHolder.backgroundColor = appearance.background
        terminalHolder.clipsToBounds = true
        view.addSubview(terminalHolder)
        terminalHolder.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            $0.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            $0.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }

        banner.font = .preferredFont(forTextStyle: .footnote)
        banner.textColor = .secondaryLabel
        banner.backgroundColor = .tertiarySystemBackground
        banner.textAlignment = .center
        banner.numberOfLines = 1
        banner.layer.cornerRadius = 8
        banner.layer.cornerCurve = .continuous
        banner.clipsToBounds = true
        banner.isHidden = true
        view.addSubview(banner)
        banner.snp.makeConstraints {
            $0.top.equalTo(terminalHolder.snp.top).offset(8)
            $0.centerX.equalToSuperview()
            $0.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide.snp.leading).offset(16)
            $0.width.lessThanOrEqualTo(360)
            $0.height.equalTo(28)
        }

        statusTitle.font = .preferredFont(forTextStyle: .headline)
        statusTitle.textColor = .label
        statusTitle.textAlignment = .center
        statusTitle.numberOfLines = 0
        statusDetail.font = .preferredFont(forTextStyle: .subheadline)
        statusDetail.textColor = .secondaryLabel
        statusDetail.textAlignment = .center
        statusDetail.numberOfLines = 0
        statusButton.setContentHuggingPriority(.required, for: .vertical)
        statusButton.addAction(UIAction { [weak self] _ in self?.statusButtonTapped() }, for: .touchUpInside)
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 12
        statusStack.addArrangedSubview(statusTitle)
        statusStack.addArrangedSubview(statusDetail)
        statusStack.addArrangedSubview(statusButton)
        statusStack.isHidden = true
        view.addSubview(statusStack)
        statusStack.snp.makeConstraints {
            $0.centerX.equalToSuperview()
            $0.centerY.equalTo(terminalHolder.snp.centerY)
            $0.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide.snp.leading).offset(24)
            $0.width.lessThanOrEqualTo(380)
        }

        let sessions = UIBarButtonItem(
            image: UIImage(systemName: "rectangle.stack"),
            style: .plain,
            target: self,
            action: #selector(showSessionsList)
        )
        sessions.accessibilityLabel = String(localized: "Terminal Sessions")
        sessionsItem = sessions
        navigationItem.rightBarButtonItem = sessions
    }

    private func applyBackground() {
        applyBackground(appearance.background)
    }

    private func applyBackground(_ color: UIColor) {
        view.backgroundColor = color
        terminalHolder.backgroundColor = color
        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = color
        navigation.titleTextAttributes = [.foregroundColor: UIColor.label]
        navigationItem.standardAppearance = navigation
        navigationItem.scrollEdgeAppearance = navigation
        navigationItem.compactAppearance = navigation
    }

    // MARK: - Sessions

    private func attachCurrentIfNeeded() {
        if current == nil {
            // The reader deleted the last terminal: the page says there is
            // none and offers New Terminal, and nothing opens a shell behind
            // their back — not a re-entry, not coming back to the front.
            guard !isShowingEmptyState else {
                updateStatus()
                return
            }
            guard let session = TerminalSessions.session(for: identity) else {
                // Nothing here is ended to make room, and the page says what
                // is actually in the way: the books are full of shells that may
                // still be running, or a records file that could not be read.
                showUnavailableNotice()
                return
            }
            current = session
            bind(session)
        }
        attachCurrent()
    }

    private func showUnavailableNotice() {
        if let problem = TerminalSessions.storageProblem {
            showStatus(
                title: String(localized: "Unable to Start the Terminal"),
                detail: problem,
                action: nil
            )
            banner.isHidden = true
            return
        }
        showStatus(
            title: String(localized: "Too Many Terminals"),
            detail: String(localized: "End a terminal that is still running, then open this one again."),
            action: String(localized: "Try Again")
        )
        banner.isHidden = true
    }

    private func attachCurrent() {
        guard let current else {
            teardownSurface()
            updateStatus()
            refreshSessions()
            return
        }
        if current.isFinished, current.taskID == nil {
            // A terminal that ended before its shell ever existed has nothing
            // to replay. It is shown as it ended; a new shell is only ever
            // opened from New Terminal, by the reader.
            teardownSurface()
            updateStatus()
            refreshSessions()
            return
        }
        makeSurface(for: current)
        updateStatus()
        refreshSessions()
    }

    private func bind(_ session: TerminalSession?) {
        guard let session else { return }
        session.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            if self.current === session {
                self.sessionDidChange()
            } else {
                // A list may be open on a session that is not the one on
                // screen: its row's state is worth redrawing too.
                self.refreshSessions()
            }
        }
        session.onTruncation = { [weak self, weak session] in
            guard let self, let session, self.current === session else { return }
            self.rebuildSurface()
        }
    }

    private func sessionDidChange() {
        guard let session = current else { return }
        updateStatus()
        refreshSessions()
        if session.isLive, !focusRequested {
            focusRequested = true
            terminalState?.requestFocus()
        }
    }

    private func startNewSession() {
        guard let session = TerminalSessions.newSession(for: identity) else {
            // A shell that is live stays on screen: the books being full is a
            // sentence, not a reason to cover the terminal the reader is in.
            presentNotice(
                title: "Too Many Terminals",
                message: "End a terminal that is still running, then try again."
            )
            return
        }
        isShowingEmptyState = false
        switchTo(session)
    }

    private func switchTo(_ session: TerminalSession) {
        guard session.id != current?.id else { return }
        isShowingEmptyState = false
        current?.detach()
        current = session
        bind(session)
        attachCurrent()
    }

    private func endCurrent() {
        guard let current, !current.isFinished else { return }
        current.terminate()
        updateStatus()
        refreshSessions()
    }

    /// Nothing is left to show: the page keeps the place, says it is empty and
    /// offers New Terminal. No shell is created until the reader taps it.
    private func showEmptyState() {
        isShowingEmptyState = true
        current = nil
        teardownSurface()
        updateStatus()
        refreshSessions()
    }

    private func statusButtonTapped() {
        guard let session = current else {
            // The empty state's New Terminal, or a second try at taking a
            // place: both are the reader asking for a shell.
            startNewSession()
            return
        }
        switch session.phase {
        case .ended:
            startNewSession()
        case .failed:
            session.allowRetry()
            makeSurface(for: session)
            updateStatus()
            refreshSessions()
        default:
            break
        }
    }

    // MARK: - The surface

    private func makeSurface(for session: TerminalSession) {
        teardownSurface()
        let emulator = InMemoryTerminalSession(
            write: { [router = session.input] data in
                router.send(data)
            },
            resize: { [relay = session.resize] viewport in
                relay.request(columns: Int(viewport.columns), rows: Int(viewport.rows))
            },
            suppressesPixelOnlyResizes: true
        )
        let options = appearance.surfaceOptions(backend: emulator)
        let state = TerminalViewState(controller: appearance.controller)
        state.configuration = options
        let view = TerminalView(frame: .zero)
        view.delegate = state
        view.controller = appearance.controller
        view.configuration = options
        terminalHolder.addSubview(view)
        view.snp.makeConstraints { $0.edges.equalToSuperview() }
        terminalView = view
        terminalState = state
        focusRequested = false
        // The library resolves the theme's own light and dark colours; the page
        // behind the grid follows the one the surface actually uses, so a
        // scheme change never leaves a white strip around a dark terminal.
        surfaceCancellables.removeAll()
        state.$backgroundColor
            .sink { [weak self] color in
                self?.applyBackground(TerminalAppearance.color(color))
            }
            .store(in: &surfaceCancellables)
        // The host sizes the shell to the grid the library reports; until it
        // does, the shell starts at the protocol's own default.
        session.attach(emulator: emulator, columns: 80, rows: 24)
    }

    private func teardownSurface() {
        surfaceCancellables.removeAll()
        terminalView?.removeFromSuperview()
        terminalView = nil
        terminalState = nil
    }

    /// The host cut this session's history: what is on screen is no longer the
    /// whole of what the log holds, so a fresh surface replays only the tail.
    private func rebuildSurface() {
        guard let current else { return }
        makeSurface(for: current)
        updateStatus()
        refreshSessions()
    }

    // MARK: - Status

    private func updateStatus() {
        guard let session = current else {
            // The empty state: every terminal this page had was deleted, and
            // New Terminal is the way back.
            showStatus(
                title: String(localized: "No Terminal Open"),
                detail: nil,
                action: String(localized: "New Terminal")
            )
            settleBanner()
            return
        }
        switch session.phase {
        case .live:
            statusStack.isHidden = true
            settleBanner()
        case .idle, .opening:
            showStatus(
                title: String(localized: "Starting the Terminal…"),
                detail: nil,
                action: nil
            )
            settleBanner()
        case .reconnecting:
            showStatus(
                title: String(localized: "Reconnecting…"),
                detail: nil,
                action: nil
            )
            settleBanner()
        case let .ended(ending):
            showStatus(
                title: String(localized: "The Terminal Ended"),
                detail: detail(for: ending),
                action: String(localized: "New Terminal")
            )
            settleBanner()
        case let .failed(message):
            showStatus(
                title: String(localized: "Unable to Start the Terminal"),
                detail: message,
                action: String(localized: "Try Again")
            )
            settleBanner()
        }
    }

    private func showStatus(title: String, detail: String?, action: String?) {
        statusStack.isHidden = false
        statusTitle.text = title
        statusDetail.text = detail
        statusDetail.isHidden = detail == nil
        statusButton.isHidden = action == nil
        if let action {
            statusButton.setTitle(action, for: .normal)
        }
    }

    private func detail(for ending: TerminalSession.TerminalEnding) -> String {
        switch ending {
        case let .exited(status, signal):
            // Cast to Int so the catalogue key is the `%lld` form.
            if let status {
                return String(localized: "The shell exited with status \(Int(status)).")
            }
            if let signal {
                return String(localized: "The shell stopped with signal \(Int(signal)).")
            }
            return String(localized: "The shell is no longer running.")
        case .stopped:
            return String(localized: "This terminal was closed.")
        case .noLongerAvailable:
            return String(localized: "The background service no longer has this session.")
        }
    }

    private func settleBanner() {
        // A file the app could not read is never replaced; saying so is more
        // useful than a terminal that silently forgets every session.
        let text = TerminalSessions.storageProblem
            ?? (current?.historyTrimmed == true
                ? String(localized: "Earlier output was trimmed.")
                : nil)
        banner.text = text
        banner.isHidden = text == nil
    }

    // MARK: - The sessions list

    /// The bar button opens a list rather than a menu: rows carry the state of
    /// each terminal, a tap switches, and a terminal that ended can be
    /// forgotten from it — by long press, or by swipe, which VoiceOver lists
    /// among its actions.
    @objc dynamic private func showSessionsList() {
        guard sessionsList == nil else { return }
        let controller = TerminalSessionsListController()
        controller.modelProvider = { [weak self] in
            self?.sessionsListModel()
                ?? TerminalSessionsListController.Model(entries: [], currentID: nil, canEndCurrent: false)
        }
        controller.onSelect = { [weak self] id in
            self?.selectSession(id)
        }
        controller.deleteHandler = { [weak self] id in
            self?.deleteSession(id) ?? .notFound
        }
        controller.onNewTerminal = { [weak self] in
            self?.startNewSession()
        }
        controller.onEndCurrent = { [weak self] in
            self?.endCurrent()
        }
        controller.onPaste = { [weak self] in
            self?.pasteFromPasteboard()
        }
        controller.reloadModel()
        sessionsList = controller

        let navigation = UINavigationController(rootViewController: controller)
        if traitCollection.horizontalSizeClass == .regular {
            // Wide enough for a popover anchored to its bar button; anything
            // narrower gets the sheet, whatever the device calls itself.
            navigation.modalPresentationStyle = .popover
            navigation.preferredContentSize = controller.preferredContentSize
            navigation.popoverPresentationController?.barButtonItem = sessionsItem
            navigation.popoverPresentationController?.permittedArrowDirections = .any
        } else {
            navigation.modalPresentationStyle = .pageSheet
            if let sheet = navigation.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
        }
        present(navigation, animated: true)
    }

    private func sessionsListModel() -> TerminalSessionsListController.Model {
        TerminalSessionsListController.Model(
            entries: listEntries(),
            currentID: current?.id,
            canEndCurrent: current.map { !$0.isFinished } ?? false
        )
    }

    private func listEntries() -> [TerminalSessionListEntry] {
        TerminalSessions.sessions(for: identity).map { session in
            TerminalSessionListEntry(
                id: session.id,
                title: session.title,
                status: session.listStatus
            )
        }
    }

    /// Redraws the list when it is up — a session ending while the sheet is
    /// open changes a row and whether that row may be deleted.
    @objc dynamic private func refreshSessions() {
        sessionsList?.reloadModel()
    }

    private func selectSession(_ id: UUID) {
        guard let session = TerminalSessions.session(id) else {
            refreshSessions()
            return
        }
        switchTo(session)
    }

    /// Deletes one terminal that ended, and only that: its model and its record
    /// go, the folder and the host's task log stay, and no other shell is
    /// touched.
    ///
    /// The session is checked again here, not trusted from the row the reader
    /// tapped: it may have started reconnecting while the sheet was open. When
    /// the record does not write, nothing is forgotten and the error is shown.
    private func deleteSession(_ id: UUID) -> TerminalSessionDeletionOutcome {
        let entries = listEntries()
        let decision = TerminalSessionList.removal(of: id, from: entries, current: current?.id)
        let outcome = TerminalSessions.remove(id)
        guard outcome == .removed else { return outcome }

        // The row's neighbour in the list the page just saw: the decision's
        // when it was one that could go, and recomputed from the same list
        // otherwise, so a deletion never leaves the page on a session that no
        // longer exists.
        var nextCurrent: UUID?
        if case let .remove(next) = decision {
            nextCurrent = next
        } else if let index = entries.firstIndex(where: { $0.id == id }) {
            let remaining = entries.filter { $0.id != id }
            nextCurrent = remaining.indices.contains(index) ? remaining[index].id : remaining.last?.id
        }

        let wasCurrent = current?.id == id
        if wasCurrent {
            // The screen moves to the row that took its place, or to the last
            // one left. `current` is dropped first so the removed session is
            // never attached again.
            current = nil
            teardownSurface()
            if let nextCurrent, let next = TerminalSessions.session(nextCurrent) {
                switchTo(next)
            } else {
                showEmptyState()
            }
        } else if current == nil, let nextCurrent, let next = TerminalSessions.session(nextCurrent) {
            switchTo(next)
        }
        refreshSessions()
        return outcome
    }

    private func pasteFromPasteboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        // The library's text path: a program with bracketed paste receives it
        // framed, so a newline lands in the edit line instead of running it.
        terminalState?.paste(text: text)
    }

    // MARK: - Notifications

    @objc private func appDidEnterBackground() {
        current?.detach()
        teardownSurface()
    }

    @objc private func appWillEnterForeground() {
        guard viewIfLoaded?.window != nil else { return }
        attachCurrentIfNeeded()
    }
}
