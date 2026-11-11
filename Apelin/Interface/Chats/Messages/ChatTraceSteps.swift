import SnapKit
import UIKit

/// The steps behind a summary, drawn under it in the transcript: a thought
/// as one line that opens into what the model said to itself
/// (`ChatThoughtRow`), a call as one line that opens into what it was told
/// and what it answered (`ChatToolCallRow`). aimini's chat unfolds a run
/// this way; the trace's own page (`TraceController`) is still there, on a
/// long press, for a step read whole and copied.
@MainActor
final class ChatTraceSteps: UIView {
    /// A line inside was folded or unfolded: the row holding this has to
    /// measure itself again.
    @objc dynamic var onExpansionChange: (() -> Void)?

    private let stack = UIStackView()
    private var order: [UUID] = []
    private var views: [UUID: UIView] = [:]
    /// What each view shows now, so a step that has not changed is not read
    /// again — a call's arguments can be a whole file.
    private var shown: [UUID: ChatMessage] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = true
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// The summary's steps as they are now: one that has not changed keeps
    /// what is on screen, so a stream grows the last of them in place.
    func show(_ summary: ChatMessage) {
        let steps = TraceStep.messages(of: summary)
        guard steps.map(\.id) == order else {
            rebuild(with: steps)
            return
        }
        for step in steps where shown[step.id] != step {
            if let row = views[step.id] as? ChatToolCallRow {
                row.show(step)
            } else if let row = views[step.id] as? ChatThoughtRow {
                row.show(step)
            }
            shown[step.id] = step
        }
    }

    private func rebuild(with steps: [ChatMessage]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        views.removeAll(keepingCapacity: true)
        shown.removeAll(keepingCapacity: true)
        order = steps.map(\.id)
        for step in steps {
            let view: UIView
            switch step.role {
            case .thinking:
                let row = ChatThoughtRow(step: step)
                row.onToggle = { [weak self] in self?.onExpansionChange?() }
                view = row
            default:
                let row = ChatToolCallRow(step: step)
                row.onToggle = { [weak self] in self?.onExpansionChange?() }
                view = row
            }
            stack.addArrangedSubview(view)
            views[step.id] = view
            shown[step.id] = step
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.frame = bounds
    }

    /// The height the steps take at `width`, as they are drawn now.
    func fittingHeight(width: CGFloat) -> CGFloat {
        Self.height(of: stack, width: width)
    }

    /// The same for a summary the list is measuring, which it does without
    /// the row that will show it.
    static func height(for summary: ChatMessage, width: CGFloat) -> CGFloat {
        guard width > 1 else { return 0 }
        sizing.show(summary)
        return height(of: sizing.stack, width: width)
    }

    private static func height(of stack: UIStackView, width: CGFloat) -> CGFloat {
        let fitted = stack.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        )
        return ceil(fitted.height)
    }

    /// The one view the list's heights are measured in.
    private static let sizing = ChatTraceSteps()
}

/// One thought of a run, folded into a line: how long it thought, and — once
/// the reader opens it — what it said to itself. aimini's chat keeps a
/// thought to one line for the same reason: the process reads as what the
/// run did, and the monologue is there for whoever asks for it.
final class ChatThoughtRow: UIView {
    /// The line was tapped: the text is open now or it is not.
    @objc dynamic var onToggle: (() -> Void)?
    let stepID: UUID

    private var step: ChatMessage
    private let line = UIControl()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let chevron = UIImageView()
    private let textLabel = UILabel()
    private var showsBody = false

    /// How much of a thought the row draws before it stops: a run whose
    /// thoughts run to pages would otherwise bury the calls it made. The
    /// whole of it is in the trace's page, a long press away.
    private static let lineLimit = 20

    private enum Style {
        static let lineHeight: CGFloat = 28
        static let iconSize: CGFloat = 15
        static let chevronSize: CGFloat = 11
        static let spacing: CGFloat = 6
        /// Between the line and the text under it.
        static let bodySpacing: CGFloat = 6

        static var titleFont: UIFont {
            UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: .systemFont(ofSize: 14, weight: .medium),
            )
        }

        static var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: .subheadline) }
    }

    init(step: ChatMessage) {
        stepID = step.id
        self.step = step
        super.init(frame: .zero)

        line.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        addSubview(line)

        icon.image = UIImage(systemName: "brain.head.profile")
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .secondaryLabel
        icon.isAccessibilityElement = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.addSubview(icon)

        titleLabel.font = Style.titleFont
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        line.addSubview(titleLabel)

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Style.chevronSize, weight: .semibold),
        )
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.isAccessibilityElement = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.addSubview(chevron)

        textLabel.font = Style.bodyFont
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.textColor = .secondaryLabel
        textLabel.numberOfLines = Self.lineLimit
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.isHidden = true
        addSubview(textLabel)

        line.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.greaterThanOrEqualTo(Style.lineHeight)
        }
        icon.snp.makeConstraints { make in
            make.leading.centerY.equalToSuperview()
            make.size.equalTo(Style.iconSize)
        }
        chevron.snp.makeConstraints { make in
            make.trailing.centerY.equalToSuperview()
            make.size.equalTo(Style.chevronSize + 4)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(icon.snp.trailing).offset(Style.spacing)
            make.trailing.equalTo(chevron.snp.leading).offset(-Style.spacing)
            make.centerY.equalToSuperview()
        }
        textLabel.snp.makeConstraints { make in
            make.top.equalTo(line.snp.bottom).offset(Style.bodySpacing)
            make.leading.trailing.bottom.equalToSuperview()
        }

        configure(step)
        updateChevron(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(step:)")
    }

    /// The same thought as it grows, or a new one.
    func show(_ step: ChatMessage) {
        guard step != self.step else { return }
        self.step = step
        configure(step)
    }

    private func configure(_ step: ChatMessage) {
        titleLabel.text = Self.title(for: step)
        textLabel.text = step.text
        showsBody = ChatTraceExpansion.isExpanded(thought: step.id)
        textLabel.isHidden = !showsBody
        textLabel.snp.updateConstraints { make in
            make.top.equalTo(line.snp.bottom).offset(showsBody ? Style.bodySpacing : 0)
        }
        updateAccessibility()
    }

    /// "Thinking…" while it thinks, then how long it thought.
    private static func title(for step: ChatMessage) -> String {
        guard case let .thinking(seconds, _) = step.role, let seconds else {
            return String(localized: "Thinking…")
        }
        return seconds == 1
            ? String(localized: "Thought for 1 second")
            : String(localized: "Thought for \(seconds) seconds")
    }

    private func updateChevron(animated: Bool) {
        let turn = CGAffineTransform(rotationAngle: showsBody ? .pi / 2 : 0)
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            chevron.transform = turn
            return
        }
        UIView.animate(withDuration: 0.2) { self.chevron.transform = turn }
    }

    /// Folded, the row is one stop that opens the thought; open, the line and
    /// the text are read on their own.
    private func updateAccessibility() {
        if showsBody {
            isAccessibilityElement = false
            line.isAccessibilityElement = true
            line.accessibilityLabel = titleLabel.text
            line.accessibilityTraits = .button
            line.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "Collapse")) { [weak self] _ in
                    self?.toggle()
                    return true
                },
            ]
            textLabel.isAccessibilityElement = true
            textLabel.accessibilityTraits = .staticText
        } else {
            isAccessibilityElement = true
            accessibilityLabel = titleLabel.text
            accessibilityTraits = .button
            line.isAccessibilityElement = false
            textLabel.isAccessibilityElement = false
        }
    }

    override func accessibilityActivate() -> Bool {
        guard !showsBody else { return false }
        toggle()
        return true
    }

    @objc dynamic private func toggle() {
        ChatTraceExpansion.setExpanded(thought: step.id, !showsBody)
        configure(step)
        updateChevron(animated: true)
        onToggle?()
    }
}
