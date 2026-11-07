import SnapKit
import Then
import UIKit

/// The first page of the sidebar: the workspaces, newest activity first, as
/// aimini's workspace tab lists them, with the way to make another above the
/// list.
///
/// General Chat is here too, last: Apelin keeps conversations no project
/// holds, and aimini has nowhere else to put them.
final class SidebarWorkspacesController: UIViewController {
    /// What a tap picks: a project, or nil for General Chat.
    var onPick: ((ProjectSummary?) -> Void)?
    var onCreate: (() -> Void)?
    var onRename: ((ProjectSummary) -> Void)?
    var onDelete: ((ProjectSummary) -> Void)?

    private enum Row: Hashable {
        case general
        case project(String)
    }

    private var projects: [ProjectSummary] = []
    private var current: ProjectSummary?
    private var chats: [ChatSummary] = []

    private lazy var newButton = UIButton(configuration: .plain()).then {
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "New Workspace")
        configuration.image = UIImage(systemName: "plus")
        configuration.imagePadding = 6
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        $0.configuration = configuration
        $0.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline)
        $0.setContentHuggingPriority(.required, for: .horizontal)
        $0.addAction(
            UIAction { [weak self] _ in self?.onCreate?() },
            for: .touchUpInside,
        )
    }

    private let tableView = FirstFillTableView(frame: .zero, style: .insetGrouped).then {
        $0.backgroundColor = .clear
        $0.register(UITableViewCell.self, forCellReuseIdentifier: "workspace")
        $0.selectionFollowsFocus = false
        // No empty state: General Chat is always here, so the list is never
        // empty, and a sentence under a full list is only noise.
    }

    private lazy var dataSource = SwipeableTableDataSource<Int, Row>(
        tableView: tableView,
    ) { [unowned self] tableView, indexPath, row in
        let cell = tableView.dequeueReusableCell(withIdentifier: "workspace", for: indexPath)
        configure(cell, for: row)
        return cell
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        view.addSubview(newButton)
        view.addSubview(tableView)
        newButton.snp.makeConstraints { x in
            x.top.equalToSuperview().offset(4)
            x.trailing.equalToSuperview().offset(-16)
            x.height.equalTo(28)
        }
        tableView.snp.makeConstraints { x in
            x.top.equalTo(newButton.snp.bottom).offset(4)
            x.leading.trailing.bottom.equalToSuperview()
        }

        tableView.delegate = self
        dataSource.defaultRowAnimation = .fade
        // One section, and no heading for it: the tabs above already say
        // which page this is.
        var snapshot = dataSource.snapshot()
        snapshot.appendSections([0])
        dataSource.applyFirst(snapshot, to: tableView)
    }

    /// The three things the page draws, as the sidebar works them out.
    func update(projects: [ProjectSummary], current: ProjectSummary?, chats: [ChatSummary]) {
        let changedProjects = self.projects != projects
        self.projects = projects
        self.current = current
        self.chats = chats
        guard isViewLoaded else { return }
        if changedProjects || dataSource.snapshot().itemIdentifiers.isEmpty {
            applySnapshot()
        } else {
            applySnapshot(reloads: true)
        }
    }

    private func applySnapshot(reloads: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        let rows = Self.order(projects: projects, chats: chats)
        snapshot.appendItems(rows, toSection: 0)
        if reloads {
            let existing = dataSource.snapshot().itemIdentifiers
            snapshot.reloadItems(rows.filter { existing.contains($0) })
        }
        dataSource.applyChange(snapshot, to: tableView, animated: false) { [weak self] in
            self?.selectCurrent()
        }
    }

    /// Newest activity first, as aimini sorts: a workspace whose last
    /// conversation is recent comes before one never opened, and the names
    /// break the ties.
    private static func order(projects: [ProjectSummary], chats: [ChatSummary]) -> [Row] {
        var latest: [String: Date] = [:]
        for chat in chats {
            guard let name = chat.projectName else { continue }
            latest[name] = max(latest[name] ?? .distantPast, chat.lastInteraction)
        }
        let sorted = projects.sorted { left, right in
            let leftTime = latest[left.name] ?? .distantPast
            let rightTime = latest[right.name] ?? .distantPast
            if leftTime != rightTime { return leftTime > rightTime }
            return left.displayTitle.localizedStandardCompare(right.displayTitle) == .orderedAscending
        }
        return [.general] + sorted.map { .project($0.name) }
    }

    private func selectCurrent() {
        let row: Row = current.map { .project($0.name) } ?? .general
        guard let indexPath = dataSource.indexPath(for: row) else { return }
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
    }

    private func configure(_ cell: UITableViewCell, for row: Row) {
        let summary = project(for: row)
        var content = UIListContentConfiguration.subtitleCell()
        content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
        content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
        content.imageProperties.cornerRadius = 7
        switch row {
        case .general:
            content.text = String(localized: "General Chat")
            content.secondaryText = String(localized: "Conversations outside any workspace")
            content.image = UIImage(systemName: "bubble.left.and.bubble.right")
            content.imageProperties.tintColor = .secondaryLabel
        case .project:
            content.text = summary?.displayTitle
            content.secondaryText = summary.map { "projects/\($0.name)" }
            content.image = summary.flatMap { ProjectIcon.image(for: $0) }
        }
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryView = runningChip(for: row)
        // A row the reader can act on from a long press; the swipes carry
        // the two destructive ones.
        cell.accessibilityValue = cell.accessoryView?.accessibilityLabel
        cell.configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
            if state.isSelected || state.isHighlighted {
                background.backgroundColor = Self.selectionColor
            }
            cell.backgroundConfiguration = background
        }
    }

    /// A picked row's ground, lighter than the system's, as the conversations
    /// page draws it.
    private static let selectionColor = UIColor(
        light: UIColor.black.withAlphaComponent(0.1),
        dark: UIColor.white.withAlphaComponent(0.1),
    )

    /// How many of the workspace's conversations are working, as aimini's
    /// chip says; nil when none is.
    private func runningChip(for row: Row) -> UIView? {
        let name: String? = switch row {
        case .general: nil
        case let .project(name): name
        }
        let count = chats.filter { $0.projectName == name && $0.isWorking }.count
        guard count > 0 else { return nil }
        let label = UILabel()
        label.text = "\(count)"
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textColor = .label
        label.textAlignment = .center
        label.sizeToFit()
        let height = max(22, ceil(label.bounds.height) + 4)
        let width = max(height, ceil(label.bounds.width) + 14)
        // UITableView sizes an accessory from its frame, not constraints
        // inside a zero-sized container. Reserve room for every digit.
        let capsule = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        capsule.backgroundColor = .tertiarySystemFill
        capsule.layer.cornerRadius = height / 2
        capsule.layer.cornerCurve = .continuous
        label.frame = capsule.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        capsule.addSubview(label)
        capsule.isAccessibilityElement = true
        capsule.accessibilityLabel = String(localized: "\(count) working")
        return capsule
    }

    private func project(for row: Row) -> ProjectSummary? {
        guard case let .project(name) = row else { return nil }
        return projects.first { $0.name == name }
    }
}

extension SidebarWorkspacesController: UITableViewDelegate {
    func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        onPick?(dataSource.itemIdentifier(for: indexPath).flatMap(project(for:)))
    }

    /// A workspace's folder is its identity; a swipe can only take the whole
    /// thing away, which asks first.
    func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let row = dataSource.itemIdentifier(for: indexPath), let summary = project(for: row) else {
            return UISwipeActionsConfiguration(actions: [])
        }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, completion in
            completion(false)
            self?.onDelete?(summary)
        }
        delete.image = UIImage(systemName: "trash.fill")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let row = dataSource.itemIdentifier(for: indexPath), let summary = project(for: row) else {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Rename…"), image: UIImage(systemName: "pencil")) { [weak self] _ in
                    self?.onRename?(summary)
                },
                UIAction(
                    title: String(localized: "Delete"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive,
                ) { [weak self] _ in
                    self?.onDelete?(summary)
                },
            ])
        }
    }
}
