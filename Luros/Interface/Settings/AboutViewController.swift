import SnapKit
import UIKit

/// Settings ▸ About: the icon, the slogan beneath it, and what names this
/// build — its version, the licences of what it carries, and its logs.
///
/// The header is the table's own: a centred `AppIconView` over one line of
/// the slogan in secondary text, sized to the table's width so a rotation or
/// a larger text size lays it out again.
final class AboutViewController: UITableViewController {
    private enum Row: Int, CaseIterable {
        /// This build's version and build number, read-only.
        case version
        case licenses
        case logs
    }

    /// Luros · A loom in your palm — the hand makes the thing.
    private static let slogan = String(localized: "Luros · A loom in your palm")

    private lazy var header: UIView = {
        let view = UIView()
        let icon = AppIconView()
        icon.isAccessibilityElement = false
        let line = UILabel()
        line.text = Self.slogan
        line.font = .preferredFont(forTextStyle: .subheadline)
        line.adjustsFontForContentSizeCategory = true
        line.textColor = .secondaryLabel
        line.textAlignment = .center
        line.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [icon, line])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        view.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().offset(24)
            make.bottom.equalToSuperview().offset(-24)
            make.leading.greaterThanOrEqualToSuperview().offset(24)
            make.trailing.lessThanOrEqualToSuperview().offset(-24)
        }
        return view
    }()

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "About")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "about")
        tableView.tableHeaderView = header
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHeader()
    }

    /// The header takes the table's width and the height its one stack needs;
    /// only a change of either rewrites it, so scrolling never fights it.
    private func layoutHeader() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let fitting = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        )
        guard abs(header.frame.width - width) > 0.5 || abs(header.frame.height - fitting.height) > 0.5 else {
            return
        }
        header.frame = CGRect(x: 0, y: 0, width: width, height: fitting.height)
        tableView.tableHeaderView = header
    }

    // MARK: - The table

    override func numberOfSections(in _: UITableView) -> Int {
        1
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "about", for: indexPath)
        guard let row = Row(rawValue: indexPath.row) else { return cell }
        var content = UIListContentConfiguration.valueCell()
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        switch row {
        case .version:
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            let build = info?["CFBundleVersion"] as? String ?? "?"
            content.text = String(localized: "Version")
            content.secondaryText = "\(version) (\(build))"
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case .licenses:
            content.text = String(localized: "Open Source Licenses")
        case .logs:
            content.text = String(localized: "Logs")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        Row(rawValue: indexPath.row) != .version
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row) {
        case .licenses: navigationController?.pushViewController(LicensesViewController(), animated: true)
        case .logs: navigationController?.pushViewController(LogsController(), animated: true)
        case .version, .none: break
        }
    }
}
