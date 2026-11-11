import UIKit

/// The steps behind a summary, drawn under it in the transcript: a thought
/// as prose, a call as a line of its own (`ChatToolCallRow`) that opens into
/// what it was told and what it answered. aimini's chat unfolds a run this
/// way; the trace's own page (`TraceController`) is still there, on a long
/// press, for a call read whole and copied.
@MainActor
final class ChatTraceSteps: UIView {
    /// A call inside was folded or unfolded: the row holding this has to
    /// measure itself again.
    @objc dynamic var onExpansionChange: (() -> Void)?

    /// How tall a thought may get before it stops: a run whose thoughts are
    /// pages long would otherwise bury the calls it made. aimini's tool
    /// sections stop at twenty lines too.
    private static let thoughtLineLimit = 20

    private let stack = UIStackView()
    private var order: [UUID] = []
    private var views: [UUID: UIView] = [:]
    /// What each view shows now, so a step that has not changed is not read
    /// again — a call's arguments can be a whole file.
    private var shown: [UUID: ChatMessage] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 12
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
            (views[step.id] as? ChatToolCallRow)?.show(step)
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
                view = Self.prose(step.text)
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

    /// A thought, or what an approval asked: prose on the transcript's
    /// ground, with no card around it, as the trace's page draws it.
    private static func prose(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = thoughtLineLimit
        label.lineBreakMode = .byTruncatingTail
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.text = text
        label.isAccessibilityElement = true
        label.accessibilityTraits = .staticText
        return label
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
