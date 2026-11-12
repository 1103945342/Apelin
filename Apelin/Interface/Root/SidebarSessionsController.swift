import SnapKit
import Then
import UIKit

/// The middle page of the sidebar: the open workspace's conversations,
/// pinned first and then by the day they were last used, under a search
/// field that stays where it is, as aimini's session tab has it.
///
/// It reads the runtime the sidebar hands it and nothing else, so switching
/// workspace only replaces what it lists.
final class SidebarSessionsController: UIViewController {
    /// Pinned, then Today, Yesterday, the weekday within the week, then the date.
    private enum Section: Hashable {
        case pinned
        case day(Date)
    }

    /// The conversation the reader picked, or one picked for them; `picked`
    /// says which, so the root can put a drawer away.
    var onSelect: ((ChatSummary?, _ picked: Bool) -> Void)?
    /// A message to send in the conversation just picked, as if typed.
    var onSendPrompt: ((String) -> Void)?

    var runtime: ChatRuntime! {
        didSet { if isViewLoaded { reload() } }
    }

    /// The conversations listed: the open workspace's, or General Chat's
    /// when it is nil.
    private var projectName: String?
    private var chats: [ChatSummary] = []
    private var query = ""
    private var selectedID: UUID?
    private var tree = SidebarTree([])
    private var rows: [SidebarTree.Item: SidebarTree.Row] = [:]
    /// IDs are globally unique; switching projects keeps each one's choices.
    private var expanded = Set(UserDefaults.standard.stringArray(forKey: "sidebar.expandedConversations.v1") ?? [])
    private let pacing = ListPacing()

    /// "Today" and "Yesterday" in the reader's language, capitalised as a
    /// heading starts: French, Italian and Spanish write them in lower case
    /// mid-sentence.
    private static let relativeDayFormatter = DateFormatter().then {
        $0.dateStyle = .medium
        $0.timeStyle = .none
        $0.doesRelativeDateFormatting = true
        $0.formattingContext = .beginningOfSentence
    }

    /// The other days' headings, capitalised the same way ("Lundi").
    private static let dayHeading = Date.FormatStyle(capitalizationContext: .beginningOfSentence)

    var summaries: [ChatSummary] { chats }

    private lazy var searchField = SidebarSearchField(placeholder: "Search chats").then {
        $0.onChange = { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed != query else { return }
            query = trimmed
            pacing.begin()
            applySnapshot()
        }
    }

    private lazy var newChatButton = UIButton(type: .system).then {
        $0.setImage(UIImage(systemName: "square.and.pencil"), for: .normal)
        $0.accessibilityLabel = String(localized: "New Chat")
        $0.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                // The sidebar makes the conversation, so it is the one that
                // knows which empty one stands in its place.
                controllingSidebar?.startNewChat()
            },
            for: .touchUpInside,
        )
    }

    /// The sidebar this page belongs to, for the one thing a page cannot do
    /// itself: making a conversation.
    private var controllingSidebar: SidebarController? {
        parent as? SidebarController ?? (parent?.parent as? SidebarController)
    }

    private let tableView = FirstFillTableView(frame: .zero, style: .insetGrouped).then {
        $0.backgroundColor = .clear
        $0.register(SidebarTreeCell.self, forCellReuseIdentifier: "chat")
        // The first conversation is picked at launch, and after that a tap
        // picks: in a primary column the selection would otherwise follow
        // a keyboard's focus.
        $0.selectionFollowsFocus = false
        // the symbol alone; the words are for VoiceOver
        $0.backgroundView = EmptyStateView(
            symbolName: "bubble.left.and.bubble.right.fill",
            text: String(localized: "No chats yet. Tap “New Chat” to start one."),
            showsText: false,
        )
    }

    /// A picked row's ground, lighter than the system's: black at 0.1 in
    /// the light, white at 0.1 in the dark (owner, 2026-10-21).
    private static let selectionColor = UIColor(
        light: UIColor.black.withAlphaComponent(0.1),
        dark: UIColor.white.withAlphaComponent(0.1),
    )

    /// Conversations and their nonempty relationship categories have separate IDs.
    private lazy var dataSource = SwipeableTableDataSource<Section, SidebarTree.Item>(
        tableView: tableView,
    ) { [unowned self] tableView, indexPath, item in
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "chat", for: indexPath) as? SidebarTreeCell,
              let row = rows[item] else { return nil }
        let summary = item.chatID.flatMap(chat)
        let title: String
        switch item {
        case .chat: title = summary?.displayTitle ?? ""
        case .group(_, .branch): title = String(localized: "Branches")
        case .group(_, .derived): title = String(localized: "Delegated Chats")
        }
        cell.configure(row: row, summary: summary, title: title)
        cell.onToggle = { [weak self] in self?.toggle(item) }
        cell.configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
            if state.isSelected || state.isHighlighted {
                background.backgroundColor = Self.selectionColor
            }
            cell.backgroundConfiguration = background
        }
        return cell
    }.then {
        $0.sectionTitle = { Self.title(for: $0) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let center = NotificationCenter.default
        for name in [
            NSNotification.Name.NSCalendarDayChanged,
            NSNotification.Name.NSSystemTimeZoneDidChange,
            NSLocale.currentLocaleDidChangeNotification,
            UIApplication.willEnterForegroundNotification,
        ] {
            center.addObserver(self, selector: #selector(datePresentationChanged), name: name, object: nil)
        }

        view.addSubview(searchField)
        view.addSubview(newChatButton)
        view.addSubview(tableView)

        searchField.snp.makeConstraints { x in
            x.top.equalToSuperview()
            x.leading.equalToSuperview().offset(16)
            x.trailing.equalTo(newChatButton.snp.leading).offset(-8)
        }
        newChatButton.snp.makeConstraints { x in
            x.centerY.equalTo(searchField)
            x.trailing.equalToSuperview().offset(-16)
            x.size.equalTo(40)
        }
        tableView.snp.makeConstraints { x in
            x.top.equalTo(searchField.snp.bottom).offset(8)
            x.leading.trailing.bottom.equalToSuperview()
        }

        tableView.delegate = self
        dataSource.defaultRowAnimation = .fade
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - What the sidebar asks for

    func switchProject(to name: String?) {
        guard name != projectName else { return }
        projectName = name
        query = ""
        searchField.text = ""
        selectedID = nil
        guard isViewLoaded else { return }
        reload()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let previous = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        chats = runtime.summaries.filter { $0.projectName == projectName }
        let pinChanged = chats.contains { chat in
            previous[chat.id].map { $0.isPinned != chat.isPinned } ?? false
        }
        let changedRows = chats.compactMap { chat -> UUID? in
            guard let old = previous[chat.id],
                  old != chat
            else { return nil }
            return chat.id
        }
        applySnapshot(changedRows: changedRows, restoreSelection: false, animateMove: pinChanged)
    }

    @objc private func datePresentationChanged() {
        guard isViewLoaded else { return }
        applySnapshot { [weak self] in self?.refreshSectionTitles() }
    }

    /// A heading names the day it stands for, and the words under it move:
    /// at midnight "Today" becomes "Yesterday", and a new time zone or
    /// locale renames every day. The sections themselves stay where they
    /// are, so each heading on screen is given its text again rather than
    /// reloaded: the table keeps a section count of its own that can still
    /// be ahead of the one its data source holds, and reloading a section
    /// past the end throws.
    private func refreshSectionTitles() {
        guard tableView.isFilled else { return }
        for section in 0..<tableView.numberOfSections {
            guard let header = tableView.headerView(forSection: section),
                  let identifier = dataSource.sectionIdentifier(for: section)
            else { continue }
            header.textLabel?.text = Self.title(for: identifier)
        }
    }

    /// Picks `summary` and brings its row into sight.
    func select(_ summary: ChatSummary) {
        selectedID = summary.id
        guard isViewLoaded else { return }
        // A link to a hidden descendant must reveal it even through a search.
        if !query.isEmpty {
            query = ""
            searchField.text = ""
        }
        chats = runtime.summaries.filter { $0.projectName == projectName }
        tree = SidebarTree(chats)
        expanded = tree.revealing(summary.id, in: expanded)
        saveExpansion()
        applySnapshot()
        guard let indexPath = dataSource.indexPath(for: .chat(summary.id)) else { return }
        if tableView.indexPathsForVisibleRows?.contains(indexPath) != true {
            tableView.scrollToRow(at: indexPath, at: .none, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    /// Deletes a conversation, from its row or the chat's More menu
    /// (`origin`), asking first as `ChatDeletion` says; `presenter` asks.
    func delete(
        _ id: UUID,
        from origin: ChatDeletion.Origin,
        presenter: UIViewController,
        onDeleted: @escaping () -> Void,
    ) {
        guard let chat = runtime.summary(id) else { return }
        guard let confirmation = ChatDeletion.confirmation(for: chat, from: origin) else {
            delete(id, onDeleted: onDeleted)
            return
        }
        let name = chat.displayTitle
        switch confirmation {
        case .delete:
            presenter.presentConfirmation(
                title: "Delete Conversation?",
                message: "“\(name)” and its messages will be deleted. This cannot be undone.",
                confirmTitle: "Delete",
                destructive: true,
            ) { [weak self] in self?.delete(id, onDeleted: onDeleted) }
        case .stopAndDelete:
            presenter.presentConfirmation(
                title: "Delete Conversation?",
                message: "“\(name)” is still working. It will be stopped, then deleted with its messages. This cannot be undone.",
                confirmTitle: "Stop and Delete",
                destructive: true,
            ) { [weak self] in self?.delete(id, onDeleted: onDeleted) }
        }
    }

    /// Stops it if it is working by then, as Stop does, closes its session,
    /// removes its history and leaves the page to what is picked next. A
    /// stop that fails leaves the run to the close, which ends it too.
    private func delete(_ id: UUID, onDeleted: @escaping () -> Void) {
        Task {
            if runtime.records[id]?.summary.isWorking == true {
                try? await runtime.stop(id, continueQueue: false)
            }
            do {
                try await runtime.delete(id)
                if selectedID == id { selectedID = nil }
                onDeleted()
                refresh()
            } catch { presentNotice(title: "Unable to Delete Chat", message: error.readableMessage) }
        }
    }

    private func togglePin(_ id: UUID) {
        runtime.togglePin(id)
        refresh()
    }

    private func stop(_ id: UUID) {
        Task {
            do { try await runtime.stop(id) }
            catch { presentNotice(title: "Unable to Stop", message: error.readableMessage) }
        }
    }

    // MARK: - The list

    private func reload() {
        chats = runtime?.summaries.filter { $0.projectName == projectName } ?? []
        applySnapshot()
    }

    private func chat(_ id: UUID) -> ChatSummary? {
        chats.first { $0.id == id }
    }

    private func toggle(_ item: SidebarTree.Item) {
        guard rows[item]?.expandable == true else { return }
        // Search temporarily reveals paths. Clear it before a manual collapse
        // and retain the visible expansion so that the requested node closes.
        if !query.isEmpty {
            expanded.formUnion(rows.values.filter(\.expanded).map { $0.item.storageKey })
            query = ""
            searchField.text = ""
        }
        if !expanded.insert(item.storageKey).inserted { expanded.remove(item.storageKey) }
        saveExpansion()
        pacing.begin()
        applySnapshot()
    }

    @objc dynamic private func saveExpansion() {
        UserDefaults.standard.set(expanded.sorted(), forKey: "sidebar.expandedConversations.v1")
    }

    private func applySnapshot(
        changedRows: [UUID] = [],
        restoreSelection: Bool = true,
        animateMove: Bool = false,
        completion: (() -> Void)? = nil,
    ) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, SidebarTree.Item>()
        tree = SidebarTree(chats)
        let shown = tree.roots(query: query)
        let order = SidebarOrder.sections(of: shown)
        let previousRows = rows
        rows = [:]
        func append(_ roots: [UUID]) {
            for root in roots {
                let branch = tree.rows(under: root, expanded: expanded, query: query)
                snapshot.appendItems(branch.map(\.item))
                for row in branch { rows[row.item] = row }
            }
        }
        // A pinned descendant promotes the whole tree; it never appears twice.
        snapshot.appendSections([.pinned])
        append(order.pinned)
        for day in order.days {
            snapshot.appendSections([.day(day.start)])
            append(day.chats)
        }
        let current = dataSource.snapshot()
        let old = Set(current.itemIdentifiers)
        let changed = Set(changedRows.map { SidebarTree.Item.chat($0) })
        let reconfigured = snapshot.itemIdentifiers.filter {
            old.contains($0) && (changed.contains($0) || previousRows[$0] != rows[$0])
        }
        snapshot.reconfigureItems(reconfigured)
        let hasChanges = !reconfigured.isEmpty || current.sectionIdentifiers != snapshot.sectionIdentifiers
            || current.itemIdentifiers != snapshot.itemIdentifiers
            || snapshot.itemIdentifiers.contains { current.sectionIdentifier(containingItem: $0) != snapshot.sectionIdentifier(containingItem: $0) }
        // Streamed text changes nothing here, and an unchanged row is never
        // rebuilt: its open swipe actions would close.
        tableView.backgroundView?.isHidden = !shown.isEmpty
        guard tableView.isFilled else {
            pacing.begin()
            dataSource.applyFirst(snapshot, to: tableView) { [weak self] in
                self?.selectPicked()
                completion?()
            }
            return
        }
        if hasChanges {
            let pacedAnimation = pacing.animatesChange(in: tableView)
            let animated = animateMove
                ? tableView.window != nil && !UIAccessibility.isReduceMotionEnabled
                : pacedAnimation
            dataSource.applyChange(snapshot, to: tableView, animated: animated) { [weak self] in
                self?.selectPicked()
                completion?()
            }
        }
        if !hasChanges, restoreSelection {
            selectPicked()
        }
        if !hasChanges {
            completion?()
        }
    }

    private func selectPicked() {
        if let selectedID {
            // Keep the collapsed ancestor highlighted without changing which
            // conversation is open, or reopening it on every streamed update.
            let candidates = [selectedID] + tree.ancestors(of: selectedID)
            if let indexPath = candidates.compactMap({ dataSource.indexPath(for: .chat($0)) }).first {
                tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            }
        }
    }

    /// Pinned, then Today, Yesterday, the weekday within the week, then the date.
    private static func title(for section: Section) -> String {
        let now = Date()
        guard case let .day(day) = section else { return String(localized: "Pinned") }
        let calendar = Calendar.current
        switch SidebarOrder.titleKind(for: day, now: now, calendar: calendar) {
        case .today, .yesterday:
            return relativeDayFormatter.string(from: day)
        case .weekday:
            return day.formatted(dayHeading.weekday(.wide))
        case .monthDay:
            return day.formatted(dayHeading.month(.abbreviated).day())
        case .fullDate:
            return day.formatted(dayHeading.year().month(.abbreviated).day())
        }
    }
}

extension SidebarSessionsController: UITableViewDelegate {
    /// Keep empty groups available as move destinations without showing a
    /// heading or leaving a gap in the list.
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        tableView.numberOfRows(inSection: section) == 0 ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        tableView.numberOfRows(inSection: section) == 0 ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    func tableView(_: UITableView, heightForRowAt _: IndexPath) -> CGFloat {
        max(48, UIFont.preferredFont(forTextStyle: .body).lineHeight + 24)
    }

    /// Categories expand in place; selecting a chat still opens it.
    func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        guard let id = item.chatID else {
            toggle(item)
            return
        }
        selectedID = id
        onSelect?(chat(id), true)
    }

    // MARK: Pin, stop and delete

    func tableView(
        _: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath)?.chatID, let chat = chat(id) else { return nil }
        return UISwipeActionsConfiguration(actions: ChatRowAction.leadingSwipe(for: chat).map { swipeAction($0, for: id) })
    }

    /// Never nil, which would put UIKit's default Delete on the row, one
    /// that does nothing here.
    func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath)?.chatID, let chat = chat(id) else {
            return UISwipeActionsConfiguration(actions: [])
        }
        let actions = UISwipeActionsConfiguration(
            actions: ChatRowAction.trailingSwipe(for: chat).map { swipeAction($0, for: id) },
        )
        // a full swipe deletes one at rest; one that works keeps Stop beside Delete
        actions.performsFirstActionWithFullSwipe = !chat.isWorking
        return actions
    }

    private func swipeAction(_ action: ChatRowAction, for id: UUID) -> UIContextualAction {
        switch action {
        case .pin, .unpin:
            let pin = UIContextualAction(
                style: .normal,
                title: action == .unpin ? String(localized: "Unpin") : String(localized: "Pin"),
            ) { [weak self] _, _, completion in
                // the swipe's own transaction has to end for the row to settle
                completion(true)
                DispatchQueue.main.async { [weak self] in self?.togglePin(id) }
            }
            pin.image = UIImage(systemName: action == .unpin ? "pin.slash.fill" : "pin.fill")
            pin.backgroundColor = .systemOrange
            return pin
        case .stop:
            let stop = UIContextualAction(
                style: .normal,
                title: String(localized: "Stop"),
            ) { [weak self] _, _, completion in
                completion(true)
                self?.stop(id)
            }
            stop.image = UIImage(systemName: "stop.fill")
            stop.backgroundColor = .darkGray
            return stop
        case .delete:
            let delete = UIContextualAction(
                style: .destructive,
                title: String(localized: "Delete"),
            ) { [weak self] _, _, completion in
                // The snapshot removes the row only after deletion succeeds.
                completion(false)
                guard let self else { return }
                delete(id, from: .sidebarRow, presenter: self) { [weak self] in
                    self?.onSelect?(nil, false)
                }
            }
            delete.image = UIImage(systemName: "trash.fill")
            return delete
        }
    }

    /// A swipe that ends after the list changed under it, as deleting the
    /// picked conversation does, leaves no row highlighted.
    func tableView(_: UITableView, didEndEditingRowAt _: IndexPath?) {
        applySnapshot()
    }

    /// The swipes' actions, for a long press and a pointer.
    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath)?.chatID, let chat = chat(id) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIAction] = []
            for action in ChatRowAction.menu(for: chat) {
                if action == .delete {
                    actions.append(ChatActions.renameAction(for: id, runtime: runtime, from: self))
                }
                actions.append(menuAction(action, for: id))
            }
            return UIMenu(children: actions)
        }
    }

    private func menuAction(_ action: ChatRowAction, for id: UUID) -> UIAction {
        switch action {
        case .pin, .unpin:
            UIAction(
                title: action == .unpin ? String(localized: "Unpin") : String(localized: "Pin"),
                image: UIImage(systemName: action == .unpin ? "pin.slash" : "pin"),
            ) { [weak self] _ in self?.togglePin(id) }
        case .stop:
            UIAction(
                title: String(localized: "Stop"),
                image: UIImage(systemName: "stop.fill"),
            ) { [weak self] _ in self?.stop(id) }
        case .delete:
            UIAction(
                title: String(localized: "Delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive,
            ) { [weak self] _ in
                guard let self else { return }
                delete(id, from: .sidebarRow, presenter: self) { [weak self] in
                    self?.onSelect?(nil, false)
                }
            }
        }
    }
}

/// A diffable table data source whose rows can be swiped: UIKit offers a
/// row's swipe actions only when its data source calls it editable, and a
/// diffable one says no unless it is told otherwise. Xrash's, with each
/// section's header title from `sectionTitle`.
final class SwipeableTableDataSource<Section: Hashable, Item: Hashable>:
    UITableViewDiffableDataSource<Section, Item>
{
    var sectionTitle: ((Section) -> String?)?

    override func tableView(_: UITableView, canEditRowAt _: IndexPath) -> Bool {
        true
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section).flatMap { sectionTitle?($0) }
    }
}
