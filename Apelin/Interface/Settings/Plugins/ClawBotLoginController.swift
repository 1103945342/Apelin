import ApelinProtocol
import UIKit

/// Settings ▸ Plugins ▸ WeChat ClawBot ▸ Sign In: the code a phone scans with
/// WeChat, and the number WeChat asks for on it afterwards.
///
/// The sign-in is the channel's own task on the host; this page only starts
/// the channel and folds that task's events (`ClawBotLoginProgress`). The
/// number is typed here and sent with `channelLoginCode`; a wrong one comes
/// back as the platform asking again, which the page says in place rather
/// than in a system alert.
///
/// The code carries the sign-in, so it is drawn and nothing else — never a
/// label, an alert, the pasteboard or a log. The number is the reader's, and
/// is only sent.
final class ClawBotLoginController: TableController {
    /// Told once, as the page goes, with whether the channel came up signed in.
    @objc dynamic var onFinish: ((Bool) -> Void)?

    private enum Section: Hashable {
        case code
        case entry
        case failure
        case actions
    }

    /// The one button under the code.
    private enum Button: Hashable {
        case tryAgain
        case newCode
        case submitCode

        var title: String {
            switch self {
            case .tryAgain:
                return String(localized: "Try Again")
            case .newCode:
                return String(localized: "Show a New Code")
            case .submitCode:
                return String(localized: "Confirm")
            }
        }
    }

    private enum Row: Hashable {
        /// The prompt as it arrived, which is also what tells one from the next.
        case picture(ClawBotLoginProgress.Prompt)
        /// A platform that asks in words rather than in a code.
        case words(String)
        case status(String)
        case failure(String)
        case action(Button)
        /// The number WeChat wants, typed here.
        case codeField
        /// Why the last number was not taken, or that it was not.
        case hint(String)
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private let channelID: String
    private var progress = ClawBotLoginProgress()
    /// Counts the attempts: an event or an answer of an older one writes nothing.
    @objc private dynamic var attempt = 0
    private var follower: Task<Void, Never>?
    private var submitter: Task<Void, Never>?

    @objc private dynamic var codeField = UITextField()
    private lazy var codeCell = fieldCell(codeField)
    /// The code request this page already answered. A newer one asks again.
    private var answeredRequest: Int?
    /// Why the last number could not be sent at all.
    @objc private dynamic var codeError: String?

    init(channelID: String) {
        self.channelID = channelID
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(channelID:)")
    }

    deinit {
        follower?.cancel()
        submitter?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "WeChat ClawBot")
        navigationItem.backButtonDisplayMode = .minimal
        // A number WeChat puts on the phone: digits only, and iOS offers the
        // one it just read from a message.
        codeField.keyboardType = .numberPad
        codeField.textContentType = .oneTimeCode
        codeField.returnKeyType = .done
        codeField.accessibilityLabel = String(localized: "Enter the Code")
        codeField.font = .preferredFont(forTextStyle: .body)
        codeField.adjustsFontForContentSizeCategory = true
        codeField.borderStyle = .none
        codeField.addAction(
            UIAction { [weak self] _ in self?.submitCode() },
            for: .editingDidEndOnExit,
        )
        dataSource.headerTitle = { [weak self] in self?.header(for: $0) }
        dataSource.footerTitle = { [weak self] in self?.footer(for: $0) }
        render()
        follow(restarting: false)
    }

    /// Leaving the page stops watching; the channel itself keeps waiting for
    /// the phone, and the page it came from shows that.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent || navigationController?.isBeingDismissed == true else { return }
        guard let coordinator = transitionCoordinator else {
            stopWatching()
            return
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard !context.isCancelled else { return }
            self?.stopWatching()
        }
    }

    @objc private dynamic func stopWatching() {
        follower?.cancel()
        follower = nil
        submitter?.cancel()
        submitter = nil
        attempt &+= 1
    }

    // MARK: - The flow

    @objc private dynamic func tryAgain() {
        follow(restarting: false)
    }

    @objc private dynamic func newCode() {
        follow(restarting: true)
    }

    /// Starts the channel and reads its task from the first event. A new code
    /// is a stop and a start: a start on a channel that is already running
    /// answers the worker it has, code and all.
    @objc private dynamic func follow(restarting: Bool) {
        follower?.cancel()
        attempt &+= 1
        let attempt = attempt
        progress = ClawBotLoginProgress()
        answeredRequest = nil
        codeError = nil
        codeField.text = nil
        render()
        follower = Task { [weak self] in
            guard let self else { return }
            do {
                if restarting {
                    _ = try await ApelinService.app.channelStop(channelID: self.channelID)
                    guard !Task.isCancelled, attempt == self.attempt else { return }
                }
                let summary = try await ApelinService.app.channelStart(channelID: self.channelID)
                guard !Task.isCancelled, attempt == self.attempt else { return }
                guard let taskID = summary.taskID else {
                    self.progress.lost(String(localized: "The channel is not running."))
                    self.render()
                    return
                }
                let handle = TaskHandle(taskID: taskID, kind: .channel)
                for try await event in ApelinService.app.events(of: handle, afterSeq: .start) {
                    guard !Task.isCancelled, attempt == self.attempt else { return }
                    self.receive(event)
                    if self.progress.isFinished { return }
                }
                guard !Task.isCancelled, attempt == self.attempt else { return }
                self.loseWithoutAnswer()
            } catch {
                guard !Task.isCancelled, attempt == self.attempt else { return }
                self.progress.lost(error.readableMessage)
                self.render()
                UIAccessibility.post(notification: .announcement, argument: String(localized: "Sign-In Failed"))
            }
        }
    }

    /// Not `@objc`: one event is a struct Objective-C cannot carry.
    private func receive(_ event: TaskEvent) {
        let wasFinished = progress.isFinished
        let askedBefore = progress.codeRequests
        progress.apply(event)
        if progress.codeRequests > askedBefore {
            // A new number is wanted: what was typed before is spent.
            codeError = nil
            codeField.text = nil
        }
        render()
        guard progress.isFinished, !wasFinished else { return }
        finished()
    }

    @objc private dynamic func finished() {
        switch progress.step {
        case .online:
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Signed In"))
            onFinish?(true)
            onFinish = nil
            navigationController?.popViewController(animated: true)
        case let .ended(state, message):
            UIAccessibility.post(notification: .announcement, argument: message ?? Self.text(for: state))
        case .starting, .prompt, .awaitingLogin, .code:
            break
        }
    }

    /// The task ended without a word about why: nothing is left to wait on.
    @objc private dynamic func loseWithoutAnswer() {
        guard !progress.isFinished else { return }
        progress.lost(String(localized: "The sign-in ended before it finished."))
        render()
    }

    // MARK: - The number

    @objc private dynamic func submitCode() {
        let text = codeField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, case .code = progress.step else { return }
        let attempt = self.attempt
        let channelID = self.channelID
        codeError = nil
        answeredRequest = progress.codeRequests
        codeField.text = nil
        codeField.resignFirstResponder()
        render()
        submitter?.cancel()
        submitter = Task { [weak self] in
            do {
                _ = try await ApelinService.app.channelLoginCode(channelID: channelID, code: text)
            } catch {
                guard !Task.isCancelled, let self, attempt == self.attempt else { return }
                // In place, never a system alert: the field is right here.
                self.codeError = error.readableMessage
                self.answeredRequest = nil
                self.render()
            }
        }
    }

    // MARK: - Drawing

    @objc private dynamic func render() {
        dataSource.update(buildSections(), reconfigure: true)
        focusCodeField()
    }

    private func buildSections() -> [(Section, [Row])] {
        var result: [(Section, [Row])] = []
        var codeRows: [Row] = []
        // The code stays on screen the whole time: signing in is scanning it,
        // and a number WeChat asks for appears in its own section underneath.
        switch progress.prompt {
        case let .image(data):
            codeRows.append(.picture(.image(data)))
        case let .link(link):
            codeRows.append(.picture(.link(link)))
        case let .text(text):
            codeRows.append(.words(text))
        case nil:
            break
        }
        if let text = statusText {
            codeRows.append(.status(text))
        }
        if !codeRows.isEmpty {
            result.append((.code, codeRows))
        }
        if showsCodeEntry {
            var entryRows: [Row] = [.codeField]
            if let hint = codeHint {
                entryRows.append(.hint(hint))
            }
            entryRows.append(.action(.submitCode))
            result.append((.entry, entryRows))
        }
        if let message = failureText {
            result.append((.failure, [.failure(message)]))
        }
        if let button = actionButton {
            result.append((.actions, [.action(button)]))
        }
        return result
    }

    /// The number is asked for once per request: a submitted one hides the
    /// field until the platform answers, taken or refused.
    private var showsCodeEntry: Bool {
        guard case .code = progress.step else { return false }
        return progress.codeRequests > (answeredRequest ?? 0)
    }

    private var codeHint: String? {
        if let codeError { return codeError }
        guard case let .code(retry, _) = progress.step, retry else { return nil }
        return String(localized: "That number was not right. Try again.")
    }

    @objc private dynamic var statusText: String? {
        switch progress.step {
        case .starting:
            return String(localized: "Waiting for WeChat…")
        case .prompt:
            return String(localized: "Scan this code with WeChat to sign the bot in.")
        case .awaitingLogin:
            return String(localized: "Waiting for the phone to finish signing in.")
        case .code:
            // The row that asks for the number says what it wants; a line
            // above it about the phone would only contradict it. Once the
            // number is sent, the page is waiting again.
            return showsCodeEntry ? nil : String(localized: "Waiting for WeChat…")
        case .online:
            return String(localized: "Signed In")
        case .ended:
            return nil
        }
    }

    @objc private dynamic var failureText: String? {
        guard case let .ended(state, message) = progress.step else { return nil }
        if let message, !message.isEmpty { return message }
        return Self.text(for: state)
    }

    /// The one row under the code: a fresh code while one is still being
    /// scanned, and another try once the sign-in is over.
    private var actionButton: Button? {
        switch progress.step {
        case .ended:
            return .tryAgain
        case .starting, .prompt, .awaitingLogin, .code:
            return .newCode
        case .online:
            return nil
        }
    }

    /// Not `@objc`: a section is this page's own enum.
    private func header(for section: Section) -> String? {
        section == .entry ? String(localized: "Enter the Code") : nil
    }

    /// Not `@objc`: a section is this page's own enum.
    private func footer(for section: Section) -> String? {
        switch section {
        case .entry:
            return String(localized: "WeChat shows a number on the phone that signed in. Type it here.")
        case .code:
            return String(localized: "The code is shown by WeChat on this device only; it is never sent anywhere else.")
        case .failure, .actions:
            return nil
        }
    }

    /// Not `@objc`: a task's state is an enum of the protocol's.
    static func text(for state: TaskState) -> String {
        switch state {
        case .cancelled:
            return String(localized: "The sign-in was cancelled.")
        case .interrupted:
            return String(localized: "The sign-in was interrupted. Try again.")
        default:
            return String(localized: "Sign-In Failed")
        }
    }

    // MARK: - Cells

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        switch row {
        case let .picture(prompt):
            let cell = tableView.dequeueReusableCell(withIdentifier: "clawbot-qr") as? ClawBotQRCodeCell
                ?? ClawBotQRCodeCell()
            switch prompt {
            case let .image(data):
                cell.show(UIImage(data: data))
            case let .link(link):
                cell.show(ClawBotQRCode.image(for: link))
            case .text:
                cell.show(nil)
            }
            return cell
        case let .words(text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "clawbot-words")
                ?? UITableViewCell(style: .default, reuseIdentifier: "clawbot-words")
            var content = UIListContentConfiguration.explanatoryCell()
            content.text = text
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        case let .status(text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "clawbot-status")
                ?? UITableViewCell(style: .default, reuseIdentifier: "clawbot-status")
            var content = UIListContentConfiguration.explanatoryCell()
            content.text = text
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        case let .failure(text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "clawbot-failure")
                ?? UITableViewCell(style: .default, reuseIdentifier: "clawbot-failure")
            var content = UIListContentConfiguration.explanatoryCell()
            content.text = text
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        case let .hint(text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "clawbot-hint")
                ?? UITableViewCell(style: .default, reuseIdentifier: "clawbot-hint")
            var content = UIListContentConfiguration.explanatoryCell()
            content.text = text
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell
        case .codeField:
            return codeCell
        case let .action(button):
            let cell = tableView.dequeueReusableCell(withIdentifier: "clawbot-action")
                ?? UITableViewCell(style: .default, reuseIdentifier: "clawbot-action")
            var content = UIListContentConfiguration.valueCell()
            content.text = button.title
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .default
            return cell
        }
    }

    /// A field on a row of its own; the cell is kept, so the keyboard and the
    /// text stay where they were across a redraw.
    private func fieldCell(_ field: UIView) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            field.topAnchor.constraint(equalTo: margins.topAnchor),
            field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return cell
    }

    /// The field is the point of the step: it comes up with the keyboard as
    /// soon as the platform asks, and goes away with the row.
    @objc private dynamic func focusCodeField() {
        guard showsCodeEntry, view.window != nil else {
            if codeField.isFirstResponder {
                codeField.resignFirstResponder()
            }
            return
        }
        guard !codeField.isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.showsCodeEntry, self.view.window != nil else { return }
            self.codeField.becomeFirstResponder()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .action(button)? = dataSource.value(at: indexPath) else { return }
        switch button {
        case .tryAgain:
            tryAgain()
        case .newCode:
            newCode()
        case .submitCode:
            submitCode()
        }
    }
}

/// The code on its own white square, which a dark page must keep: a scanner
/// needs dark modules on light, whatever the device's appearance.
private final class ClawBotQRCodeCell: UITableViewCell {
    private let codeView = UIImageView()

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        isAccessibilityElement = false
        codeView.contentMode = .scaleAspectFit
        codeView.backgroundColor = .white
        // Whole modules: a smoothed edge is a code the camera cannot place.
        codeView.layer.magnificationFilter = .nearest
        codeView.layer.minificationFilter = .nearest
        codeView.isAccessibilityElement = true
        codeView.accessibilityLabel = String(localized: "Sign-in QR code")
        codeView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(codeView)
        let margins = contentView.layoutMarginsGuide
        let side = codeView.widthAnchor.constraint(equalToConstant: 240)
        side.priority = .defaultHigh
        NSLayoutConstraint.activate([
            side,
            codeView.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            codeView.widthAnchor.constraint(lessThanOrEqualTo: margins.widthAnchor),
            codeView.heightAnchor.constraint(equalTo: codeView.widthAnchor),
            codeView.centerXAnchor.constraint(equalTo: margins.centerXAnchor),
            codeView.topAnchor.constraint(equalTo: margins.topAnchor, constant: 24),
            codeView.bottomAnchor.constraint(equalTo: margins.bottomAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    @objc dynamic func show(_ image: UIImage?) {
        codeView.image = image
        codeView.isHidden = image == nil
    }
}
