import SnapKit
import Then
import UIKit

/// The branches page: the current branch, the branch and tag sections in
/// their trees, and the sheets and dialogs that switch, merge, create,
/// rename and delete them.
final class GitBranchesPage: UIViewController, GitPage {
    struct RefRow {
        let name: String
        let fullName: String
        let subtitle: String?
        let kind: Kind
        let isCurrent: Bool
        let indent: CGFloat
        let loading: Bool
        let branch: GitBranch?
        let tag: GitTag?
        let actions: [Action]

        enum Kind { case branch, remote, tag, commit }
        enum Action { case switchTo, merge, rename, delete }
    }

    struct RefHeader {
        let key: String
        let title: String
        var add: (() -> Void)?
        var indent: CGFloat = 0
    }

    enum Item {
        case overview
        case header(RefHeader)
        case ref(RefRow)
        case empty(String)
    }

    private let session: GitSession
    weak var host: GitPageHost?

    private let table = UITableView(frame: .zero, style: .plain)
    private(set) var items: [Item] = []
    private var expanded: [String: Bool] = [:]
    private var checkoutLoading: String?
    private var busy = false {
        didSet {
            host?.gitSetBusy(busy)
            table.reloadData()
        }
    }

    init(session: GitSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 56
        table.showsVerticalScrollIndicator = false
        table.register(GitBranchesOverviewCell.self, forCellReuseIdentifier: "overview")
        table.register(GitRefHeaderCell.self, forCellReuseIdentifier: "header")
        table.register(GitRefRowCell.self, forCellReuseIdentifier: "row")
        table.register(GitBranchEmptyCell.self, forCellReuseIdentifier: "empty")
        view.addSubview(table)
        table.snp.makeConstraints { make in make.edges.equalToSuperview() }
        applyBottomInset()
        applySession()
    }

    func applyBottomInset() {
        table.contentInset.bottom = 70 + view.safeAreaInsets.bottom
        table.verticalScrollIndicatorInsets.bottom = 70 + view.safeAreaInsets.bottom
    }

    func pageDidAppear() {
        guard session.branches == nil else { return }
        Task { @MainActor in await session.reloadBranches() }
    }

    private var currentBranchName: String? {
        session.localBranches.first(where: \.isCurrent)?.name
    }

    private func isExpanded(_ key: String) -> Bool {
        expanded[key] ?? true
    }

    // MARK: - Building

    func applySession() {
        var items: [Item] = []
        guard let branches = session.branches else {
            items.append(.empty(String(localized: "Loading branch list…")))
            self.items = items
            table.reloadData()
            return
        }
        items.append(.overview)
        let hasCurrent = branches.local.contains(where: \.isCurrent)
        let current = currentBranchName

        items.append(.header(RefHeader(key: "head", title: "HEAD")))
        if isExpanded("head") {
            if let current {
                items.append(.ref(RefRow(
                    name: current,
                    fullName: current,
                    subtitle: String(localized: "Checked out"),
                    kind: .commit,
                    isCurrent: true,
                    indent: 1,
                    loading: false,
                    branch: branches.local.first { $0.name == current },
                    tag: nil,
                    actions: [.rename]
                )))
            } else {
                items.append(.ref(RefRow(
                    name: String(localized: "No branch checked out"),
                    fullName: "",
                    subtitle: hasCurrent ? nil : String(localized: "detached HEAD: not on any branch"),
                    kind: .commit,
                    isCurrent: false,
                    indent: 1,
                    loading: false,
                    branch: nil,
                    tag: nil,
                    actions: []
                )))
            }
        }

        let local = branches.local
        if !local.isEmpty {
            items.append(.header(RefHeader(
                key: "local",
                title: "\(String(localized: "Local")) (\(local.count))",
                add: { [weak self] in self?.showCreateBranch() }
            )))
            if isExpanded("local") {
                appendTree(local, isRemote: false, depth: 1, to: &items)
            }
        }
        let remote = branches.remote
        if !remote.isEmpty {
            items.append(.header(RefHeader(
                key: "remote",
                title: "\(String(localized: "Remote")) (\(remote.count))"
            )))
            if isExpanded("remote") {
                appendTree(remote, isRemote: true, depth: 1, to: &items)
            }
        }
        let tags = branches.tags
        if !tags.isEmpty {
            items.append(.header(RefHeader(
                key: "tags",
                title: "\(String(localized: "Tags")) (\(tags.count))",
                add: { [weak self] in self?.showCreateTag() }
            )))
            if isExpanded("tags") {
                for tag in tags.sorted(by: { $0.name < $1.name }) {
                    items.append(.ref(RefRow(
                        name: tag.name,
                        fullName: tag.name,
                        subtitle: String(tag.commit.prefix(7)),
                        kind: .tag,
                        isCurrent: false,
                        indent: 1,
                        loading: checkoutLoading == tag.name,
                        branch: nil,
                        tag: tag,
                        actions: [.switchTo, .delete]
                    )))
                }
            }
        }
        if local.isEmpty, remote.isEmpty, tags.isEmpty {
            items.append(.empty(String(localized: "No branches")))
        }
        self.items = items
        table.reloadData()
    }

    private func appendTree(_ branches: [GitBranch], isRemote: Bool, depth: Int, to items: inout [Item]) {
        let tree = GitRefTree.build(branches)
        appendNodes(tree, isRemote: isRemote, depth: depth, to: &items)
    }

    private func appendNodes(_ nodes: [GitRefTree.Node], isRemote: Bool, depth: Int, to items: inout [Item]) {
        for node in nodes {
            if !node.children.isEmpty {
                let key = "\(isRemote ? "remote" : "local")/\(node.fullName)"
                items.append(.header(RefHeader(key: key, title: node.segment, indent: CGFloat(depth))))
                if isExpanded(key) {
                    appendNodes(node.children, isRemote: isRemote, depth: depth + 1, to: &items)
                }
            } else if let branch = node.branch {
                let actions: [RefRow.Action] = isRemote
                    ? [.switchTo, .merge, .delete]
                    : branch.isCurrent ? [.rename] : [.switchTo, .merge, .rename, .delete]
                items.append(.ref(RefRow(
                    name: node.segment,
                    fullName: branch.name,
                    subtitle: isRemote ? nil : subtitle(branch),
                    kind: isRemote ? .remote : .branch,
                    isCurrent: branch.isCurrent,
                    indent: CGFloat(depth),
                    loading: checkoutLoading == branch.name,
                    branch: branch,
                    tag: nil,
                    actions: actions
                )))
            }
        }
    }

    private func subtitle(_ branch: GitBranch) -> String? {
        var parts: [String] = []
        if branch.isCurrent { parts.append(String(localized: "Checked out")) }
        if let upstream = branch.upstream {
            var sync: [String] = []
            if branch.ahead > 0 { sync.append(String(localized: "\(branch.ahead) to push")) }
            if branch.behind > 0 { sync.append(String(localized: "\(branch.behind) to pull")) }
            parts.append(sync.isEmpty
                ? "\(upstream) \(String(localized: "Synced"))"
                : "\(upstream) \(sync.joined(separator: " · "))")
        } else {
            parts.append(String(localized: "No upstream set"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func act(_ action: RefRow.Action, row: RefRow) {
        switch action {
        case .switchTo:
            if let tag = row.tag {
                confirmSwitch(ref: tag.name, isTag: true, isRemote: false)
            } else if let branch = row.branch {
                confirmSwitch(ref: branch.name, isTag: false, isRemote: branch.isRemote)
            }
        case .merge:
            if let branch = row.branch { showMerge(branch) }
        case .rename:
            if let branch = row.branch { showRename(branch) }
        case .delete:
            if let tag = row.tag {
                confirmDeleteTag(tag)
            } else if let branch = row.branch {
                confirmDelete(branch)
            }
        }
    }

    private func confirmSwitch(ref: String, isTag: Bool, isRemote: Bool) {
        let message: String
        if isTag {
            message = String(localized: "Switching to tag \(ref) will enter detached HEAD state — not on any branch, new commits wont belong to any branch. Continue?")
        } else if isRemote {
            message = String(localized: "Create a local tracking branch from remote branch \(ref) and switch?")
        } else {
            message = String(localized: "Switch to \(ref)?")
        }
        presentGitDialog(
            title: String(localized: "Switch Branch"),
            message: message,
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Switch")) { [weak self] in
                    self?.checkout(ref, remote: isRemote)
                }
            ]
        )
    }

    private func checkout(_ ref: String, remote: Bool) {
        checkoutLoading = ref
        applySession()
        host?.gitSetBusy(true)
        Task { @MainActor in
            do {
                try await session.checkout(name: ref, remote: remote)
                host?.gitShowToast(String(localized: "Switched to \(ref)"))
            } catch {
                host?.gitShowToast(String(localized: "Switch failed: \(error.readableMessage)"))
            }
            checkoutLoading = nil
            host?.gitSetBusy(false)
            applySession()
        }
    }

    private func showMerge(_ branch: GitBranch) {
        let noFastForward = GitSwitchRow(title: String(localized: "Create a merge commit (--no-ff)"))
        let content = UIView()
        content.addSubview(noFastForward)
        noFastForward.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.height.equalTo(36)
        }
        let current = session.currentBranch ?? "HEAD"
        presentGitDialog(
            title: String(localized: "Merge Branch"),
            message: String(localized: "Merge branch \(branch.name) into current branch (\(current))?"),
            content: content,
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Merge Branch")) { [weak self] in
                    guard let self else { return }
                    self.busy = true
                    Task { @MainActor in
                        do {
                            _ = try await self.session.merge(
                                branch.name, noFastForward: noFastForward.toggle.isOn
                            )
                        } catch {
                            self.host?.gitShowToast(error.readableMessage)
                        }
                        self.busy = false
                    }
                }
            ]
        )
    }

    private func showCreateBranch() {
        let sheet = GitBottomSheetController(title: String(localized: "New Branch"))
        let name = GitTextField(label: String(localized: "Branch name"))
        var start = session.currentBranch ?? "HEAD"
        let startButton = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "Base branch")
        configuration.subtitle = start
        configuration.baseForegroundColor = GitTheme.onSurface
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.background.strokeColor = GitTheme.outline
        configuration.background.strokeWidth = 1
        configuration.background.cornerRadius = 12
        startButton.configuration = configuration
        startButton.contentHorizontalAlignment = .leading
        startButton.showsMenuAsPrimaryAction = true
        startButton.menu = UIMenu(children: session.localBranches.map { branch in
            UIAction(title: branch.name, state: branch.name == start ? .on : .off) { _ in
                start = branch.name
                var changed = startButton.configuration
                changed?.subtitle = start
                startButton.configuration = changed
            }
        })
        let checkout = GitSwitchRow(title: String(localized: "Create and Switch"), isOn: true)
        let create = GitButtons.primary(title: String(localized: "Create"))
        create.isEnabled = false
        name.field.addAction(UIAction { _ in
            create.isEnabled = !name.text.trimmingCharacters(in: .whitespaces).isEmpty
        }, for: .editingChanged)
        let content = UIStackView(arrangedSubviews: [name, startButton, checkout, create]).then {
            $0.axis = .vertical
            $0.spacing = 12
        }
        create.addAction(UIAction { [weak sheet, weak self] _ in
            guard let self else { return }
            let branchName = name.text.trimmingCharacters(in: .whitespaces)
            guard !branchName.isEmpty else { return }
            sheet?.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.busy = true
                Task { @MainActor in
                    do {
                        try await self.session.createBranch(
                            name: branchName, startPoint: start, checkout: checkout.toggle.isOn
                        )
                    } catch {
                        self.host?.gitShowToast(error.readableMessage)
                    }
                    self.busy = false
                }
            }
        }, for: .touchUpInside)
        let wrapper = UIView()
        wrapper.addSubview(content)
        content.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        sheet.stack.addArrangedSubview(wrapper)
        present(sheet, animated: true)
    }

    private func showCreateTag() {
        let sheet = GitBottomSheetController(title: String(localized: "New Tag"))
        let name = GitTextField(label: String(localized: "Tag name"))
        let description = UILabel().then {
            $0.text = String(localized: "Create lightweight tag from current HEAD (\(session.currentBranch ?? "HEAD"))")
            $0.font = GitTheme.bodySmall
            $0.textColor = GitTheme.onSurfaceVariant
            $0.numberOfLines = 0
        }
        let create = GitButtons.primary(title: String(localized: "Create"))
        create.isEnabled = false
        name.field.addAction(UIAction { _ in
            create.isEnabled = !name.text.trimmingCharacters(in: .whitespaces).isEmpty
        }, for: .editingChanged)
        let cancel = GitButtons.text(title: String(localized: "Cancel"))
        cancel.addAction(UIAction { [weak sheet] _ in sheet?.dismiss(animated: true) }, for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [cancel, create]).then {
            $0.axis = .horizontal
            $0.spacing = 8
            $0.alignment = .center
        }
        create.addAction(UIAction { [weak sheet, weak self] _ in
            guard let self else { return }
            let tagName = name.text.trimmingCharacters(in: .whitespaces)
            guard !tagName.isEmpty else { return }
            sheet?.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.busy = true
                Task { @MainActor in
                    do {
                        try await self.session.createTag(name: tagName, commit: nil, message: nil)
                    } catch {
                        self.host?.gitShowToast(error.readableMessage)
                    }
                    self.busy = false
                }
            }
        }, for: .touchUpInside)
        let content = UIStackView(arrangedSubviews: [name, description, actions]).then {
            $0.axis = .vertical
            $0.spacing = 12
        }
        let wrapper = UIView()
        wrapper.addSubview(content)
        content.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        sheet.stack.addArrangedSubview(wrapper)
        present(sheet, animated: true)
    }

    private func showRename(_ branch: GitBranch) {
        let field = GitTextField(label: String(localized: "New branch name"))
        field.text = branch.name
        presentGitDialog(
            title: String(localized: "Rename Branch"),
            message: String(localized: "Rename \(branch.name) to:"),
            content: field,
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Rename")) { [weak self] in
                    guard let self else { return }
                    let newName = field.text.trimmingCharacters(in: .whitespaces)
                    guard !newName.isEmpty, newName != branch.name else { return }
                    self.busy = true
                    Task { @MainActor in
                        do {
                            try await self.session.renameBranch(from: branch.name, to: newName)
                        } catch {
                            self.host?.gitShowToast(error.readableMessage)
                        }
                        self.busy = false
                    }
                }
            ]
        )
    }

    private func confirmDelete(_ branch: GitBranch) {
        let remote = branch.isRemote
        presentGitDialog(
            title: remote ? String(localized: "Delete Remote Branch") : String(localized: "Delete Branch"),
            message: remote
                ? String(localized: "Delete remote branch \(branch.name)? This action cannot be undone.")
                : String(localized: "Delete local branch \(branch.name)?"),
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Delete"), destructive: true) { [weak self] in
                    guard let self else { return }
                    self.busy = true
                    Task { @MainActor in
                        do {
                            try await self.session.deleteBranch(branch)
                        } catch {
                            self.host?.gitShowToast(error.readableMessage)
                        }
                        self.busy = false
                    }
                }
            ]
        )
    }

    private func confirmDeleteTag(_ tag: GitTag) {
        presentGitDialog(
            title: String(localized: "Delete Tag"),
            message: String(localized: "Delete local tag \(tag.name)?"),
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Delete"), destructive: true) { [weak self] in
                    guard let self else { return }
                    self.busy = true
                    Task { @MainActor in
                        do {
                            try await self.session.deleteTag(tag.name)
                        } catch {
                            self.host?.gitShowToast(error.readableMessage)
                        }
                        self.busy = false
                    }
                }
            ]
        )
    }
}

// MARK: - Table

extension GitBranchesPage: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch items[indexPath.row] {
        case .overview:
            let cell = tableView.dequeueReusableCell(withIdentifier: "overview", for: indexPath) as! GitBranchesOverviewCell
            cell.configure(
                current: currentBranchName ?? String(localized: "No branch checked out"),
                detached: !session.localBranches.contains(where: \.isCurrent),
                local: session.localBranches.count,
                remote: session.remoteBranches.count,
                tags: session.tags.count
            )
            return cell
        case let .header(header):
            let cell = tableView.dequeueReusableCell(withIdentifier: "header", for: indexPath) as! GitRefHeaderCell
            cell.configure(
                title: header.title,
                expanded: isExpanded(header.key),
                indent: header.indent,
                hasAdd: header.add != nil,
                onToggle: { [weak self] in
                    guard let self else { return }
                    self.expanded[header.key] = !self.isExpanded(header.key)
                    self.applySession()
                },
                onAdd: header.add
            )
            return cell
        case let .ref(row):
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! GitRefRowCell
            cell.configure(row: row)
            return cell
        case let .empty(text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "empty", for: indexPath) as! GitBranchEmptyCell
            cell.configure(text: text, loading: session.branches == nil)
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard case let .ref(row) = items[indexPath.row], !row.actions.isEmpty else { return }
        presentGitSheet(title: row.fullName, rows: row.actions.map { action in
            switch action {
            case .switchTo:
                .init(title: String(localized: "Switch"), symbol: GitIcon.Name.commit) { [weak self] in
                    self?.act(action, row: row)
                }
            case .merge:
                .init(title: String(localized: "Merge Branch"), symbol: GitIcon.Name.merge) { [weak self] in
                    self?.act(action, row: row)
                }
            case .rename:
                .init(title: String(localized: "Rename"), symbol: GitIcon.Name.editSquare) { [weak self] in
                    self?.act(action, row: row)
                }
            case .delete:
                .init(title: String(localized: "Delete"), symbol: GitIcon.Name.trash, destructive: true) { [weak self] in
                    self?.act(action, row: row)
                }
            }
        })
    }
}

// MARK: - Cells

private final class GitBranchesOverviewCell: UITableViewCell {
    private let icon = UIImageView(image: GitIcon.image(GitIcon.Name.branch, pointSize: 18))
    private let title = UILabel().then {
        $0.text = String(localized: "Current branch")
        $0.font = GitTheme.labelMedium
        $0.textColor = GitTheme.onSurfaceVariant
    }
    private let branch = UILabel().then {
        $0.font = GitTheme.mono(16, .medium)
        $0.textColor = GitTheme.onSurface
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
    }
    private let detached = UILabel().then {
        $0.text = String(localized: "detached HEAD: not on any branch")
        $0.font = GitTheme.labelSmall
        $0.textColor = GitTheme.error
    }
    private let metrics = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        let card = UIView().then {
            $0.backgroundColor = GitTheme.cardSurface
            $0.layer.cornerRadius = 14
            $0.layer.cornerCurve = .continuous
        }
        icon.tintColor = GitTheme.primary
        icon.contentMode = .scaleAspectFit
        let text = UIStackView(arrangedSubviews: [title, branch, detached]).then {
            $0.axis = .vertical
            $0.spacing = 0
            $0.alignment = .leading
        }
        let head = UIStackView(arrangedSubviews: [icon, text]).then {
            $0.axis = .horizontal
            $0.spacing = GitTheme.Space.sm
            $0.alignment = .center
        }
        icon.snp.makeConstraints { make in make.size.equalTo(18) }
        metrics.axis = .horizontal
        metrics.spacing = GitTheme.Space.sm
        metrics.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [head, metrics]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.md
        }
        card.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(GitTheme.Space.lg)
        }
        contentView.addSubview(card)
        card.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalToSuperview()
            make.bottom.equalToSuperview().offset(-4)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(current: String, detached isDetached: Bool, local: Int, remote: Int, tags: Int) {
        branch.text = current
        detached.isHidden = !isDetached
        metrics.arrangedSubviews.forEach { $0.removeFromSuperview() }
        metrics.addArrangedSubview(GitMetricView(
            title: String(localized: "Local"), count: local, color: GitTheme.primary
        ))
        metrics.addArrangedSubview(GitMetricView(
            title: String(localized: "Remote"), count: remote, color: GitTheme.secondary
        ))
        metrics.addArrangedSubview(GitMetricView(
            title: String(localized: "Tags"), count: tags, color: GitTheme.tertiary
        ))
    }
}

private final class GitRefHeaderCell: UITableViewCell {
    private let chevron = UIImageView()
    private let label = UILabel()
    private let add = UIButton(type: .system)
    private var onToggle: (() -> Void)?
    private var onAdd: (() -> Void)?
    private var row: UIStackView!
    private var leading: Constraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        chevron.tintColor = GitTheme.subtleText
        chevron.contentMode = .scaleAspectFit
        label.font = GitTheme.font(13, .regular)
        label.textColor = GitTheme.subtleText
        add.tintColor = GitTheme.onSurfaceVariant
        add.setImage(GitIcon.image(GitIcon.Name.plus, pointSize: 16), for: .normal)
        add.accessibilityLabel = String(localized: "New")
        row = UIStackView(arrangedSubviews: [chevron, label, add]).then {
            $0.axis = .horizontal
            $0.spacing = GitTheme.Space.xs
            $0.alignment = .center
        }
        chevron.snp.makeConstraints { make in make.size.equalTo(16) }
        add.snp.makeConstraints { make in make.size.equalTo(28) }
        contentView.addSubview(row)
        row.snp.makeConstraints { make in
            leading = make.leading.equalToSuperview().offset(12).constraint
            make.trailing.equalToSuperview().offset(-8)
            make.top.equalToSuperview().offset(8)
            make.bottom.equalToSuperview().offset(-4)
        }
        add.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        title: String,
        expanded: Bool,
        indent: CGFloat,
        hasAdd: Bool,
        onToggle: @escaping () -> Void,
        onAdd: (() -> Void)?
    ) {
        label.text = title
        chevron.image = GitIcon.image(
            expanded ? GitIcon.Name.chevronDown : GitIcon.Name.chevronRight, pointSize: 16
        )
        add.isHidden = !hasAdd
        self.onAdd = onAdd
        self.onToggle = onToggle
        leading?.update(offset: 12 + max(indent - 1, 0) * 16)
        // The cell is a container: the word is the element VoiceOver reads,
        // and the add button keeps its own name.
        label.isAccessibilityElement = true
        label.accessibilityTraits = .header
    }

    @objc private func tapped() {
        onToggle?()
    }
}

private final class GitRefRowCell: UITableViewCell {
    private let card = UIView()
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var iconLeading: Constraint?
    private let name = UILabel().then {
        $0.font = GitTheme.mono(14)
        $0.textColor = GitTheme.onSurface
        $0.numberOfLines = 1
        $0.lineBreakMode = .byTruncatingMiddle
    }
    private let subtitle = UILabel().then {
        $0.font = GitTheme.labelSmall
        $0.textColor = GitTheme.onSurfaceVariant
        $0.numberOfLines = 1
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(card)
        card.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.bottom.equalToSuperview()
        }
        card.addSubview(icon)
        card.addSubview(spinner)
        let text = UIStackView(arrangedSubviews: [name, subtitle]).then {
            $0.axis = .vertical
            $0.spacing = 0
        }
        card.addSubview(text)
        icon.contentMode = .scaleAspectFit
        spinner.hidesWhenStopped = true
        icon.snp.makeConstraints { make in
            iconLeading = make.leading.equalToSuperview().offset(16).constraint
            make.centerY.equalToSuperview()
            make.size.equalTo(18)
        }
        spinner.snp.makeConstraints { make in make.center.equalTo(icon) }
        text.snp.makeConstraints { make in
            make.leading.equalTo(icon.snp.trailing).offset(GitTheme.Space.md)
            make.trailing.equalToSuperview().offset(-16)
            make.top.bottom.equalToSuperview().inset(6)
            make.height.greaterThanOrEqualTo(36)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(row: GitBranchesPage.RefRow) {
        name.text = row.name
        subtitle.text = row.subtitle
        subtitle.isHidden = row.subtitle == nil
        name.textColor = row.isCurrent ? GitTheme.onPrimaryContainer : GitTheme.onSurface
        name.font = row.isCurrent ? GitTheme.mono(14, .semibold) : GitTheme.mono(14)
        subtitle.textColor = row.isCurrent ? GitTheme.primary : GitTheme.onSurfaceVariant
        card.backgroundColor = row.isCurrent ? GitTheme.primaryContainer : .clear
        icon.tintColor = row.isCurrent ? GitTheme.primary : GitTheme.onSurfaceVariant
        switch row.kind {
        case .branch:
            icon.image = GitIcon.image(GitIcon.Name.branch, pointSize: 18)
        case .remote:
            icon.image = GitIcon.image(GitIcon.Name.cloud, pointSize: 18)
        case .tag:
            icon.image = GitIcon.image(GitIcon.Name.tag, pointSize: 18)
        case .commit:
            icon.image = GitIcon.image(GitIcon.Name.commit, pointSize: 18)
        }
        if row.loading {
            spinner.startAnimating()
            icon.isHidden = true
        } else {
            spinner.stopAnimating()
            icon.isHidden = false
        }
        isAccessibilityElement = true
        accessibilityLabel = row.name
        if let subtitle = row.subtitle {
            accessibilityValue = subtitle
        }
        accessibilityTraits = row.actions.isEmpty ? .staticText : .button
        if row.isCurrent {
            accessibilityTraits.insert(.selected)
        }
        // The tree steps in by 16 pt per depth.
        iconLeading?.update(offset: 16 + max(row.indent - 1, 0) * 16)
    }
}

private final class GitBranchEmptyCell: UITableViewCell {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        label.font = GitTheme.bodyMedium
        label.textColor = GitTheme.onSurfaceVariant
        label.textAlignment = .center
        label.numberOfLines = 0
        contentView.addSubview(label)
        label.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(16)
        }
        spinner.hidesWhenStopped = true
        contentView.addSubview(spinner)
        spinner.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(label.snp.top).offset(-8)
        }
        contentView.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(120) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, loading: Bool) {
        label.text = text
        if loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }
}

/// A branch tree built from the names' path components.
enum GitRefTree {
    final class Node {
        let segment: String
        let fullName: String
        var branch: GitBranch?
        var children: [Node] = []
        init(segment: String, fullName: String, branch: GitBranch? = nil) {
            self.segment = segment
            self.fullName = fullName
            self.branch = branch
        }
    }

    /// Builds the tree: a name's `/`-separated segments become folders, and
    /// the last one carries its branch. A branch that is also a folder — a
    /// local `feature` beside `feature/x` — keeps both, so neither is lost.
    static func build(_ branches: [GitBranch]) -> [Node] {
        let root = Node(segment: "", fullName: "")
        for branch in branches.sorted(by: { $0.name < $1.name }) {
            let parts = branch.name.split(separator: "/")
            var current = root
            var path = ""
            for (index, part) in parts.enumerated() {
                path += (path.isEmpty ? "" : "/") + part
                let isLeaf = index == parts.count - 1
                if let existing = current.children.first(where: { $0.segment == String(part) }) {
                    current = existing
                } else {
                    let node = Node(segment: String(part), fullName: path)
                    current.children.append(node)
                    current = node
                }
                if isLeaf {
                    current.branch = branch
                }
            }
        }
        sort(root)
        return root.children
    }

    private static func sort(_ node: Node) {
        node.children.sort { $0.segment.lowercased() < $1.segment.lowercased() }
        node.children.forEach(sort)
    }
}
