import UIKit

/// One step of the trace, opened from its row: a thought's whole text, or a
/// call's arguments and its result, each on a card of its own (`TraceBody`).
/// A step still streaming grows here as it comes, below wherever the reader is.
final class TraceStepController: UIViewController {
    let stepID: UUID
    private let scrollView = UIScrollView()
    private let stack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = TraceBody.Style.sectionSpacing
        return stack
    }()

    /// What the page shows, nil when it shows nothing.
    private var key: TraceBody.Key?
    /// Between the content and the page's top and foot.
    private static let padding: CGFloat = 16

    init(step: ChatMessage, title: String) {
        stepID = step.id
        super.init(nibName: nil, bundle: nil)
        self.title = title
        show(step)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(step:title:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(stack)
        view.addSubview(scrollView)
        setContentScrollView(scrollView)

        // The page is made of labels and cards, which cannot be selected the
        // way one text could; the whole step goes to the pasteboard instead.
        let copyItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            primaryAction: UIAction { [weak self] _ in self?.copyAll() },
        )
        copyItem.accessibilityLabel = String(localized: "Copy")
        navigationItem.rightBarButtonItem = copyItem
        copyItem.isEnabled = key != nil

        // Laid out by hand: the stack sizes itself to the cards inside it,
        // and only the layout pass knows how wide the page lets it be.
        stack.translatesAutoresizingMaskIntoConstraints = true
    }

    /// A step that did not change keeps what is on screen.
    func show(_ step: ChatMessage) {
        showBody(TraceBody.key(for: step))
    }

    private func showBody(_ key: TraceBody.Key?) {
        guard key != self.key else { return }
        self.key = key
        rebuild()
    }

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        navigationItem.rightBarButtonItem?.isEnabled = key != nil
        guard let key else { return }
        for block in TraceBody.blocks(for: key) {
            switch block {
            case let .text(text):
                stack.addArrangedSubview(Self.prose(text))
            case let .section(section):
                stack.addArrangedSubview(ToolCallSectionView(section: section))
            }
        }
        viewIfLoaded?.setNeedsLayout()
    }

    private func copyAll() {
        guard let key else { return }
        UIPasteboard.general.string = TraceBody.plainText(for: key)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A thought, or what an approval asked: prose on the page itself, with
    /// no card around it.
    private static func prose(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.text = text
        label.isAccessibilityElement = true
        label.accessibilityTraits = .staticText
        return label
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // the cards are built in the size they are drawn at
        let size = UIApplication.shared.preferredContentSizeCategory
        guard let key, key.size != size else { return }
        showBody(TraceBody.Key(source: key.source, callTitle: key.callTitle, size: size))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        let readable = view.readableContentGuide.layoutFrame
        guard readable.width > 0 else { return }
        let fitted = stack.systemLayoutSizeFitting(
            CGSize(width: readable.width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        )
        stack.frame = CGRect(
            x: readable.minX,
            y: Self.padding,
            width: readable.width,
            height: ceil(fitted.height),
        )
        scrollView.contentSize = CGSize(
            width: view.bounds.width,
            height: stack.frame.height + Self.padding * 2,
        )
    }
}
