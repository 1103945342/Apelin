import SnapKit
import UIKit

/// A picker's choices in a sheet of the system's own: on iOS 26 its Liquid
/// Glass shows through, the page's background being clear, and before that the
/// grouped background, as the message's sheet does. Every picker opens at one
/// height (owner, 2026-11-06) and the choices scroll inside it, so a provider
/// listing twenty models opens the card a provider listing two does, and the
/// row above the keyboard does not jump from one picker to the next.
///
/// A choice closes the sheet, then runs. Its rows are the composer's own: a
/// label over its detail with the circle that says which one is set, on the
/// fill the question's options use, so choosing a model reads like answering
/// a question.
final class ComposerChoiceSheet: UIViewController {
    struct Choice {
        var title: String
        var subtitle: String?
        /// The one the row is set to, marked with a filled circle and spoken
        /// as selected.
        var isSelected: Bool
        var handler: () -> Void
    }

    /// Choices under a heading of their own, such as one provider's models.
    struct Group {
        var title: String?
        var choices: [Choice]
    }

    /// The height every picker opens at, on a phone and on a card alike.
    static let height: CGFloat = 420

    private let heading: String
    private let groups: [Group]
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    /// Each row with the height it asks for: a row sizes itself to its text,
    /// which needs the width it is given, and the stack asks before it has one.
    private var rows: [(row: ChoiceRow, height: NSLayoutConstraint)] = []
    private static let margin: CGFloat = 16

    init(heading: String, groups: [Group]) {
        self.heading = heading
        self.groups = groups
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(heading:groups:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26, *) {
            view.backgroundColor = .clear
        } else {
            view.backgroundColor = .systemGroupedBackground
        }

        let titleLabel = UILabel()
        titleLabel.text = heading
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        view.addSubview(titleLabel)

        stack.axis = .vertical
        stack.spacing = 8
        for group in groups {
            // A heading stands closer to the choices it names than to the ones
            // above it, so a provider's list reads as one block.
            if let title = group.title, !title.isEmpty {
                let label = UILabel()
                label.text = title
                label.font = .preferredFont(forTextStyle: .footnote)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .secondaryLabel
                label.numberOfLines = 0
                label.accessibilityTraits = .header
                if let previous = stack.arrangedSubviews.last {
                    stack.setCustomSpacing(16, after: previous)
                }
                stack.addArrangedSubview(label)
                stack.setCustomSpacing(4, after: label)
            }
            for choice in group.choices {
                let row = ChoiceRow(title: choice.title, detail: choice.subtitle, chosen: choice.isSelected)
                let handler = choice.handler
                row.addAction(UIAction { [weak self] _ in
                    self?.dismiss(animated: true) { handler() }
                }, for: .touchUpInside)
                rows.append((row, fit(row)))
                stack.addArrangedSubview(row)
            }
        }

        scrollView.alwaysBounceVertical = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(Self.margin)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(Self.margin)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(12)
            make.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }
        stack.snp.makeConstraints { make in
            make.top.equalTo(scrollView.contentLayoutGuide)
            make.bottom.equalTo(scrollView.contentLayoutGuide).offset(-Self.margin)
            make.leading.trailing.equalTo(scrollView.frameLayoutGuide).inset(Self.margin)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The width a row is given is the scroll view's less the margins, and
        // only the layout knows it.
        let width = scrollView.bounds.width - Self.margin * 2
        guard width > 0 else { return }
        for entry in rows {
            let height = ceil(entry.row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            if abs(entry.height.constant - height) > 0.5 {
                entry.height.constant = height
            }
        }
    }

    /// The height `row` is held to, which `viewDidLayoutSubviews` keeps up to
    /// date: the stack asks for one before the row has a width to measure with.
    private func fit(_ row: ChoiceRow) -> NSLayoutConstraint {
        let height = row.heightAnchor.constraint(equalToConstant: 44)
        height.priority = .required
        height.isActive = true
        return height
    }

    /// Presents `sheet` from `presenter`: a card of the sheet's own height on a
    /// phone, a form sheet of it on a window wide enough for one.
    static func present(_ sheet: ComposerChoiceSheet, from presenter: UIViewController) {
        // The card needs the bottom of the screen, which the keyboard is on.
        presenter.view.endEditing(true)
        if presenter.viewIfLoaded?.window?.traitCollection.horizontalSizeClass == .compact {
            sheet.modalPresentationStyle = .pageSheet
            if let controller = sheet.sheetPresentationController {
                controller.detents = [.custom(identifier: .init("choices")) { context in
                    min(context.maximumDetentValue, height)
                }]
                controller.prefersGrabberVisible = true
                controller.prefersEdgeAttachedInCompactHeight = true
            }
        } else {
            sheet.modalPresentationStyle = .formSheet
            sheet.preferredContentSize = CGSize(width: 480, height: height)
        }
        presenter.present(sheet, animated: true)
    }
}

/// One choice of the sheet: its label over its detail, with the circle that
/// says which one is set. A single element, read as its label and detail, a
/// button, selected while chosen.
private final class ChoiceRow: UIControl {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let check = UIImageView()
    private static let inset = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    private static let checkSize: CGFloat = 22

    init(title: String, detail: String?, chosen: Bool) {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous

        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.isHidden = detail?.isEmpty ?? true
        check.image = UIImage(systemName: chosen ? "checkmark.circle.fill" : "circle")
        check.tintColor = chosen ? .label : .tertiaryLabel
        check.contentMode = .scaleAspectFit
        for view in [check, titleLabel, detailLabel] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }

        isAccessibilityElement = true
        accessibilityLabel = [title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityTraits = chosen ? [.button, .selected] : .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:detail:chosen:)")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(1, width - Self.inset.left - Self.inset.right - Self.checkSize - 10)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = textWidth(for: size.width)
        var height = ceil(titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        if !detailLabel.isHidden {
            height += 2 + ceil(detailLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }
        return CGSize(width: size.width, height: max(44, height + Self.inset.top + Self.inset.bottom))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = textWidth(for: bounds.width)
        var y = Self.inset.top
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        titleLabel.frame = CGRect(x: Self.inset.left + Self.checkSize + 10, y: y, width: width, height: titleHeight)
        check.frame = CGRect(
            x: Self.inset.left,
            y: y + (titleHeight - Self.checkSize) / 2,
            width: Self.checkSize,
            height: Self.checkSize,
        )
        y += titleHeight
        guard !detailLabel.isHidden else { return }
        let detailHeight = ceil(detailLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        y += 2
        detailLabel.frame = CGRect(x: titleLabel.frame.minX, y: y, width: width, height: detailHeight)
    }
}
