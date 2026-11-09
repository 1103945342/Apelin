import ApelinProtocol
import UIKit

/// A single, bounded account-worker request, never a chat or a model selection.
/// The reply stays on this page only; it is not written into conversation logs.
final class ModelConnectivityController: UIViewController {
    private let request: AgentModelTestRequest
    private let textView = UITextView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var work: Task<Void, Never>?
    private var result: AgentModelTestResponse?
    @objc private dynamic var transportFailure: String?

    init(request: AgentModelTestRequest) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(request:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model Connectivity Test")
        view.backgroundColor = .systemBackground
        textView.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        textView.adjustsFontForContentSizeCategory = true
        view.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        setContentScrollView(textView)
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: spinner)
        spinner.accessibilityLabel = String(localized: "Testing…")
        spinner.startAnimating()
        renderModelTestReport()
        let request = request
        work = Task { [weak self] in
            do {
                let result = try await ApelinService.app.agentModelTest(request)
                guard !Task.isCancelled else { return }
                self?.result = result
            } catch {
                guard !Task.isCancelled else { return }
                self?.transportFailure = error.readableMessage
            }
            self?.finishModelTest()
        }
    }

    @objc private dynamic func finishModelTest() {
        work = nil
        spinner.stopAnimating()
        // The spinner was the only way off this page while the request ran;
        // once it has answered, the leading button goes back to the list.
        let back = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        back.accessibilityLabel = String(localized: "Back")
        navigationItem.leftBarButtonItem = back
        renderModelTestReport()
    }

    @objc private dynamic func renderModelTestReport() {
        let body = NSMutableAttributedString()
        // A heading with no body under it: the verdicts read as one word, and
        // the detail they used to carry is the reader's to look at below.
        func section(_ title: String, _ text: String = "") {
            let heading = NSMutableParagraphStyle()
            heading.paragraphSpacingBefore = body.length == 0 ? 0 : 20
            heading.paragraphSpacing = 6
            body.append(NSAttributedString(string: title + "\n", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .headline),
                .foregroundColor: UIColor.label,
                .paragraphStyle: heading,
            ]))
            guard !text.isEmpty else { return }
            body.append(NSAttributedString(string: text + "\n", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
            ]))
        }
        section(String(localized: "Model"), request.provider.displayName + "\n" + request.model)
        if let result {
            section(result.success ? String(localized: "Connection Successful") : String(localized: "Connection Failed"))
            if let failure = result.failure, !failure.isEmpty {
                section(String(localized: "Failure Reason"), failure)
            }
            section(String(localized: "Timings"), Self.timings(result))
            section(String(localized: "Model Reply"), result.text.isEmpty ? String(localized: "No Reply") : result.text)
            if !result.thinking.isEmpty {
                section(String(localized: "Thoughts"), result.thinking)
            }
        } else if let transportFailure {
            section(String(localized: "Connection Failed"), transportFailure)
            section(String(localized: "Timings"), String(localized: "Unavailable"))
            section(String(localized: "Model Reply"), String(localized: "Unavailable"))
        } else {
            // What is being sent, and nothing about it: the request is one
            // word, and `AgentModelTester` writes it into the message it sends.
            section(String(localized: "Testing…"), Self.sentText)
        }
        textView.attributedText = body
    }

    /// The one message a connectivity test sends, as `AgentModelTester` builds
    /// it: no system prompt, no history, no tools.
    private static let sentText = "Hi"

    private static func timings(_ result: AgentModelTestResponse) -> String {
        let phases: [(AgentModelTestPhase, String)] = [
            (.credentials, String(localized: "Read Credentials")),
            (.preparation, String(localized: "Prepare Model")),
            (.authorization, String(localized: "Authorize Request")),
            (.firstEvent, String(localized: "Time to First Event")),
            (.firstText, String(localized: "Time to First Text")),
            (.response, String(localized: "Receive Response")),
            (.total, String(localized: "Total Time")),
        ]
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 1
        let rows = phases.map { phase, name in
            let value = result.stages.first { $0.name == phase }.map {
                formatter.string(from: Measurement(value: $0.milliseconds, unit: UnitDuration.milliseconds))
            } ?? String(localized: "Not Reached")
            return name + ": " + value
        }
        return rows.joined(separator: "\n")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
        let offset = textView.contentOffset
        renderModelTestReport()
        textView.setContentOffset(offset, animated: false)
    }
}
