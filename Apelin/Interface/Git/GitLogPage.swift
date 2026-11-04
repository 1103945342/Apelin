import SnapKit
import Then
import UIKit

/// The commits page: a search field, the graph of the loaded history, and a
/// sheet with one commit's detail, its files and the actions on it.
final class GitLogPage: UIViewController, GitPage {
    private let session: GitSession
    weak var host: GitPageHost?

    private let table = UITableView(frame: .zero, style: .plain)
    private let searchField = GitLogSearchField()
    private var search = ""
    private var layout = GitGraphLayout.empty
    private var loadingMore = false

    private enum Item {
        case header(Int)
        case commit(GitCommit, Int)
        case footer
        case empty(String)
    }

    private var items: [Item] = []

    init(session: GitSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        searchField.field.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.search = self.searchField.field.text ?? ""
            self.applySession()
        }, for: .editingChanged)

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 72
        table.showsVerticalScrollIndicator = false
        table.keyboardDismissMode = .onDrag
        table.register(GitLogCommitCell.self, forCellReuseIdentifier: "commit")
        table.register(GitLogFooterCell.self, forCellReuseIdentifier: "footer")
        table.register(GitLogHeaderCell.self, forCellReuseIdentifier: "header")
        table.register(GitLogEmptyCell.self, forCellReuseIdentifier: "empty")

        let header = UIView()
        header.addSubview(searchField)
        searchField.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.bottom.equalToSuperview().inset(4)
            make.height.equalTo(48)
        }
        header.snp.makeConstraints { make in make.height.equalTo(56) }
        view.addSubview(header)
        view.addSubview(table)
        header.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }
        table.snp.makeConstraints { make in
            make.top.equalTo(header.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
        applyBottomInset()
        applySession()
    }

    func applyBottomInset() {
        table.contentInset.bottom = 70 + view.safeAreaInsets.bottom
        table.verticalScrollIndicatorInsets.bottom = 70 + view.safeAreaInsets.bottom
    }

    func pageDidAppear() {}

    // MARK: - Building

    private var shownCommits: [GitCommit] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return session.commits }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return session.commits.filter {
            $0.summary.lowercased().contains(query)
                || $0.authorName.lowercased().contains(query)
                || $0.shortID.lowercased().contains(query)
        }
    }

    func applySession() {
        layout = search.isEmpty ? GitGraphLayout(commits: session.commits) : .empty
        let commits = shownCommits
        var items: [Item] = [.header(commits.count)]
        if commits.isEmpty {
            items.append(.empty(String(localized: "No commits yet")))
        } else {
            for (index, commit) in commits.enumerated() {
                items.append(.commit(commit, index))
            }
            if search.isEmpty {
                items.append(.footer)
            }
        }
        self.items = items
        table.reloadData()
    }

    // MARK: - Detail

    private func open(_ commit: GitCommit) {
        host?.gitSetBusy(true)
        Task { @MainActor in
            do {
                let detail = try await session.commitDetail(commit.id)
                host?.gitSetBusy(false)
                presentDetail(commit: commit, detail: detail)
            } catch {
                host?.gitSetBusy(false)
                host?.gitShowToast(error.readableMessage)
            }
        }
    }

    private func presentDetail(commit: GitCommit, detail: GitCommitDetail) {
        let content = GitCommitDetailContent(
            commit: commit,
            detail: detail,
            onCopyShort: { [weak self] in self?.copy(commit.shortID) },
            onCopyFull: { [weak self] in self?.copy(commit.id) },
            onCreateBranch: { [weak self] in
                guard let self else { return }
                let field = GitTextField(label: String(localized: "Branch name"))
                self.presentGitDialog(
                    title: String(localized: "Create Branch from Commit"),
                    content: field,
                    actions: [
                        .init(title: String(localized: "Cancel")) {},
                        .init(title: String(localized: "Create branch")) { [weak self] in
                            guard let self else { return }
                            let name = field.text.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            self.host?.gitSetBusy(true)
                            Task { @MainActor in
                                do {
                                    try await self.session.createBranch(
                                        name: name, startPoint: commit.id, checkout: false,
                                    )
                                } catch {
                                    self.host?.gitShowToast(error.readableMessage)
                                }
                                self.host?.gitSetBusy(false)
                            }
                        },
                    ],
                )
            },
            onCreateTag: { [weak self] in
                guard let self else { return }
                let field = GitTextField(label: String(localized: "Tag name"))
                self.presentGitDialog(
                    title: String(localized: "Create Tag at Commit"),
                    content: field,
                    actions: [
                        .init(title: String(localized: "Cancel")) {},
                        .init(title: String(localized: "Create tag")) { [weak self] in
                            guard let self else { return }
                            let name = field.text.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            self.host?.gitSetBusy(true)
                            Task { @MainActor in
                                do {
                                    try await self.session.createTag(
                                        name: name, commit: commit.id, message: nil,
                                    )
                                } catch {
                                    self.host?.gitShowToast(error.readableMessage)
                                }
                                self.host?.gitSetBusy(false)
                            }
                        },
                    ],
                )
            },
            onReset: { [weak self] in
                self?.confirmReset(commit)
            },
            onFile: { [weak self] path in
                // Pushed into the sheet's own navigation stack: the diff is
                // the next page of the sheet the file was tapped in, so no
                // second sheet is presented and nothing can cover it.
                guard let self, let navigation = self.presentedViewController as? UINavigationController else {
                    return
                }
                let page = GitDiffPage(
                    session: self.session, source: .commit(commit.id), path: path,
                )
                page.host = self.host
                if let sheet = navigation.sheetPresentationController {
                    sheet.animateChanges {
                        sheet.detents = [.large()]
                    }
                }
                navigation.pushViewController(page, animated: true)
            },
        )
        let detail = GitCommitDetailController(content: content, title: commit.shortID)
        let navigation = UINavigationController(rootViewController: detail)
        detail.navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) },
        ).then { $0.accessibilityLabel = String(localized: "Close") }
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        present(navigation, animated: true)
    }

    private func copy(_ text: String) {
        // The button says it copied, in place, so nothing is put over the page.
        UIPasteboard.general.string = text
    }

    private func confirmReset(_ commit: GitCommit) {
        let choice = GitResetChoice()
        presentGitDialog(
            title: String(localized: "Reset to this Commit"),
            message: String(localized: "Reset current branch to commit \(commit.shortID)?"),
            content: choice,
            actions: [
                .init(title: String(localized: "Cancel")) {},
                .init(title: String(localized: "Reset to this Commit"), destructive: true) { [weak self] in
                    guard let self else { return }
                    self.host?.gitSetBusy(true)
                    Task { @MainActor in
                        do {
                            try await self.session.reset(to: commit.id, mode: choice.mode)
                        } catch {
                            self.host?.gitShowToast(error.readableMessage)
                        }
                        self.host?.gitSetBusy(false)
                    }
                },
            ],
        )
    }

    private func loadMore() {
        guard search.isEmpty, session.hasMoreCommits, !loadingMore else { return }
        loadingMore = true
        table.reloadData()
        Task { @MainActor in
            _ = await session.loadMoreCommits()
            loadingMore = false
            applySession()
        }
    }
}

// MARK: - Table

extension GitLogPage: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch items[indexPath.row] {
        case let .header(count):
            let cell = tableView.dequeueReusableCell(withIdentifier: "header", for: indexPath) as! GitLogHeaderCell
            cell.configure(count: count)
            return cell
        case let .commit(commit, index):
            let cell = tableView.dequeueReusableCell(withIdentifier: "commit", for: indexPath) as! GitLogCommitCell
            let searching = !search.isEmpty
            cell.configure(
                commit: commit,
                layout: layout,
                index: index,
                showsGraph: !searching,
                laneWidth: GitGraphView.laneWidth(for: layout.maxLane),
            )
            return cell
        case .footer:
            let cell = tableView.dequeueReusableCell(withIdentifier: "footer", for: indexPath) as! GitLogFooterCell
            cell.configure(hasMore: session.hasMoreCommits, loading: loadingMore)
            return cell
        case let .empty(text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "empty", for: indexPath) as! GitLogEmptyCell
            cell.configure(text: text)
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        table.deselectRow(at: indexPath, animated: false)
        switch items[indexPath.row] {
        case let .commit(commit, _):
            open(commit)
        case .footer:
            loadMore()
        default:
            break
        }
    }

    func tableView(_ tableView: UITableView, willDisplay _: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row < items.count, case .footer = items[indexPath.row] else { return }
        if session.hasMoreCommits, !loadingMore {
            loadMore()
        }
    }
}

// MARK: - Search

private final class GitLogSearchField: UIView {
    let field = UITextField()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = GitTheme.cardSurface
        layer.cornerRadius = GitTheme.Radius.mdLarge
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = GitTheme.outline.cgColor
        let icon = UIImageView(image: GitIcon.image(GitIcon.Name.search, pointSize: 16))
        icon.tintColor = GitTheme.onSurfaceVariant
        icon.contentMode = .scaleAspectFit
        field.font = GitTheme.bodyMedium
        field.textColor = GitTheme.onSurface
        field.tintColor = GitTheme.primary
        field.placeholder = String(localized: "Search commit message or author…")
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = String(localized: "Search commit message or author…")
        addSubview(icon)
        addSubview(field)
        icon.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }
        field.snp.makeConstraints { make in
            make.leading.equalTo(icon.snp.trailing).offset(8)
            make.trailing.equalToSuperview().offset(-12)
            make.top.bottom.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Cells

private final class GitLogHeaderCell: UITableViewCell {
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        label.font = GitTheme.font(13, .regular)
        label.textColor = GitTheme.subtleText
        contentView.addSubview(label)
        label.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalToSuperview().offset(16)
            make.bottom.equalToSuperview().offset(-8)
        }
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(count: Int) {
        label.text = String(localized: "Commits (\(count))")
        accessibilityLabel = label.text
    }
}

private final class GitLogCommitCell: UITableViewCell {
    private let card = UIView()
    private let graph = GitGraphView()
    private var graphWidth: Constraint?
    private let refs = UIStackView()
    private let chevron = UIImageView(image: GitIcon.image(
        GitIcon.Name.chevronRight, pointSize: 16,
    )).then {
        $0.tintColor = GitTheme.onSurfaceVariant
        $0.contentMode = .scaleAspectFit
    }
    private let message = UILabel().then {
        $0.font = GitTheme.font(14, .semibold)
        $0.textColor = GitTheme.onSurface
        $0.numberOfLines = 2
    }
    private let hashLabel = UILabel().then {
        $0.font = GitTheme.mono(11)
        $0.textAlignment = .center
        $0.clipsToBounds = true
        $0.layer.cornerRadius = 8
        $0.layer.cornerCurve = .continuous
        // The tinted background wraps the hash, never the rest of the row.
        $0.setContentHuggingPriority(.required, for: .horizontal)
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    private let author = UILabel().then {
        $0.font = GitTheme.labelSmall
        $0.textColor = GitTheme.onSurfaceVariant
        $0.numberOfLines = 1
    }
    private let date = UILabel().then {
        $0.font = GitTheme.labelSmall
        $0.textColor = GitTheme.onSurfaceVariant
        $0.numberOfLines = 1
    }
    private let separator = UIView()
    private var separatorLeading: Constraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(card)
        card.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.bottom.equalToSuperview()
        }
        card.addSubview(graph)
        graph.snp.makeConstraints { make in
            graphWidth = make.width.equalTo(60).constraint
            make.leading.top.bottom.equalToSuperview()
        }
        card.addSubview(chevron)
        let text = UIStackView(arrangedSubviews: [message, hashAuthorRow()]).then {
            $0.axis = .vertical
            $0.spacing = 2
        }
        let column = UIStackView(arrangedSubviews: [refs, text]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.xs
        }
        refs.axis = .horizontal
        refs.spacing = GitTheme.Space.xs
        let wrapper = UIView()
        wrapper.addSubview(column)
        wrapper.addSubview(chevron)
        card.addSubview(wrapper)
        chevron.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.top.equalToSuperview().offset(2)
            make.size.equalTo(16)
        }
        column.snp.makeConstraints { make in
            make.leading.equalTo(chevron.snp.trailing).offset(GitTheme.Space.xs)
            make.top.equalToSuperview().offset(GitTheme.Space.sm)
            make.bottom.equalToSuperview().offset(-GitTheme.Space.sm)
            make.trailing.equalToSuperview()
        }
        wrapper.snp.makeConstraints { make in
            make.leading.equalTo(graph.snp.trailing)
            make.trailing.equalToSuperview().offset(-GitTheme.Space.lg)
            make.top.bottom.equalToSuperview()
        }
        card.addSubview(separator)
        separator.backgroundColor = GitTheme.subtleBorder
        separator.snp.makeConstraints { make in
            separatorLeading = make.leading.equalToSuperview().offset(60).constraint
            make.trailing.equalToSuperview()
            make.bottom.equalToSuperview()
            make.height.equalTo(1 / UIScreen.main.scale)
        }
        hashLabel.snp.makeConstraints { make in make.height.equalTo(18) }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func hashAuthorRow() -> UIView {
        let row = UIStackView(arrangedSubviews: [hashLabel, author, date]).then {
            $0.axis = .horizontal
            $0.spacing = GitTheme.Space.sm
            $0.alignment = .center
        }
        author.setContentHuggingPriority(.defaultLow, for: .horizontal)
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    func configure(
        commit: GitCommit,
        layout: GitGraphLayout,
        index: Int,
        showsGraph: Bool,
        laneWidth: CGFloat,
    ) {
        graph.isHidden = !showsGraph
        graphWidth?.update(offset: showsGraph
            ? GitGraphView.canvasWidth(maxLane: layout.maxLane, laneWidth: laneWidth)
            : 0)
        separatorLeading?.update(offset: showsGraph
            ? GitGraphView.canvasWidth(maxLane: layout.maxLane, laneWidth: laneWidth) + GitTheme.Space.md
            : GitTheme.Space.lg)
        if showsGraph {
            graph.configure(layout: layout, index: index, laneWidth: laneWidth)
        }
        let lane = showsGraph ? (layout.rows.indices.contains(index) ? layout.rows[index].lane : 0) : 0
        let color = GitTheme.laneColor(lane)
        refs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for ref in commit.refs.prefix(4) {
            refs.addArrangedSubview(GitRefPill(ref: ref))
        }
        // Empty space after the pills, so the row's remaining width is not
        // given to the last pill.
        if !commit.refs.isEmpty {
            let spacer = UIView()
            spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
            refs.addArrangedSubview(spacer)
        }
        refs.isHidden = commit.refs.isEmpty
        message.text = commit.summary
        hashLabel.text = "  \(commit.shortID)  "
        hashLabel.backgroundColor = color.withAlphaComponent(0.15)
        hashLabel.textColor = color
        author.text = commit.authorName
        date.text = Self.dateText(commit.authoredAt)
        accessibilityLabel = [
            commit.summary,
            commit.shortID,
            commit.authorName,
            date.text,
            commit.refs.map(\.name).joined(separator: ", "),
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        card.backgroundColor = GitTheme.cardSurface
    }

    private static func dateText(_ seconds: Double) -> String {
        let value = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = Calendar.current.isDateInToday(value) ? "HH:mm" : "MM-dd"
        return formatter.string(from: value)
    }
}

private final class GitRefPill: UIStackView {
    init(ref: GitRef) {
        super.init(frame: .zero)
        let isCurrent = ref.kind == .head
        let background = isCurrent
            ? GitTheme.primary
            : ref.kind == .tag ? GitTheme.tertiaryContainer : GitTheme.secondaryContainer
        let foreground = isCurrent
            ? GitTheme.onPrimary
            : ref.kind == .tag ? GitTheme.onTertiaryContainer : GitTheme.onSecondaryContainer
        backgroundColor = background
        layer.cornerRadius = GitTheme.Radius.xs
        layer.cornerCurve = .continuous
        // The pill is only as wide as what it says: its size comes from the
        // glyph and the word, and its margins, never from the row it is in.
        axis = .horizontal
        spacing = 2
        alignment = .center
        isLayoutMarginsRelativeArrangement = true
        layoutMargins = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        let icon = UIImageView(image: GitIcon.image(
            ref.kind == .remote ? GitIcon.Name.cloud
                : ref.kind == .tag ? GitIcon.Name.tag : GitIcon.Name.branch,
            pointSize: 11,
        ))
        icon.tintColor = foreground
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel().then {
            $0.text = ref.name
            $0.font = GitTheme.labelSmall
            $0.textColor = foreground
            $0.numberOfLines = 1
            $0.lineBreakMode = .byTruncatingMiddle
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        addArrangedSubview(icon)
        addArrangedSubview(label)
        icon.snp.makeConstraints { make in make.size.equalTo(11) }
        setContentHuggingPriority(.required, for: .horizontal)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class GitLogFooterCell: UITableViewCell {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        label.font = GitTheme.labelSmall
        label.textColor = GitTheme.onSurfaceVariant
        label.textAlignment = .center
        contentView.addSubview(label)
        spinner.hidesWhenStopped = true
        contentView.addSubview(spinner)
        label.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.bottom.equalToSuperview().inset(16)
        }
        spinner.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview()
        }
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(hasMore: Bool, loading: Bool) {
        label.text = hasMore
            ? String(localized: "Pull up to load more commits")
            : String(localized: "No more commits")
        label.isHidden = loading
        if loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        accessibilityLabel = label.text
        accessibilityTraits = hasMore ? .button : .staticText
    }
}

private final class GitLogEmptyCell: UITableViewCell {
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        label.font = GitTheme.bodyMedium
        label.textColor = GitTheme.onSurfaceVariant
        label.textAlignment = .center
        contentView.addSubview(label)
        label.snp.makeConstraints { make in
            make.centerX.centerY.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.greaterThanOrEqualToSuperview().offset(80)
            make.bottom.lessThanOrEqualToSuperview().offset(-32)
        }
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String) {
        label.text = text
        accessibilityLabel = text
    }
}

// MARK: - Commit detail

private final class GitCommitDetailContent: UIView {
    init(
        commit: GitCommit,
        detail: GitCommitDetail,
        onCopyShort: @escaping () -> Void,
        onCopyFull: @escaping () -> Void,
        onCreateBranch: @escaping () -> Void,
        onCreateTag: @escaping () -> Void,
        onReset: @escaping () -> Void,
        onFile: @escaping (String) -> Void,
    ) {
        super.init(frame: .zero)
        let message = UILabel().then {
            $0.text = commit.summary
            $0.font = GitTheme.titleMedium
            $0.textColor = GitTheme.onSurface
            $0.numberOfLines = 0
        }
        let body = detail.message
        let lines = body.components(separatedBy: "\n")
        let rest = lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyLabel = UILabel().then {
            $0.text = rest.isEmpty ? nil : rest
            $0.font = GitTheme.bodySmall
            $0.textColor = GitTheme.onSurfaceVariant
            $0.numberOfLines = 0
        }
        let author = UILabel().then {
            $0.text = "\(commit.authorName) · \(Self.dateText(commit.authoredAt))"
            $0.font = GitTheme.labelMedium
            $0.textColor = GitTheme.onSurfaceVariant
        }
        let hash = UILabel().then {
            $0.text = commit.id
            $0.font = GitTheme.mono(11)
            $0.textColor = GitTheme.onSurfaceVariant
            $0.numberOfLines = 1
            $0.lineBreakMode = .byTruncatingMiddle
            // The two copy buttons stay whole; the hash gives way, folding
            // its middle when there is no room for all forty characters.
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        let shortCopy = GitButtons.copy(title: String(localized: "Copy short hash")) { onCopyShort() }
        let fullCopy = GitButtons.copy(title: String(localized: "Copy full hash")) { onCopyFull() }
        hash.snp.makeConstraints { make in
            make.width.lessThanOrEqualTo(150)
            make.width.greaterThanOrEqualTo(60)
        }
        for button in [shortCopy, fullCopy] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        let hashRow = UIStackView(arrangedSubviews: [hash]).then {
            $0.axis = .horizontal
            $0.spacing = 4
            $0.alignment = .center
        }
        hashRow.addArrangedSubview(shortCopy)
        hashRow.addArrangedSubview(fullCopy)

        let branchButton = GitButtons.tonal(
            title: String(localized: "Branches"), symbol: GitIcon.Name.branch, height: 36,
        )
        let tagButton = GitButtons.tonal(
            title: String(localized: "Tags"), symbol: GitIcon.Name.tag, height: 36,
        )
        let resetButton = GitButtons.tonal(
            title: String(localized: "Reset to this Commit"), symbol: GitIcon.Name.rotate, height: 36,
        )
        branchButton.addAction(UIAction { _ in onCreateBranch() }, for: .touchUpInside)
        tagButton.addAction(UIAction { _ in onCreateTag() }, for: .touchUpInside)
        resetButton.addAction(UIAction { _ in onReset() }, for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [branchButton, tagButton, resetButton]).then {
            $0.axis = .horizontal
            $0.spacing = GitTheme.Space.xs
            $0.distribution = .fillEqually
        }

        let stack = UIStackView(arrangedSubviews: [message]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.sm
        }
        if !rest.isEmpty { stack.addArrangedSubview(bodyLabel) }
        stack.addArrangedSubview(author)
        stack.addArrangedSubview(hashRow)
        stack.addArrangedSubview(actions)
        let merging = commit.parents.count > 1
        if merging {
            let merge = UILabel().then {
                $0.text = String(localized: "Merge commit")
                $0.font = GitTheme.labelSmall
                $0.textColor = GitTheme.tertiary
            }
            stack.addArrangedSubview(merge)
        }
        if detail.files.isEmpty {
            let empty = UILabel().then {
                $0.text = String(localized: "No files changed in this commit")
                $0.font = GitTheme.labelSmall
                $0.textColor = GitTheme.onSurfaceVariant
            }
            stack.addArrangedSubview(empty)
        } else {
            let summary = UILabel().then {
                $0.text = String(localized: "\(detail.files.count) files changed")
                $0.font = GitTheme.labelSmall
                $0.textColor = GitTheme.onSurfaceVariant
            }
            stack.addArrangedSubview(summary)
            // One block of rows: no gap between them, so the list is tapped
            // as a list and not as a set of lines with dead space around.
            var fileRows: [UIView] = []
            for file in detail.files {
                let row = makeFileRow(file, onTap: { onFile(file.path) })
                fileRows.append(row)
                stack.addArrangedSubview(row)
            }
            for row in fileRows.dropLast() {
                stack.setCustomSpacing(0, after: row)
            }
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.width.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeFileRow(_ file: GitFileChange, onTap: @escaping () -> Void) -> UIView {
        let control = UIControl()
        let chip = GitStatusChip(code: file.status)
        let name = UILabel().then {
            $0.text = (file.path as NSString).lastPathComponent
            $0.font = GitTheme.mono(12)
            $0.textColor = GitTheme.onSurface
            $0.numberOfLines = 1
            $0.lineBreakMode = .byTruncatingMiddle
        }
        let directory = UILabel().then {
            let dir = (file.path as NSString).deletingLastPathComponent
            $0.text = dir.isEmpty ? nil : dir
            $0.font = GitTheme.mono(11)
            $0.textColor = GitTheme.onSurfaceVariant
        }
        let text = UIStackView(arrangedSubviews: [name, directory]).then {
            $0.axis = .vertical
            $0.spacing = 0
        }
        // Neither the chip nor the two lines of text are targets of their
        // own: a stack view is interactive by default and would swallow the
        // touch, so both are turned off and the row takes the tap.
        chip.isUserInteractionEnabled = false
        text.isUserInteractionEnabled = false
        control.addSubview(chip)
        control.addSubview(text)
        chip.snp.makeConstraints { make in
            make.leading.centerY.equalToSuperview()
            make.size.equalTo(CGSize(width: 32, height: 20))
        }
        text.snp.makeConstraints { make in
            make.leading.equalTo(chip.snp.trailing).offset(GitTheme.Space.md)
            make.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
        }
        // The row is one target of a fixed height: the whole line the reader
        // sees — the chip, the name, the folder, the space after them — is
        // the button, so a tap anywhere on it opens the file.
        control.snp.makeConstraints { make in make.height.equalTo(48) }
        control.addAction(UIAction { _ in onTap() }, for: .touchUpInside)
        control.isAccessibilityElement = true
        control.accessibilityLabel = file.path
        control.accessibilityTraits = .button
        return control
    }

    private static func dateText(_ seconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}

/// The commit's page inside its sheet: the message and the changed files,
/// scrollable, with the sheet's bar above it. A file opened here is pushed
/// on the same navigation stack.
private final class GitCommitDetailController: UIViewController {
    private let content: UIView

    init(content: UIView, title: String) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        self.title = title
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        let wrapper = UIView()
        wrapper.addSubview(content)
        content.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(GitTheme.Space.lg)
        }
        scroll.addSubview(wrapper)
        view.addSubview(scroll)
        wrapper.snp.makeConstraints { make in
            make.edges.equalTo(scroll.contentLayoutGuide)
            make.width.equalTo(scroll.frameLayoutGuide)
        }
        scroll.snp.makeConstraints { make in make.edges.equalTo(view.safeAreaLayoutGuide) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        // Coming back from a diff: the sheet returns to the size the commit's
        // page is read at.
        if let sheet = navigationController?.sheetPresentationController, sheet.detents.count == 1 {
            sheet.animateChanges { sheet.detents = [.medium(), .large()] }
        }
    }
}

/// The reset dialog's two choices, radio style, as the reference app's.
private final class GitResetChoice: UIView {
    private(set) var mode: GitResetMode = .mixed
    private let soft = GitResetChoiceRow(title: String(localized: "Soft (Keep working tree and staged)"))
    private let mixed = GitResetChoiceRow(title: String(localized: "Mixed (Keep working tree, unstage)"))

    init() {
        super.init(frame: .zero)
        soft.addAction(UIAction { [weak self] _ in
            self?.mode = .soft
            self?.soft.isChosen = true
            self?.mixed.isChosen = false
        }, for: .touchUpInside)
        mixed.addAction(UIAction { [weak self] _ in
            self?.mode = .mixed
            self?.soft.isChosen = false
            self?.mixed.isChosen = true
        }, for: .touchUpInside)
        mixed.isChosen = true
        let stack = UIStackView(arrangedSubviews: [soft, mixed]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.sm
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in make.edges.equalToSuperview() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class GitResetChoiceRow: UIControl {
    private let circle = UIImageView()
    private let label = UILabel()
    var isChosen = false {
        didSet { update() }
    }

    init(title: String) {
        super.init(frame: .zero)
        circle.contentMode = .scaleAspectFit
        circle.tintColor = GitTheme.primary
        label.text = title
        label.font = GitTheme.bodySmall
        label.textColor = GitTheme.onSurface
        label.numberOfLines = 2
        addSubview(circle)
        addSubview(label)
        circle.snp.makeConstraints { make in
            make.leading.centerY.equalToSuperview()
            make.size.equalTo(20)
        }
        label.snp.makeConstraints { make in
            make.leading.equalTo(circle.snp.trailing).offset(8)
            make.trailing.equalToSuperview()
            make.top.bottom.equalToSuperview().inset(6)
        }
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func update() {
        circle.image = UIImage(
            systemName: isChosen ? "largecircle.fill.circle" : "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18),
        )
        accessibilityTraits = isChosen ? [.button, .selected] : .button
    }
}

/// The reset modes, spelled here so the page does not import the wire's
/// types for one enum.

