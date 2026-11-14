import UIKit

/// The list behind the terminal page's sessions button: every terminal this
/// page has opened for its folder, the three actions that used to be a menu,
/// and the one destructive row action — forgetting a terminal that ended.
///
/// It is a plain table. The page presents it, so the page decides what it looks
/// like where: a popover anchored to the bar button where the width is regular,
/// a sheet otherwise.
///
/// Only a row that ended offers Delete — by long press, and by swipe, which
/// VoiceOver lists among its actions. Running, reconnecting and failed rows
/// offer nothing: the host may still have their shell.
@MainActor
final class TerminalSessionsListController: UITableViewController {
    /// What the list shows, read fresh whenever it is about to draw or to act:
    /// a session can end or reconnect while the list is up.
    struct Model: Equatable {
        var entries: [TerminalSessionListEntry]
        var currentID: UUID?
        var canEndCurrent: Bool
    }

    var modelProvider: (() -> Model)?
    var onSelect: ((UUID) -> Void)?
    /// Performs the deletion and answers what became of it. The page owns the
    /// session bookkeeping; this controller only reports what it says.
    var deleteHandler: ((UUID) -> TerminalSessionDeletionOutcome)?
    var onNewTerminal: (() -> Void)?
    var onEndCurrent: (() -> Void)?
    var onPaste: (() -> Void)?

    private enum Section: Int {
        case sessions
        case actions
    }

    private enum Action: Int {
        case newTerminal
        case endCurrent
        case paste
    }

    private var model = Model(entries: [], currentID: nil, canEndCurrent: false)

    init() {
        super.init(style: .insetGrouped)
        title = String(localized: "Terminal Sessions")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Done"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 48
        tableView.accessibilityIdentifier = "TerminalSessions"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadModel()
    }

    /// Reads the page's model again and redraws only when something about it
    /// changed: output arrives on every batch, and a redraw per line would
    /// interrupt a long press or a scroll for nothing.
    @objc dynamic func reloadModel() {
        let fresh = modelProvider?() ?? Model(entries: [], currentID: nil, canEndCurrent: false)
        let changed = fresh != model
        model = fresh
        updatePreferredSize()
        if changed, isViewLoaded {
            tableView.reloadData()
        }
    }

    // MARK: - Rows

    private var actionRows: [Action] {
        model.canEndCurrent ? [.newTerminal, .endCurrent, .paste] : [.newTerminal, .paste]
    }

    @objc dynamic private var rowCount: Int {
        model.entries.count + actionRows.count
    }

    override func numberOfSections(in _: UITableView) -> Int {
        2
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .sessions?:
            return model.entries.count
        case .actions?:
            return actionRows.count
        case nil:
            return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .sessions?:
            return sessionCell(in: tableView, at: indexPath.row)
        case .actions?:
            return actionCell(in: tableView, at: indexPath.row)
        case nil:
            return UITableViewCell()
        }
    }

    @objc dynamic private func sessionCell(in tableView: UITableView, at index: Int) -> UITableViewCell {
        let entry = model.entries[index]
        let cell = tableView.dequeueReusableCell(withIdentifier: "session")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "session")
        var content = UIListContentConfiguration.subtitleCell()
        content.text = entry.title
        content.secondaryText = statusText(for: entry.status)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = entry.id == model.currentID ? .checkmark : .none
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = entry.title
        cell.accessibilityValue = statusText(for: entry.status)
        var traits: UIAccessibilityTraits = [.button]
        if entry.id == model.currentID {
            // The checkmark is drawn, not spoken, so the state is carried here.
            traits.insert(.selected)
        }
        cell.accessibilityTraits = traits
        // Deleting an ended row is offered by the swipe action alone, which
        // VoiceOver already lists in its actions: a second custom action of
        // the same name would be the rotor saying it twice.
        cell.accessibilityCustomActions = nil
        return cell
    }

    @objc dynamic private func actionCell(in tableView: UITableView, at index: Int) -> UITableViewCell {
        let action = actionRows[index]
        let cell = tableView.dequeueReusableCell(withIdentifier: "action")
            ?? UITableViewCell(style: .default, reuseIdentifier: "action")
        var content = UIListContentConfiguration.cell()
        switch action {
        case .newTerminal:
            content.text = String(localized: "New Terminal")
            content.image = UIImage(systemName: "plus")
        case .endCurrent:
            content.text = String(localized: "End This Terminal")
            content.image = UIImage(systemName: "xmark.circle")
        case .paste:
            content.text = String(localized: "Paste")
            content.image = UIImage(systemName: "doc.on.clipboard")
        }
        cell.contentConfiguration = content
        cell.accessoryType = .none
        cell.accessibilityCustomActions = nil
        return cell
    }

    private func statusText(for status: TerminalSessionListEntry.Status) -> String {
        switch status {
        case .running:
            return String(localized: "Running")
        case .connecting:
            return String(localized: "Connecting…")
        case .ended:
            return String(localized: "Ended")
        case .unavailable:
            return String(localized: "Unavailable")
        }
    }

    // MARK: - Selecting

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .sessions?:
            guard indexPath.row < model.entries.count else { return }
            let id = model.entries[indexPath.row].id
            let handler = onSelect
            dismiss(animated: true) {
                handler?(id)
            }
        case .actions?:
            guard indexPath.row < actionRows.count else { return }
            let action = actionRows[indexPath.row]
            let newTerminal = onNewTerminal
            let endCurrent = onEndCurrent
            let paste = onPaste
            dismiss(animated: true) {
                switch action {
                case .newTerminal:
                    newTerminal?()
                case .endCurrent:
                    endCurrent?()
                case .paste:
                    paste?()
                }
            }
        case nil:
            break
        }
    }

    // MARK: - Deleting

    /// Deletes one row that ended, re-reading the list first and asking the
    /// page to act — the page checks the session again. Answers whether the
    /// row went, so a swipe only reports itself done when something happened.
    @discardableResult
    private func requestDelete(_ id: UUID) -> Bool {
        reloadModel()
        switch TerminalSessionList.removal(of: id, from: model.entries, current: model.currentID) {
        case .refusedUnknown:
            // Already gone: the reload above shows the list as it is.
            return false
        case .refusedStillRunning:
            presentFailure(String(localized: "This terminal is still running."))
            return false
        case .remove:
            guard let deleteHandler else { return false }
            switch deleteHandler(id) {
            case .removed:
                reloadModel()
                if model.entries.isEmpty {
                    // Nothing left to list: the page's empty state, with New
                    // Terminal, is what the reader should see.
                    dismiss(animated: true)
                }
                return true
            case .stillRunning:
                reloadModel()
                presentFailure(String(localized: "This terminal is still running."))
                return false
            case .notFound:
                reloadModel()
                return false
            case let .failed(message):
                reloadModel()
                presentFailure(message)
                return false
            }
        }
    }

    @objc dynamic private func presentFailure(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "Unable to Delete"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .default))
        present(alert, animated: true)
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .sessions,
              indexPath.row < model.entries.count
        else { return nil }
        let entry = model.entries[indexPath.row]
        guard entry.canDelete else { return nil }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete")
        ) { [weak self] _, _, completion in
            completion(self?.requestDelete(entry.id) ?? false)
        }
        delete.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [delete])
        // A full swipe would delete without the reader seeing what they hit;
        // the swipe shows Delete first, as the long press does.
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard Section(rawValue: indexPath.section) == .sessions,
              indexPath.row < model.entries.count
        else { return nil }
        let entry = model.entries[indexPath.row]
        guard entry.canDelete else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let delete = UIAction(
                title: String(localized: "Delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                self?.requestDelete(entry.id)
            }
            return UIMenu(children: [delete])
        }
    }

    // MARK: - Size and dismissal

    /// A popover gets the height its rows need, up to a bound, so a page with
    /// one terminal is not a tall empty sheet.
    @objc dynamic private func updatePreferredSize() {
        let height = min(560, 64 + CGFloat(rowCount) * 48)
        preferredContentSize = CGSize(width: 340, height: height)
        navigationController?.preferredContentSize = preferredContentSize
    }

    @objc dynamic private func doneTapped() {
        dismiss(animated: true)
    }
}
