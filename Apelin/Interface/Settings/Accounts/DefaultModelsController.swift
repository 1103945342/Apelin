import ApelinProtocol
import UIKit

/// Settings ▸ Agent ▸ Default Models. Each auxiliary agent operation can use
/// its own enabled model without changing the model used for the conversation.
final class DefaultModelsController: TableController {
    private enum Section: Hashable { case models }

    private lazy var dataSource = TableDataSource<Section, Preferences.DefaultModelKind, Preferences.DefaultModelKind>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] table, _, kind in
        self?.cell(in: table, kind: kind)
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
        dataSource.headerTitle = { _ in String(localized: "Agent") }
        dataSource.footerTitle = { _ in
            String(localized: "These models are used for auxiliary tasks and do not change the model selected for a conversation.")
        }
        dataSource.update([(.models, Preferences.DefaultModelKind.allCases)])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadAccounts()
        updateRows()
    }

    private func updateRows() {
        dataSource.update([(.models, Preferences.DefaultModelKind.allCases)], reconfigure: true)
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

    private func cell(in tableView: UITableView, kind: Preferences.DefaultModelKind) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "default-model")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "default-model")
        var content = UIListContentConfiguration.valueCell()
        content.text = kind.title
        content.secondaryText = Preferences.DefaultModels.summary(for: kind)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let kind = dataSource.value(at: indexPath) else { return }
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
