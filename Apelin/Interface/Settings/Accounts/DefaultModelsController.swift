import ApelinProtocol
import UIKit

/// Settings ▸ Agent ▸ Default Models. Each auxiliary agent operation can use
/// its own enabled model without changing the model used for the conversation.
final class DefaultModelsController: TableController {
    private enum Section: Hashable { case models }

    /// What a row says right now, not just which operation it is about: the
    /// table redraws a row whose content differs, and a chosen model is the
    /// only thing that differs here.
    private struct Row: Equatable {
        let kind: Preferences.DefaultModelKind
        let detail: String
    }

    private lazy var dataSource = TableDataSource<Section, Preferences.DefaultModelKind, Row>(
        tableView: tableView,
        identifier: { $0.kind },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private var accounts: [AgentAccount] = []
    private var loader: Task<Void, Never>?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        loader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Default Models")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        dataSource.headerTitle = { _ in String(localized: "Agent") }
        dataSource.footerTitle = { _ in
            String(localized: "These models are used for auxiliary tasks and do not change the model selected for a conversation.")
        }
        dataSource.update([(.models, rows())])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadAccounts()
        updateRows()
    }

    private func rows() -> [Row] {
        Preferences.DefaultModelKind.allCases.map {
            Row(kind: $0, detail: Preferences.DefaultModels.summary(for: $0))
        }
    }

    private func updateRows() {
        dataSource.update([(.models, rows())], reconfigure: true)
    }

    private func loadAccounts() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                var accounts = try await EnabledModels.accounts(from: ApelinService.app.agentAccountList().accounts)
                for index in accounts.indices where accounts[index].models?.isEmpty != false {
                    do {
                        accounts[index].models = try await ApelinService.app
                            .agentModelList(provider: accounts[index].provider).models
                    } catch {
                        // Keep the account visible even if this provider's model catalog is unavailable.
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.accounts = accounts
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.accounts = []
            }
            self?.updateRows()
        }
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let reusable = tableView.dequeueReusableCell(withIdentifier: ModelValueCell.reuseIdentifier)
        let cell = (reusable as? ModelValueCell) ?? ModelValueCell()
        cell.configure(title: row.kind.title, value: row.detail)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let kind = dataSource.value(at: indexPath)?.kind else { return }
        choose(kind)
    }

    private func choose(_ kind: Preferences.DefaultModelKind) {
        guard !accounts.isEmpty else {
            presentPageAsFormSheet(ModelProvidersController())
            return
        }

        let current = Preferences.DefaultModels.selection(for: kind)
        var groups = [ComposerChoiceSheet.Group(
            title: nil,
            choices: [ComposerChoiceSheet.Choice(
                title: String(localized: "Use Conversation Model"),
                isSelected: current == nil,
            ) { [weak self] in
                Preferences.DefaultModels.remove(for: kind)
                self?.updateRows()
            }],
        )]
        groups.append(contentsOf: accounts.compactMap { account in
            let models = account.models ?? []
            guard !models.isEmpty else { return nil }
            return ComposerChoiceSheet.Group(
                title: account.account ?? account.provider.displayName,
                choices: models.map { model in
                    ComposerChoiceSheet.Choice(
                        title: model,
                        isSelected: current?.provider == account.provider && current?.model == model,
                        modelTest: AgentModelTestRequest(provider: account.provider, model: model),
                    ) { [weak self] in
                        Preferences.DefaultModels.save(
                            .init(provider: account.provider, model: model),
                            for: kind,
                        )
                        self?.updateRows()
                    }
                },
            )
        })
        ComposerChoiceSheet.present(
            ComposerChoiceSheet(heading: kind.title, groups: groups),
            from: self,
        )
    }
}

/// A setting whose value is a model's name: the operation at the leading end,
/// the model at the trailing one, one text size smaller. The system's own value
/// cell drops the value under the title when the two do not fit side by side,
/// which left the list with some rows right-aligned and others not; here the
/// value keeps the row's end whatever it is and a long name is cut in the
/// middle, where the provider and the version's last words both stay readable.
///
/// The row is one accessibility element: VoiceOver reads the operation and the
/// model in use as the one setting they are.
private final class ModelValueCell: UITableViewCell {
    static let reuseIdentifier = "default-model"

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()

    init() {
        super.init(style: .default, reuseIdentifier: Self.reuseIdentifier)
        accessoryType = .disclosureIndicator
        selectionStyle = .default

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        valueLabel.font = .preferredFont(forTextStyle: .footnote)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.numberOfLines = 1
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for label in [titleLabel, valueLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
        }
        let margin = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: margin.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: margin.topAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: margin.trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            valueLabel.topAnchor.constraint(greaterThanOrEqualTo: margin.topAnchor),
            valueLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: 8,
            ),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    func configure(title: String, value: String) {
        titleLabel.text = title
        valueLabel.text = value
        accessibilityLabel = title
        accessibilityValue = value
    }
}
