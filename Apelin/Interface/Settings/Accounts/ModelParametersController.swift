import ApelinProtocol
import UIKit

/// One provider's models, each with the figures the app reads it against:
/// what its catalog entry, or its own record, says unless the user set
/// something here.
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
    ) { [weak self] _, _, model in
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = model
        content.textProperties.numberOfLines = 0
        let values = self.map { ModelParameters.values(for: $0.account.provider, model: model) }
        let catalog = self?.account.capabilities?[model]
        // The figure a conversation is read against: the user's when set, and
        // the catalog entry's otherwise.
        let window = values?.contextWindow ?? catalog?.contextWindow
        content.secondaryText = window.map { String(localized: "\($0.formatted()) tokens") }
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityValue = window.map { String(localized: "\($0.formatted()) tokens") }
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
            String(localized: "A figure set here is the one your conversations read this model against, in place of what the catalog and the provider report.")
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
                catalog: account.capabilities?[model],
                onSave: { [weak self] in self?.dataSource.update([(0, self?.models ?? [])], reconfigure: true) },
            ),
            animated: true,
        )
    }
}

/// One model's figures: the window a conversation is measured against, the
/// most a reply may be, and what the model itself takes — the catalog's answer
/// for it shown first, and the user's where they set one.
final class ModelParameterFormController: TableController {
    private let model: String
    private let provider: AgentProvider
    /// What the catalogs read this model as, when either named it.
    private let catalog: AgentModelCapabilities?
    private let onSave: () -> Void
    private var values: ModelParameters.Values
    private var window = UITextField()
    private var output = UITextField()
    private var follow = UISwitch()
    private var images = UISwitch()
    private var reasoning = UISwitch()

    private enum Section: Hashable { case catalog, window, output, model }
    private enum Row: Hashable { case entry, follow, window, output, images, reasoning }

    init(
        model: String,
        provider: AgentProvider,
        catalog: AgentModelCapabilities?,
        onSave: @escaping () -> Void,
    ) {
        self.model = model
        self.provider = provider
        self.catalog = catalog
        self.onSave = onSave
        values = ModelParameters.values(for: provider, model: model)
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(model:provider:catalog:onSave:)")
    }

    /// The entry the catalogs found, in their own words: the copy it was read
    /// from, the provider key and the name it spells.
    private var catalogLine: String {
        guard let catalog else { return String(localized: "Not in Any Catalog") }
        let name = catalog.catalogName ?? model
        let copy = catalog.source == "models.dev"
            ? "models.dev"
            : String(localized: "Built-in Catalog")
        guard let provider = catalog.catalogProvider, !provider.isEmpty else { return "\(copy) · \(name)" }
        return "\(copy) · \(provider)/\(name)"
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        guard let self else { return nil }
        switch row {
        case .entry:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Catalog Entry")
            content.secondaryText = catalogLine
            content.secondaryTextProperties.color = catalog == nil ? .secondaryLabel : .label
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.accessibilityValue = catalogLine
            return cell
        case .follow:
            return switchCell(follow, titled: String(localized: "Apply Catalog Figures"))
        case .images:
            return switchCell(images, titled: String(localized: "Takes Images"))
        case .reasoning:
            return switchCell(reasoning, titled: String(localized: "Reasons Before Answering"))
        case .window, .output:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = row == .window
                ? String(localized: "Context Window")
                : String(localized: "Max Output Tokens")
            cell.contentConfiguration = content
            let field = row == .window ? window : output
            field.accessibilityLabel = content.text
            field.frame = CGRect(x: 0, y: 0, width: 120, height: 30)
            cell.accessoryView = field
            return cell
        }
    }

    /// A row that names its switch: the switch speaks its own on and off, and
    /// the row's name is what tells it apart from the others.
    private func switchCell(_ toggle: UISwitch, titled title: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        toggle.accessibilityLabel = title
        cell.accessoryView = toggle
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
        window.text = values.contextWindow.map { "\($0)" }
        output.text = values.maxTokens.map { "\($0)" }
        // A switch starts where the model is read now: the user's answer when
        // they set one, and the catalog's otherwise. Only a switch they move
        // is saved as theirs.
        follow.isOn = values.followsCatalog ?? true
        follow.addAction(UIAction { [weak self] _ in
            self?.values.followsCatalog = self?.follow.isOn
        }, for: .valueChanged)
        images.isOn = values.acceptsImages ?? catalog?.acceptsImages ?? false
        images.addAction(UIAction { [weak self] _ in
            self?.values.acceptsImages = self?.images.isOn
        }, for: .valueChanged)
        reasoning.isOn = values.reasoning ?? catalog?.reasoning ?? false
        reasoning.addAction(UIAction { [weak self] _ in
            self?.values.reasoning = self?.reasoning.isOn
        }, for: .valueChanged)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.save() },
        )
        dataSource.footerTitle = { [weak self] section in
            guard let self else { return nil }
            switch section {
            case .catalog:
                return catalog == nil
                    ? String(localized: "Neither the catalog Apelin ships nor its models.dev copy names this model, so what your provider reports is used.")
                    : String(localized: "Apelin looks a model up by the full name your provider is asked for, and reads it by what the catalog says. Turn this off for an endpoint that refuses a figure it does not honour.")
            case .window:
                return String(localized: "Tokens a conversation may take before your agent compacts it. Leave it empty to use the catalog's figure, or the model's own.")
            case .output:
                return String(localized: "The most a reply may be. Leave it empty to use the catalog's figure, or the model's own.")
            case .model:
                return String(localized: "A switch here overrides the catalog. A model read as text only is sent no images: theirs are dropped before the message goes.")
            }
        }
        dataSource.update([
            (.catalog, [.entry, .follow]),
            (.window, [.window]),
            (.output, [.output]),
            (.model, [.images, .reasoning]),
        ])
    }

    private func save() {
        guard let contextWindow = figure(window.text), let maxTokens = figure(output.text) else {
            presentNotice(
                title: "Invalid Value",
                message: "Enter a whole number of tokens, or leave the field empty.",
            )
            return
        }
        values.contextWindow = contextWindow
        values.maxTokens = maxTokens
        ModelParameters.save(values, for: provider, model: model)
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
