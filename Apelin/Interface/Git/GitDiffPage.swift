import SnapKit
import Then
import UIKit

/// The diff page: two gutters, a marker, and every line of both versions of
/// one file, added and removed lines tinted. Not a patch, and not a sheet —
/// it is pushed over the Git screen with its own bar.
final class GitDiffPage: UIViewController {
    enum Source {
        case worktree(staged: Bool)
        case commit(String)
    }

    private let session: GitSession
    private let source: Source
    private let path: String
    weak var host: GitPageHost?

    private let topBar = UIView()
    private let titleLabel = UILabel()
    private let pathLabel = UILabel()
    /// The diff's options: a gear whose menu holds the wrap switch, kept for
    /// the next file. A menu is the platform's own, glass on iOS 26.
    private let optionsButton = UIButton(type: .system)
    private var wraps = Preferences.diffWraps {
        didSet { applyWrap() }
    }
    private let statsBar = UIView()
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private let hScroll = UIScrollView()
    private let table = UITableView(frame: .zero, style: .plain)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let message = UILabel()
    private let messageIcon = UIImageView()
    private let retryButton = UIButton(type: .system)

    private var rows: [LineDiff.Row] = []
    private var gutterWidth: CGFloat = 40
    private var contentWidth: CGFloat = 0

    init(session: GitSession, source: Source, path: String) {
        self.session = session
        self.source = source
        self.path = path
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = GitTheme.pageBackground
        navigationController?.setNavigationBarHidden(true, animated: false)
        buildTopBar()
        buildBody()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    // MARK: - Building

    private func buildTopBar() {
        topBar.backgroundColor = GitTheme.cardSurface
        view.addSubview(topBar)
        topBar.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalTo(view)
            make.height.equalTo(56)
        }
        let back = UIButton(type: .system)
        back.setImage(GitIcon.image(GitIcon.Name.back, pointSize: 18), for: .normal)
        back.tintColor = GitTheme.onSurface
        back.accessibilityLabel = String(localized: "Back")
        back.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Pushed inside a sheet it goes back to the page it came from —
            // which is still in a presented stack, so `presentingViewController`
            // alone would close the whole sheet.
            if let navigation = self.navigationController, navigation.viewControllers.count > 1 {
                navigation.popViewController(animated: true)
            } else {
                self.dismiss(animated: true)
            }
        }, for: .touchUpInside)
        topBar.addSubview(back)

        titleLabel.text = (path as NSString).lastPathComponent
        titleLabel.font = GitTheme.titleSmall
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = GitTheme.onSurface
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.text = path
        pathLabel.font = GitTheme.mono(11)
        pathLabel.adjustsFontForContentSizeCategory = true
        pathLabel.textColor = GitTheme.onSurfaceVariant
        pathLabel.numberOfLines = 1
        pathLabel.lineBreakMode = .byTruncatingMiddle
        let titles = UIStackView(arrangedSubviews: [titleLabel, pathLabel]).then {
            $0.axis = .vertical
            $0.spacing = 0
        }
        topBar.addSubview(titles)

        optionsButton.tintColor = GitTheme.onSurface
        optionsButton.setImage(GitIcon.image(GitIcon.Name.gear, pointSize: 18), for: .normal)
        optionsButton.accessibilityLabel = String(localized: "Diff Options")
        optionsButton.showsMenuAsPrimaryAction = true
        topBar.addSubview(optionsButton)
        updateOptionsMenu()

        back.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(4)
            make.centerY.equalToSuperview()
            make.size.equalTo(44)
        }
        optionsButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-4)
            make.centerY.equalToSuperview()
            make.size.equalTo(44)
        }
        titles.snp.makeConstraints { make in
            make.leading.equalTo(back.snp.trailing).offset(4)
            make.trailing.equalTo(optionsButton.snp.leading).offset(-8)
            make.centerY.equalToSuperview()
        }
    }

    private func buildBody() {
        statsBar.backgroundColor = GitTheme.cardSurface
        view.addSubview(statsBar)
        statsBar.snp.makeConstraints { make in
            make.top.equalTo(topBar.snp.bottom)
            make.leading.trailing.equalTo(view)
            make.height.equalTo(36)
        }
        addedLabel.font = GitTheme.mono(12, .semibold)
        addedLabel.adjustsFontForContentSizeCategory = true
        addedLabel.textColor = GitTheme.diffAdd
        removedLabel.font = GitTheme.mono(12, .semibold)
        removedLabel.adjustsFontForContentSizeCategory = true
        removedLabel.textColor = GitTheme.diffRemove
        let stats = UIStackView(arrangedSubviews: [addedLabel, removedLabel]).then {
            $0.axis = .horizontal
            $0.spacing = GitTheme.Space.sm
        }
        statsBar.addSubview(stats)
        stats.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
        }

        hScroll.showsHorizontalScrollIndicator = true
        hScroll.alwaysBounceVertical = false
        hScroll.contentInsetAdjustmentBehavior = .never
        // A diff is source code: its gutters, marker and text run left to
        // right whatever the page's direction, so the two sides of a changed
        // line stay on the sides their `+` and `-` name.
        hScroll.semanticContentAttribute = .forceLeftToRight
        table.semanticContentAttribute = .forceLeftToRight
        view.addSubview(hScroll)
        hScroll.snp.makeConstraints { make in
            make.top.equalTo(statsBar.snp.bottom)
            make.leading.trailing.equalTo(view)
            make.bottom.equalTo(view)
        }
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 20
        table.showsVerticalScrollIndicator = true
        table.register(GitDiffLineCell.self, forCellReuseIdentifier: "line")
        hScroll.addSubview(table)
        table.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.trailing.equalTo(hScroll.contentLayoutGuide)
            make.height.equalTo(hScroll.frameLayoutGuide)
        }

        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        spinner.snp.makeConstraints { make in
            make.center.equalTo(view.safeAreaLayoutGuide)
        }
        message.font = GitTheme.bodyMedium
        message.adjustsFontForContentSizeCategory = true
        message.textColor = GitTheme.onSurfaceVariant
        message.textAlignment = .center
        message.numberOfLines = 0
        message.isHidden = true
        messageIcon.tintColor = GitTheme.onSurfaceVariant
        messageIcon.contentMode = .scaleAspectFit
        messageIcon.isHidden = true
        // A file that did not load is worth another try: the repository may
        // have been busy or the read may have lost a race with a checkout.
        retryButton.setTitle(String(localized: "Try Again"), for: .normal)
        retryButton.titleLabel?.font = GitTheme.bodyMedium
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.setTitleColor(GitTheme.primary, for: .normal)
        retryButton.isHidden = true
        retryButton.addAction(UIAction { [weak self] _ in
            self?.load()
        }, for: .touchUpInside)
        let centered = UIStackView(arrangedSubviews: [messageIcon, message, retryButton]).then {
            $0.axis = .vertical
            $0.spacing = GitTheme.Space.sm
            $0.alignment = .center
        }
        view.addSubview(centered)
        centered.snp.makeConstraints { make in
            make.center.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview().inset(24)
        }
        messageIcon.snp.makeConstraints { make in make.size.equalTo(32) }
        _ = centered
        self.emptyStack = centered
    }

    private var emptyStack: UIStackView?

    // MARK: - Loading

    private func load() {
        spinner.startAnimating()
        statsBar.isHidden = true
        emptyStack?.isHidden = true
        retryButton.isHidden = true
        Task { @MainActor in
            do {
                let versions: GitVersions
                switch source {
                case let .worktree(staged):
                    versions = try await session.fileVersions(path: path, staged: staged)
                case let .commit(commit):
                    versions = try await session.commitFileVersions(commit: commit, path: path)
                }
                spinner.stopAnimating()
                if versions.isBinary {
                    show(message: String(localized: "Binary file"), symbol: GitIcon.Name.file)
                    return
                }
                let diff = LineDiff.rows(old: versions.old, new: versions.new)
                rows = diff
                let added = diff.filter { $0.kind == .added }.count
                let removed = diff.filter { $0.kind == .removed }.count
                if diff.isEmpty || (added == 0 && removed == 0 && versions.old == versions.new) {
                    show(message: String(localized: "No changes"), symbol: nil)
                    return
                }
                addedLabel.text = "+\(added)"
                removedLabel.text = "-\(removed)"
                addedLabel.isAccessibilityElement = true
                addedLabel.accessibilityLabel = String(localized: "\(added) added lines")
                removedLabel.isAccessibilityElement = true
                removedLabel.accessibilityLabel = String(localized: "\(removed) removed lines")
                statsBar.isHidden = false
                if versions.truncated {
                    // The cut is the worker's, and said so rather than drawn
                    // as if the file ended there.
                    showFooterNote(String(localized: "The file was too long to compare in full."))
                }
                layoutDiff(diff)
            } catch {
                spinner.stopAnimating()
                show(message: error.readableMessage, symbol: GitIcon.Name.error, retry: true)
            }
        }
    }

    private func showFooterNote(_ text: String) {
        let note = UILabel().then {
            $0.text = text
            $0.font = GitTheme.labelSmall
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = GitTheme.onSurfaceVariant
            $0.textAlignment = .center
            $0.numberOfLines = 0
        }
        let wrapper = UIView()
        wrapper.addSubview(note)
        note.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(12)
        }
        table.tableFooterView = wrapper
    }

    private func layoutDiff(_ rows: [LineDiff.Row]) {
        hScroll.isHidden = false
        emptyStack?.isHidden = true
        let longest = rows.map { Self.width(of: $0.text) }.max() ?? 0
        let digits = max(3, String(rows.map { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0).count)
        gutterWidth = CGFloat(digits) * 7 + 12
        contentWidth = wraps
            ? view.bounds.width
            : gutterWidth * 2 + 1 + 14 + 16 + longest + 16
        table.reloadData()
        hScroll.contentSize = CGSize(
            width: max(contentWidth, view.bounds.width),
            height: view.bounds.height,
        )
        table.snp.remakeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.equalTo(hScroll.contentLayoutGuide)
            make.width.equalTo(max(contentWidth, view.bounds.width))
            make.height.equalTo(hScroll.frameLayoutGuide)
        }
        table.isScrollEnabled = true
        hScroll.isScrollEnabled = !wraps
        if wraps { hScroll.contentOffset = .zero }
    }

    /// The gear's menu: one switch, ticked while the diff wraps.
    private func updateOptionsMenu() {
        let wrap = UIAction(
            title: String(localized: "Wrap Lines"),
            image: GitIcon.image(GitIcon.Name.wrap, pointSize: 16),
            state: wraps ? .on : .off,
        ) { [weak self] _ in
            guard let self else { return }
            self.wraps.toggle()
            Preferences.diffWraps = self.wraps
            self.updateOptionsMenu()
        }
        optionsButton.menu = UIMenu(children: [wrap])
    }

    /// Reads the switch back into the table: wrapped, its lines are the
    /// page's width; unwrapped, the longest line decides how far it scrolls.
    private func applyWrap() {
        guard !rows.isEmpty else { return }
        table.reloadData()
        layoutDiff(rows)
    }

    private static func width(of text: String) -> CGFloat {
        let font = GitTheme.mono(12)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func show(message text: String, symbol: String?, retry: Bool = false) {
        hScroll.isHidden = true
        statsBar.isHidden = true
        message.text = text
        message.isHidden = false
        messageIcon.isHidden = symbol == nil
        if let symbol {
            messageIcon.image = GitIcon.image(symbol, pointSize: 32)
        }
        retryButton.isHidden = !retry
        emptyStack?.isHidden = false
    }
}

extension GitDiffPage: UITableViewDataSource {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "line", for: indexPath) as! GitDiffLineCell
        cell.configure(row: rows[indexPath.row], gutter: gutterWidth, width: contentWidth, wrapped: wraps)
        return cell
    }
}

private final class GitDiffLineCell: UITableViewCell {
    private let oldNumber = UILabel()
    private let newNumber = UILabel()
    private let divider = UIView()
    private let prefix = UILabel()
    private let text = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        for label in [oldNumber, newNumber] {
            label.font = GitTheme.mono(10)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = GitTheme.onSurfaceVariant.withAlphaComponent(0.6)
            label.textAlignment = .right
            label.backgroundColor = GitTheme.surfaceVariant.withAlphaComponent(0.5)
            label.clipsToBounds = true
        }
        divider.backgroundColor = GitTheme.outlineVariant.withAlphaComponent(0.5)
        prefix.font = GitTheme.mono(12, .bold)
        prefix.adjustsFontForContentSizeCategory = true
        text.font = GitTheme.mono(12)
        text.adjustsFontForContentSizeCategory = true
        text.numberOfLines = 1
        contentView.addSubview(oldNumber)
        contentView.addSubview(divider)
        contentView.addSubview(newNumber)
        contentView.addSubview(prefix)
        contentView.addSubview(text)
        oldNumber.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(40)
        }
        divider.snp.makeConstraints { make in
            make.leading.equalTo(oldNumber.snp.trailing)
            make.top.bottom.equalToSuperview()
            make.width.equalTo(1)
        }
        newNumber.snp.makeConstraints { make in
            make.leading.equalTo(divider.snp.trailing)
            make.top.bottom.equalToSuperview()
            make.width.equalTo(40)
        }
        prefix.snp.makeConstraints { make in
            make.leading.equalTo(newNumber.snp.trailing).offset(4)
            make.top.bottom.equalToSuperview()
            make.width.equalTo(14)
        }
        text.snp.makeConstraints { make in
            make.leading.equalTo(prefix.snp.trailing)
            make.top.bottom.equalToSuperview().inset(2)
            make.trailing.equalToSuperview().offset(-16)
        }
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(row: LineDiff.Row, gutter: CGFloat, width: CGFloat, wrapped: Bool) {
        oldNumber.text = row.oldNumber.map(String.init)
        newNumber.text = row.newNumber.map(String.init)
        oldNumber.snp.updateConstraints { make in make.width.equalTo(gutter) }
        newNumber.snp.updateConstraints { make in make.width.equalTo(gutter) }
        text.text = row.text
        text.numberOfLines = wrapped ? 0 : 1
        switch row.kind {
        case .added:
            prefix.text = "+"
            prefix.textColor = GitTheme.diffAdd
            contentView.backgroundColor = GitTheme.diffAdd.withAlphaComponent(0.15)
        case .removed:
            prefix.text = "-"
            prefix.textColor = GitTheme.diffRemove
            contentView.backgroundColor = GitTheme.diffRemove.withAlphaComponent(0.15)
        case .same:
            prefix.text = " "
            prefix.textColor = GitTheme.onSurfaceVariant
            contentView.backgroundColor = .clear
        }
        text.textColor = GitTheme.onSurface
        accessibilityLabel = [
            row.oldNumber.map { "\($0)" },
            row.newNumber.map { "\($0)" },
            row.kind == .added ? String(localized: "Added") : row.kind == .removed ? String(localized: "Deleted") : nil,
            row.text,
        ].compactMap { $0 }.joined(separator: " ")
    }
}
