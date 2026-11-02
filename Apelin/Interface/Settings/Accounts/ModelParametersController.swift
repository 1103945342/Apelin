import ApelinProtocol
import UIKit

/// One provider's models, each with the figures the app reads it against:
/// what its own record says unless the user set something here.
final class ModelParametersController: TableController {
    private let account: AgentAccount
    private var models: [String]

    init(account: AgentAccount) {
        self.account = account
        let enabled = EnabledModels.ids(for: account.provider)
        let known = account.models ?? []
        models = Set(known)
            .union(enabled)
            .union(EnabledModels.customIDs(for: account.provider))
            .subtracting(EnabledModels.hiddenIDs(for: account.provider))
            .sorted()
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(account:)")
    }

    private lazy var dataSource = TableDataSource<Int, String, String>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] table, indexPath, model in
        let cell = table.dequeueReusableCell(withIdentifier: "model") ?? UITableViewCell(style: .value1, reuseIdentifier: "model")
        var content = cell.defaultContentConfiguration()
        content.text = model
        content.textProperties.numberOfLines = 0
        let values = ModelParameters.values(for: self?.account.provider, model: model)
        content.secondaryText = values.contextWindow.map { String(localized: "\($0.formatted()) tokens") }
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityValue = values.contextWindow.map { String(localized: "\($0.formatted()) tokens") }
        return cell
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model Parameters")
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        dataSource.headerTitle = { [weak self] _ in
            self.map { $0.account.account ?? $0.account.provider.displayName }
        }
        dataSource.footerTitle = { _ in
            String(localized: "A figure set here is the one your conversations read this model against, in place of what the provider reports.")
        }
        dataSource.update([(0, models)])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let model = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(
            ModelParameterFormController(
                model: model,
                provider: account.provider,
                onSave: { [weak self] in self?.dataSource.update([(0, self?.models ?? [])], reconfigure: true) },
            ),
            animated: true,
        )
    }
}

/// The two figures for one model: the window a conversation is measured
/// against and the most a reply may be.
final class ModelParameterFormController: TableController {
    private let model: String
    private let provider: AgentProvider
    private let onSave: () -> Void
    private var window = UITextField()
    private var output = UITextField()

    private enum Section: Hashable { case window, output }
    private enum Row: Hashable { case field }

    init(model: String, provider: AgentProvider, onSave: @escaping () -> Void) {
        self.model = model
        self.provider = provider
        self.onSave = onSave
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(model:provider:onSave:)")
    }

    private lazy var dataSource = TableDataSource<Section, Row, Section>(
        tableView: tableView,
        identifier: { _ in .field },
    ) { [weak self] table, _, section in
        guard let self else { return nil }
        let cell = table.dequeueReusableCell(withIdentifier: "field") ?? UITableViewCell(style: .default, reuseIdentifier: "field")
        var content = cell.defaultContentConfiguration()
        switch section {
        case .window: content.text = String(localized: "Context Window")
        case .output: content.text = String(localized: "Max Output Tokens")
        }
        cell.contentConfiguration = content
        let field = section == .window ? window : output
        field.accessibilityLabel = content.text
        field.frame = CGRect(x: 0, y: 0, width: 120, height: 30)
        cell.accessoryView = field
        return cell
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = model
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        for field in [window, output] {
            let size = UIFont.preferredFont(forTextStyle: .body).pointSize
            field.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
            field.adjustsFontForContentSizeCategory = true
            field.keyboardType = .numberPad
            field.textAlignment = .right
            field.placeholder = String(localized: "Model's Own")
            field.accessibilityValue = field.placeholder
        }
        let values = ModelParameters.values(for: provider, model: model)
        window.text = values.contextWindow.map { "\($0)" }
        output.text = values.maxTokens.map { "\($0)" }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.save() },
        )
        dataSource.footerTitle = { section in
            switch section {
            case .window:
                String(localized: "Tokens a conversation may take before your agent compacts it. Leave it empty to use what the model reports.")
            case .output:
                String(localized: "The most a reply may be. Leave it empty to use what the model reports.")
            }
        }
        dataSource.update([(.window, [.field]), (.output, [.field])])
    }

    private func save() {
        guard let contextWindow = figure(window.text), let maxTokens = figure(output.text) else {
            presentNotice(
                title: "Invalid Value",
                message: "Enter a whole number of tokens, or leave the field empty.",
            )
            return
        }
        ModelParameters.save(
            ModelParameters.Values(contextWindow: contextWindow, maxTokens: maxTokens),
            for: provider,
            model: model,
        )
        onSave()
        navigationController?.popViewController(animated: true)
    }

    /// A field's figure: nil for an empty one, and `Int.min` for text that is
    /// not a whole positive number, which `save` refuses.
    private func figure(_ text: String?) -> Int?? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .some(nil) }
        guard let value = Int(trimmed), value > 0 else { return nil }
        return .some(value)
    }
}
