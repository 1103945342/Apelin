import ApelinProtocol
import UIKit

/// The team of the conversation on the page, read-only: the conversations it
/// opened and what the host's assignment ledger says about each — its state,
/// what was verified, what it claims, which checks are missing, what blocks it
/// — with a row that opens the conversation itself for the original answer.
///
/// Nothing here writes: no accept, no amend, no stop, no approval. The ledger
/// comes from the host for this session (`agentDelegation`, `action: .read`),
/// never from the app's own list of children, and it is asked for again only
/// while the page is on screen.
@MainActor
final class TeamLedgerController: UIViewController {
    /// The conversation whose team this is: the opener, by its session ID.
    private let sessionID: String
    /// A member's conversation, opened by whoever shows this page: the root's
    /// own open, so the sidebar's highlight moves with the page.
    var onOpenChild: ((String) -> Void)?

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(type: .system)
    private var model: TeamLedgerModel?
    private var failure = false
    private var loading = false
    private var polling: Task<Void, Never>?

    /// How often a page that is on screen asks the host again. The ledger
    /// moves with the children's turns, and this page is read-only: polling
    /// while it is visible is cheaper than a subscription nothing else needs.
    private static let refreshInterval: Duration = .seconds(5)

    init(sessionID: String) {
        self.sessionID = sessionID
        super.init(nibName: nil, bundle: nil)
        navigationItem.title = String(localized: "Team")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Close"),
            style: .plain,
            target: self,
            action: #selector(close)
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(sessionID:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        table.dataSource = self
        table.delegate = self
        table.register(TeamMemberCell.self, forCellReuseIdentifier: TeamMemberCell.reuseIdentifier)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 90
        table.refreshControl = UIRefreshControl()
        table.refreshControl?.addTarget(self, action: #selector(refreshed), for: .valueChanged)
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)

        status.numberOfLines = 0
        status.textAlignment = .center
        status.textColor = .secondaryLabel
        status.adjustsFontForContentSizeCategory = true
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        retry.configuration = {
            var configuration = UIButton.Configuration.bordered()
            configuration.title = String(localized: "Retry")
            return configuration
        }()
        retry.addAction(UIAction { [weak self] _ in
            Task { await self?.load() }
        }, for: .primaryActionTriggered)
        retry.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(retry)

        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            retry.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retry.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 16)
        ])
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startPolling()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPolling()
    }

    // MARK: The host's ledger

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.load()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    @objc private dynamic func refreshed() {
        Task { await load() }
    }

    @objc private dynamic func close() {
        dismiss(animated: true)
    }

    /// One reading of the ledger. The page is read-only, so a failure only
    /// says so and keeps what it already showed.
    private func load() async {
        guard !loading, viewIfLoaded?.window != nil else { return }
        loading = true
        defer { loading = false }
        do {
            let answer = try await ApelinService.app.agentDelegation(
                AgentDelegationRequest(sessionID: sessionID, action: .read)
            )
            model = TeamLedgerModel(
                ledger: answer.ledger ?? AgentAssignmentLedger(),
                sessionID: sessionID
            )
            failure = false
        } catch {
            failure = model == nil
        }
        table.refreshControl?.endRefreshing()
        render()
    }

    // MARK: Drawing

    private func render() {
        let empty = model?.isEmpty ?? true
        status.text = loading && model == nil
            ? String(localized: "Loading")
            : failure
            ? String(localized: "Could Not Read the Team")
                + "\n\n" + String(localized: "The host could not read this conversation's assignment ledger.")
            : String(localized: "No Team Yet")
                + "\n\n" + String(localized: "This conversation has not delegated work to other conversations.")
        status.isHidden = !(empty || failure)
        retry.isHidden = !failure
        spinner.startAnimating()
        spinner.isHidden = model != nil || failure
        table.isHidden = empty || failure
        table.reloadData()
    }

    private static func title(_ state: AgentAssignment.State) -> String {
        switch state {
        case .working: String(localized: "Working")
        case .blocked: String(localized: "Blocked")
        case .readyForReview: String(localized: "Ready for Review")
        case .accepted: String(localized: "Accepted")
        case .cancelled: String(localized: "Cancelled")
        case .failed: String(localized: "Failed")
        }
    }

    private static func title(_ verification: AgentAssignment.Verification) -> String {
        switch verification {
        case .verified: String(localized: "Verified")
        case .unverified: String(localized: "Unverified")
        }
    }

    /// What one member's row says under its objective: what the ledger holds
    /// about it, in the order a reader checks it.
    private static func detail(_ member: TeamLedgerModel.Member) -> String {
        var lines = ["\(title(member.state)) · \(title(member.verification))"]
        if !member.claims.isEmpty {
            lines.append(String(localized: "Claims") + ": " + member.claims.joined(separator: "; "))
        }
        if !member.checks.isEmpty {
            let checks = member.checks.map { check in
                "\(check.criterion) — " + (check.passed ? String(localized: "Passed") : String(localized: "Failed"))
            }
            lines.append(String(localized: "Checks") + ": " + checks.joined(separator: "; "))
        }
        if !member.missingChecks.isEmpty {
            lines.append(String(localized: "Missing Checks") + ": " + member.missingChecks.joined(separator: "; "))
        }
        if !member.blockers.isEmpty {
            lines.append(String(localized: "Blockers") + ": " + member.blockers.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Table

extension TeamLedgerController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in _: UITableView) -> Int {
        model?.groups.count ?? 0
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        model?.groups[section].members.count ?? 0
    }

    func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let group = model?.groups[section] else { return nil }
        var title = String(localized: "Revision \(Int(group.revision)), \(group.members.count) members")
        if group.isSealed {
            title += ", " + String(localized: "Sealed")
        }
        return title
    }

    func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        String(localized: "A turn that finished is not an acceptance: only the host's check makes a step verified.")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let group = model?.groups[indexPath.section],
              group.members.indices.contains(indexPath.row),
              let cell = tableView.dequeueReusableCell(
                  withIdentifier: TeamMemberCell.reuseIdentifier,
                  for: indexPath
              ) as? TeamMemberCell
        else { return UITableViewCell() }
        let member = group.members[indexPath.row]
        cell.show(
            objective: member.objective,
            detail: Self.detail(member),
            opens: member.opens
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let group = model?.groups[indexPath.section],
              group.members.indices.contains(indexPath.row)
        else { return }
        let member = group.members[indexPath.row]
        guard member.opens else { return }
        onOpenChild?(member.childSessionID)
    }
}

/// One member: its objective, and under it what the ledger says. The row is
/// one accessibility element — a cell with subviews is not one by itself — so
/// its whole sentence is read at once, and the row's tap is what opens the
/// conversation, said in the hint.
private final class TeamMemberCell: UITableViewCell {
    static let reuseIdentifier = "TeamMemberCell"

    private let objective = UILabel()
    private let detail = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        isAccessibilityElement = true
        objective.numberOfLines = 0
        objective.font = .preferredFont(forTextStyle: .body)
        objective.adjustsFontForContentSizeCategory = true
        objective.textColor = .label
        detail.numberOfLines = 0
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [objective, detail])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:reuseIdentifier:)")
    }

    func show(objective text: String, detail: String, opens: Bool) {
        objective.text = text
        self.detail.text = detail
        accessibilityLabel = text
        accessibilityValue = detail
        accessibilityTraits = opens ? [.button] : []
        accessibilityHint = opens ? String(localized: "Open Conversation") : nil
        selectionStyle = opens ? .default : .none
        accessoryType = opens ? .disclosureIndicator : .none
    }
}
