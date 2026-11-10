import ApelinCore
import ApelinProtocol
import UIKit

/// A single, bounded account-worker request, never a chat or a model selection.
/// The reply stays on this page only; it is not written into conversation logs.
///
/// The report is a grouped list, not one block of text: the verdict and what
/// went wrong first, then what each stage of the request cost, then the model's
/// words, and the two parameters the request carried last. A reader who wants
/// only "did it work, and where did it stop" reads the first two groups.
///
/// The whole list is on screen from the start and fills in as the task reports
/// each stage, so the page shows where the request is while it waits.
final class ModelConnectivityController: UITableViewController {
    private enum Section {
        case verdict
        case stages
        case reply
        case thoughts
        case parameters
    }

    private struct Verdict {
        var symbol: String
        var tint: UIColor
        var title: String
        var subtitle: String?
    }

    private static let plainCell = "cell"

    private let request: AgentModelTestRequest
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var work: Task<Void, Never>?
    /// What each stage has cost so far, and the one running now.
    private var progress: [AgentModelTestPhase: Double] = [:]
    private var running: AgentModelTestPhase?
    private var result: AgentModelTestResponse?
    @objc private dynamic var transportFailure: String?

    init(request: AgentModelTestRequest) {
        self.request = request
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(request:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model Connectivity Test")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(VerdictCell.self, forCellReuseIdentifier: VerdictCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.plainCell)
        start()
    }

    // MARK: - The one request

    private func start() {
        work?.cancel()
        progress = [:]
        running = nil
        result = nil
        transportFailure = nil
        // The spinner is the only way off this page while the request runs;
        // once it has answered, the leading button goes back to the list.
        spinner.accessibilityLabel = String(localized: "Testing…")
        spinner.startAnimating()
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: spinner)
        navigationItem.rightBarButtonItem = nil
        tableView.reloadData()
        let request = request
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let handle = try await ApelinService.app.agentModelTest(request)
                if Task.isCancelled { return }
                for try await event in ApelinService.app.events(of: handle) {
                    if Task.isCancelled { return }
                    if apply(event) { break }
                }
            } catch {
                guard !Task.isCancelled else { return }
                transportFailure = error.readableMessage
            }
            if Task.isCancelled { return }
            if result == nil, transportFailure == nil {
                transportFailure = String(localized: "Unavailable")
            }
            finishModelTest()
        }
    }

    /// One event: a stage as it starts or ends, or the final `state` that
    /// carries the report. Answers whether the task has ended.
    private func apply(_ event: TaskEvent) -> Bool {
        if event.kind == AgentModelTestProgress.eventKind {
            guard let stage = AgentModelTestProgress(payload: event.payload) else { return false }
            if let milliseconds = stage.milliseconds {
                progress[stage.phase] = milliseconds
                if running == stage.phase { running = nil }
            } else {
                running = stage.phase
            }
            reloadStages()
            return false
        }
        guard event.kind == TaskEvent.stateKind else { return false }
        let state = event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:))
        guard state?.isTerminal == true else { return false }
        if let value = event.payload?[AgentModelTestResponse.stateMember],
           let report = try? value.decode(AgentModelTestResponse.self)
        {
            for stage in report.stages { progress[stage.name] = stage.milliseconds }
            result = report
        } else if let message = event.payload?["message"]?.stringValue {
            transportFailure = message
        }
        running = nil
        return true
    }

    @objc private dynamic func finishModelTest() {
        work = nil
        spinner.stopAnimating()
        let back = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        back.accessibilityLabel = String(localized: "Back")
        navigationItem.leftBarButtonItem = back
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Retry"),
            primaryAction: UIAction { [weak self] _ in self?.start() }
        )
        tableView.reloadData()
    }

    /// The stages group is the only one that changes while the task runs:
    /// reloading the whole list would flash the verdict and the reply with it.
    private func reloadStages() {
        guard let section = sections.firstIndex(of: .stages) else { return }
        let rows = Self.phases.indices.map { IndexPath(row: $0, section: section) }
        UIView.performWithoutAnimation {
            tableView.reloadRows(at: rows, with: .none)
        }
    }

    // MARK: - What the screen shows

    private var isFinished: Bool {
        result != nil || transportFailure != nil
    }

    private var thinking: String {
        result?.thinking ?? ""
    }

    private var failure: String? {
        if let failure = result?.failure, !failure.isEmpty { return failure }
        return transportFailure
    }

    /// Every group is here from the start: the stages fill in as the task
    /// reports them, rather than appearing together at the end.
    private var sections: [Section] {
        var sections: [Section] = [.verdict, .stages, .reply]
        if !thinking.isEmpty { sections.append(.thoughts) }
        sections.append(.parameters)
        return sections
    }

    private var verdict: Verdict {
        if let result, result.success {
            let total = result.stages.first { $0.name == .total }
            return Verdict(
                symbol: "checkmark.circle.fill",
                tint: .systemGreen,
                title: String(localized: "Connection Successful"),
                subtitle: total.map { String(localized: "Total Time") + " " + Self.duration($0.milliseconds) }
            )
        }
        if isFinished {
            return Verdict(
                symbol: "xmark.octagon.fill",
                tint: .systemRed,
                title: String(localized: "Connection Failed"),
                subtitle: nil
            )
        }
        return Verdict(
            symbol: "hourglass",
            tint: .secondaryLabel,
            title: String(localized: "Testing…"),
            subtitle: nil
        )
    }

    private var replyText: String {
        guard let result else {
            return transportFailure == nil ? String(localized: "Testing…") : String(localized: "Unavailable")
        }
        return result.text.isEmpty ? String(localized: "No Reply") : result.text
    }

    private static var phases: [(AgentModelTestPhase, String)] {
        [
            (.credentials, String(localized: "Read Credentials")),
            (.preparation, String(localized: "Prepare Model")),
            (.authorization, String(localized: "Authorize Request")),
            (.firstEvent, String(localized: "Time to First Event")),
            (.firstText, String(localized: "Time to First Text")),
            (.response, String(localized: "Receive Response")),
            (.total, String(localized: "Total Time")),
        ]
    }

    /// What a stage row says now: its time once it has ended, the spinner's
    /// sentence while it runs, and plain words for one not reached yet.
    private func stageValue(_ phase: AgentModelTestPhase) -> (text: String, active: Bool) {
        if let milliseconds = progress[phase] { return (Self.duration(milliseconds), false) }
        if isFinished { return (String(localized: "Not Reached"), false) }
        if running == phase { return (String(localized: "Testing…"), true) }
        return (String(localized: "Waiting"), false)
    }

    private static func duration(_ milliseconds: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 1
        // A stage that waited for the model reads in seconds; one that only
        // read a credential or built a request does not.
        let measurement = milliseconds >= 1000
            ? Measurement(value: milliseconds / 1000, unit: UnitDuration.seconds)
            : Measurement(value: milliseconds, unit: UnitDuration.milliseconds)
        return formatter.string(from: measurement)
    }

    private static var numberFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        )
    }

    private static var boldNumberFont: UIFont {
        UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .semibold)
        )
    }

    // MARK: - The list

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
        let offset = tableView.contentOffset
        tableView.reloadData()
        tableView.setContentOffset(offset, animated: false)
    }

    override func numberOfSections(in _: UITableView) -> Int {
        sections.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .verdict:
            return failure == nil ? 1 : 2
        case .stages:
            return Self.phases.count
        case .reply, .thoughts:
            return 1
        case .parameters:
            return 2
        }
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .verdict, .thoughts, .parameters:
            return nil
        case .stages:
            return String(localized: "Stage")
        case .reply:
            return String(localized: "Model Reply")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .verdict:
            return verdictCell(tableView, at: indexPath)
        case .stages:
            return stageCell(tableView, at: indexPath)
        case .reply:
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.plainCell, for: indexPath)
            var config = UIListContentConfiguration.cell()
            config.text = replyText
            config.textProperties.numberOfLines = 0
            cell.contentConfiguration = config
            return cell
        case .thoughts:
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.plainCell, for: indexPath)
            var config = UIListContentConfiguration.valueCell()
            config.text = String(localized: "Thoughts")
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            return cell
        case .parameters:
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.plainCell, for: indexPath)
            var config = UIListContentConfiguration.valueCell()
            if indexPath.row == 0 {
                config.text = String(localized: "Provider")
                config.secondaryText = request.provider.displayName
            } else {
                config.text = String(localized: "Model")
                config.secondaryText = request.model
            }
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            return cell
        }
    }

    private func verdictCell(_ tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.row == 0 else {
            // What went wrong, in the worker's own words, under the verdict
            // rather than in a group of its own.
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.plainCell, for: indexPath)
            var config = UIListContentConfiguration.cell()
            config.text = failure
            config.textProperties.numberOfLines = 0
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: VerdictCell.reuseIdentifier, for: indexPath)
        let verdict = verdict
        (cell as? VerdictCell)?.configure(
            symbol: verdict.symbol,
            tint: verdict.tint,
            title: verdict.title,
            subtitle: verdict.subtitle
        )
        return cell
    }

    private func stageCell(_ tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.plainCell, for: indexPath)
        let (phase, name) = Self.phases[indexPath.row]
        let value = stageValue(phase)
        var config = UIListContentConfiguration.valueCell()
        config.text = name
        // The sentence belongs to the row's value, so VoiceOver reads "Time to
        // First Event, Testing…" while the row spins; the spinner is decoration.
        config.secondaryText = value.text
        config.secondaryTextProperties.color = progress[phase] == nil ? .secondaryLabel : .label
        config.secondaryTextProperties.font = progress[phase] == nil
            ? .preferredFont(forTextStyle: .body)
            : Self.numberFont
        if phase == .total {
            config.textProperties.font = .preferredFont(forTextStyle: .headline)
            if progress[phase] != nil {
                config.secondaryTextProperties.font = Self.boldNumberFont
            }
        }
        cell.contentConfiguration = config
        cell.selectionStyle = .none
        if value.active {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        } else {
            cell.accessoryView = nil
        }
        return cell
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sections[indexPath.section] == .thoughts else { return }
        navigationController?.pushViewController(ThoughtsController(text: thinking), animated: true)
    }
}

/// The first row of the report: one symbol, the verdict in words, and the one
/// number that belongs beside it.
private final class VerdictCell: UITableViewCell {
    static let reuseIdentifier = "verdict"

    private let glyph = UIImageView()
    private let headline = UILabel()
    private let subtitle = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        isAccessibilityElement = true
        glyph.contentMode = .scaleAspectFit
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        headline.font = .preferredFont(forTextStyle: .title3)
        headline.adjustsFontForContentSizeCategory = true
        headline.numberOfLines = 0
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        let words = UIStackView(arrangedSubviews: [headline, subtitle])
        words.axis = .vertical
        words.spacing = 2
        let row = UIStackView(arrangedSubviews: [glyph, words])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        contentView.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:reuseIdentifier:)")
    }

    /// The label is the verdict and the value the number that changes; a
    /// re-test re-announces the time without repeating the sentence.
    func configure(symbol: String, tint: UIColor, title: String, subtitle: String?) {
        glyph.image = UIImage(systemName: symbol)
        glyph.tintColor = tint
        headline.text = title
        headline.textColor = tint
        self.subtitle.text = subtitle
        self.subtitle.isHidden = subtitle == nil
        accessibilityLabel = title
        accessibilityValue = subtitle
    }
}

/// The reasoning the model sent before its answer: long, rarely read twice,
/// and kept off the report.
private final class ThoughtsController: UIViewController {
    private let text: String
    private let textView = UITextView()

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(text:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Thoughts")
        view.backgroundColor = .systemBackground
        textView.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        view.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        setContentScrollView(textView)
    }
}
