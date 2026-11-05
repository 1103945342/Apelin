import ApelinProtocol
import UIKit

/// The outstanding decision replaces the input. Only its result enters history.
///
/// A question the agent asked (`ChatMessage.question`) takes the same place:
/// its options in place of the detail, each a button, then Other… for an
/// answer of the reader's own. One option answers it at once; a question
/// that takes several has Send. Skip takes Deny's place.
final class ComposerApprovalSection: ComposerSectionView {
    /// The request and the decision; Approve on a request as root waits on
    /// the device owner's check there before anything is sent.
    var onDecision: ((ChatMessage, ApprovalDecision) -> Void)?
    /// A question answered with the labels chosen, or skipped (nil).
    var onAnswer: ((ChatMessage, AgentQuestionAnswer?) -> Void)?
    /// Other… was tapped: the reader writes an answer of their own, sent
    /// with the labels already chosen.
    var onAnswerOther: ((ChatMessage, [String]) -> Void)?
    private var request: ChatMessage?
    var isPresentingRequest: Bool {
        request != nil
    }

    private let titleLabel = UILabel()
    /// Shown only for a command that runs as root, between the title and
    /// the detail, so it is read before the command.
    private let rootLabel = UILabel()
    private var detailViews: [UIView] = []
    /// A question's options, then Other…, in the scroll under the title.
    private var optionViews: [QuestionOptionControl] = []
    /// The options chosen of a question that takes several, by index.
    private var chosen: Set<Int> = []
    /// The title and detail: a request taller than half the window scrolls
    /// from its start, under buttons that stay in place.
    private let textScroll = UIScrollView()
    private let approveButton = UIButton(type: .system)
    private let denyButton = UIButton(type: .system)

    override func initializeViews() {
        super.initializeViews()
        clipsToBounds = true
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        // Drawn at the final size and pinned to the top, not stretched, while a frame animates.
        titleLabel.contentMode = .topLeft
        titleLabel.accessibilityTraits.insert(.header)
        let subheadline = UIFont.preferredFont(forTextStyle: .subheadline)
        rootLabel.font = subheadline.fontDescriptor.withSymbolicTraits(.traitBold)
            .map { UIFont(descriptor: $0, size: 0) } ?? subheadline
        rootLabel.adjustsFontForContentSizeCategory = true
        rootLabel.textColor = .systemRed
        rootLabel.numberOfLines = 0
        rootLabel.contentMode = .topLeft
        rootLabel.text = String(localized: "Runs as root, with full control of this device")
        var approveStyle = UIButton.Configuration.filled()
        approveStyle.baseBackgroundColor = .label
        approveStyle.baseForegroundColor = .systemBackground
        approveStyle.cornerStyle = .medium
        approveStyle.titleLineBreakMode = .byTruncatingTail
        approveStyle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .headline)
            return attributes
        }
        approveButton.configuration = approveStyle
        var denyStyle = UIButton.Configuration.gray()
        denyStyle.baseForegroundColor = .label
        denyStyle.cornerStyle = .medium
        denyStyle.titleTextAttributesTransformer = approveStyle.titleTextAttributesTransformer
        denyStyle.titleLineBreakMode = .byTruncatingTail
        denyButton.configuration = denyStyle
        setButtons(for: nil)
        approveButton.addAction(UIAction { [weak self] _ in self?.decide(.approve) }, for: .touchUpInside)
        denyButton.addAction(UIAction { [weak self] _ in self?.decide(.deny) }, for: .touchUpInside)
        textScroll.contentInsetAdjustmentBehavior = .never
        for view in [titleLabel, rootLabel] {
            textScroll.addSubview(view)
        }
        for view in [textScroll, denyButton, approveButton] {
            addSubview(view)
        }
        alpha = 0
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    func show(_ message: ChatMessage?) {
        guard request != message else { return }
        let replacing = request != nil
        if let message, !replacing {
            // Placed while still hidden, so the content is revealed by the
            // card rather than growing out of a zero frame.
            UIView.performWithoutAnimation {
                setText(of: message)
                layoutContent()
            }
        }
        let update = { [self] in
            request = message
            if let message, replacing {
                for label in [titleLabel, rootLabel] {
                    UIView.transition(
                        with: label,
                        duration: 0.25,
                        options: [.transitionCrossDissolve, .allowUserInteraction],
                    ) {}
                }
                setText(of: message)
            }
            let visible = message != nil
            alpha = visible ? 1 : 0
            isUserInteractionEnabled = visible
            accessibilityElementsHidden = !visible
            heightPublisher.send(visible ? layoutContent() : 0)
            // The composer's layout follows whether a request is shown, not only this band's height.
            superview?.setNeedsLayout()
        }
        if window != nil, !UIAccessibility.isReduceMotionEnabled {
            (superview ?? self).doWithAnimation(update)
        } else {
            UIView.performWithoutAnimation(update)
        }
    }

    private func setText(of message: ChatMessage) {
        titleLabel.text = message.approvalTitle
        rootLabel.isHidden = !message.runsAsRoot
        detailViews.forEach { $0.removeFromSuperview() }
        detailViews = []
        optionViews.forEach { $0.removeFromSuperview() }
        optionViews = []
        chosen = []
        setButtons(for: message.question)
        if let question = message.question {
            setOptions(of: question)
            textScroll.contentOffset = .zero
            return
        }
        let sections = message.approvalSections.isEmpty
            ? [ApprovalCardText.Section(text: message.approvalDetail)] : message.approvalSections
        for section in sections where !section.text.isEmpty {
            if let title = section.title, !section.isCode {
                let label = UILabel()
                label.text = title
                label.font = .preferredFont(forTextStyle: .callout)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .secondaryLabel
                label.numberOfLines = 0
                label.accessibilityTraits.insert(.header)
                detailViews.append(label)
            }
            if section.isCode {
                let code = UITextView()
                code.text = section.text
                code.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
                code.adjustsFontForContentSizeCategory = true
                code.textColor = .label
                code.backgroundColor = .clear
                code.isEditable = false
                code.isSelectable = true
                code.isScrollEnabled = false
                code.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
                code.textContainer.lineFragmentPadding = 0
                code.textContainer.lineBreakMode = .byCharWrapping
                code.accessibilityLabel = section.title
                detailViews.append(ApprovalCodeBlock(title: section.title, code: code))
            } else {
                let label = UILabel()
                label.text = section.text
                label.font = .preferredFont(forTextStyle: .callout)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .secondaryLabel
                label.numberOfLines = 0
                detailViews.append(label)
            }
        }
        detailViews.forEach { textScroll.addSubview($0) }
        textScroll.contentOffset = .zero
    }

    /// A question's options, each a button, then Other…. A check beside
    /// each shows what is chosen when several may be.
    private func setOptions(of question: AgentQuestion) {
        for (index, option) in question.options.enumerated() {
            let control = QuestionOptionControl(title: option.label, detail: option.detail, checks: question.multiple)
            control.addAction(UIAction { [weak self] _ in self?.choose(index) }, for: .touchUpInside)
            optionViews.append(control)
        }
        let other = QuestionOptionControl(title: String(localized: "Other…"), detail: nil, checks: false)
        other.addAction(UIAction { [weak self] _ in self?.answerOther() }, for: .touchUpInside)
        optionViews.append(other)
        optionViews.forEach { textScroll.addSubview($0) }
    }

    /// Deny and Approve, or for a question Skip, and Send when it takes
    /// several options — enabled once one is chosen.
    private func setButtons(for question: AgentQuestion?) {
        if let question {
            denyButton.setTitle(String(localized: "Skip"), for: .normal)
            approveButton.setTitle(String(localized: "Send"), for: .normal)
            approveButton.isHidden = !question.multiple
            approveButton.isEnabled = !chosen.isEmpty
        } else {
            denyButton.setTitle(String(localized: "Deny"), for: .normal)
            approveButton.setTitle(String(localized: "Approve"), for: .normal)
            approveButton.isHidden = false
            approveButton.isEnabled = true
        }
    }

    private func choose(_ index: Int) {
        guard let request, let question = request.question, question.options.indices.contains(index) else { return }
        guard question.multiple else {
            onAnswer?(request, AgentQuestionAnswer(selected: [question.options[index].label]))
            return
        }
        if chosen.remove(index) == nil {
            chosen.insert(index)
        }
        for (position, control) in optionViews.enumerated() where position < question.options.count {
            control.isChosen = chosen.contains(position)
        }
        approveButton.isEnabled = !chosen.isEmpty
    }

    /// The labels chosen, in the question's order.
    private func chosenLabels(of question: AgentQuestion) -> [String] {
        question.options.indices.filter(chosen.contains).map { question.options[$0].label }
    }

    private func answerOther() {
        guard let request, let question = request.question else { return }
        onAnswerOther?(request, chosenLabels(of: question))
    }

    private func decide(_ decision: ApprovalDecision) {
        guard let request else { return }
        if let question = request.question {
            switch decision {
            case .approve:
                let labels = chosenLabels(of: question)
                guard !labels.isEmpty else { return }
                onAnswer?(request, AgentQuestionAnswer(selected: labels))
            case .deny:
                onAnswer?(request, nil)
            }
            return
        }
        onDecision?(request, decision)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard request != nil else { return }
        heightPublisher.send(layoutContent())
    }

    /// Places the content for the current width and answers the height it needs.
    @discardableResult
    private func layoutContent() -> CGFloat {
        let contentWidth = max(1, bounds.width)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height,
        )
        titleLabel.frame = CGRect(x: 0, y: ChatMarkdownView.blockSpacing, width: contentWidth, height: titleHeight)
        var textBottom = titleLabel.frame.maxY
        if !rootLabel.isHidden {
            let rootHeight = ceil(
                rootLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height,
            )
            rootLabel.frame = CGRect(x: 0, y: textBottom + ChatMarkdownView.blockSpacing / 2, width: contentWidth, height: rootHeight)
            textBottom = rootLabel.frame.maxY
        }
        for (index, detail) in detailViews.enumerated() {
            let gap: CGFloat = index > 0 && (detailViews[index - 1] as? UILabel)?.accessibilityTraits.contains(.header) == true ? 6 : 14
            let height = ceil(detail.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
            detail.frame = CGRect(x: 0, y: textBottom + gap, width: contentWidth, height: height)
            textBottom = detail.frame.maxY
        }
        for (index, option) in optionViews.enumerated() {
            let gap: CGFloat = index == 0 ? 14 : 8
            let height = ceil(option.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
            option.frame = CGRect(x: 0, y: textBottom + gap, width: contentWidth, height: height)
            textBottom = option.frame.maxY
        }
        let textHeight = textBottom
        textScroll.contentSize = CGSize(width: contentWidth, height: textHeight)
        textScroll.frame = CGRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: min(textHeight, (window?.bounds.height ?? .greatestFiniteMagnitude) / 2),
        )
        let actionY = textScroll.frame.maxY + ChatMarkdownView.blockSpacing
        let buttonHeight = max(44, ceil(UIFont.preferredFont(forTextStyle: .headline).lineHeight + 22))
        let row = CGRect(x: 0, y: actionY, width: contentWidth, height: buttonHeight)
        // A question that takes one option has Skip alone, across the row.
        guard !approveButton.isHidden else {
            denyButton.frame = row
            return row.maxY + ChatMarkdownView.blockSpacing
        }
        let buttonWidth = (contentWidth - ChatMarkdownView.blockSpacing) / 2
        // Deny then Approve in reading order: right to left, Deny on the right
        let deny = CGRect(x: 0, y: actionY, width: buttonWidth, height: buttonHeight)
        denyButton.frame = directionalFrame(deny, across: row)
        approveButton.frame = directionalFrame(
            CGRect(x: deny.maxX + ChatMarkdownView.blockSpacing, y: actionY, width: buttonWidth, height: buttonHeight),
            across: row,
        )
        return approveButton.frame.maxY + ChatMarkdownView.blockSpacing
    }
}

/// One option of a question: its label over its detail, in a rounded cell,
/// with a check when several may be chosen. A single element, read as its
/// label and detail, a button, selected while chosen.
private final class QuestionOptionControl: UIControl {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let check = UIImageView()
    private let checks: Bool
    private static let inset = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    private static let checkSize: CGFloat = 22

    var isChosen = false {
        didSet { updateCheck() }
    }

    /// The check and the trait for `isChosen`; called from `init` too, where
    /// `didSet` does not run.
    private func updateCheck() {
        check.image = UIImage(systemName: isChosen ? "checkmark.circle.fill" : "circle")
        check.tintColor = isChosen ? .label : .tertiaryLabel
        if isChosen {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }

    init(title: String, detail: String?, checks: Bool) {
        self.checks = checks
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
        check.contentMode = .scaleAspectFit
        check.isHidden = !checks
        for view in [titleLabel, detailLabel, check] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityLabel = [title, detail].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityTraits = .button
        updateCheck()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:detail:checks:)")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(1, width - Self.inset.left - Self.inset.right - (checks ? Self.checkSize + 10 : 0))
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
        let row = bounds
        var y = Self.inset.top
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let textX = Self.inset.left + (checks ? Self.checkSize + 10 : 0)
        titleLabel.frame = directionalFrame(CGRect(x: textX, y: y, width: width, height: titleHeight), across: row)
        y += titleHeight
        if !detailLabel.isHidden {
            let detailHeight = ceil(detailLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            detailLabel.frame = directionalFrame(CGRect(x: textX, y: y + 2, width: width, height: detailHeight), across: row)
        }
        check.frame = directionalFrame(
            CGRect(x: Self.inset.left, y: (bounds.height - Self.checkSize) / 2, width: Self.checkSize, height: Self.checkSize),
            across: row,
        )
    }
}

/// The caption decorates the block; selecting or copying still takes only code.
private final class ApprovalCodeBlock: UIView {
    private let caption = UILabel()
    private let code: UITextView

    init(title: String?, code: UITextView) {
        self.code = code
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        clipsToBounds = true
        caption.text = title?.uppercased(with: .current)
        caption.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        caption.numberOfLines = 0
        caption.isHidden = title == nil
        caption.accessibilityTraits.insert(.header)
        addSubview(caption)
        addSubview(code)
        code.textContainerInset = UIEdgeInsets(top: title == nil ? 14 : 8, left: 12, bottom: 14, right: 12)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:code:)")
    }

    private func captionHeight(for width: CGFloat) -> CGFloat {
        caption.isHidden ? 0 : ceil(caption.sizeThatFits(CGSize(width: max(1, width - 24), height: .greatestFiniteMagnitude)).height) + 12
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: captionHeight(for: size.width)
            + ceil(code.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude)).height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let headerHeight = captionHeight(for: bounds.width)
        caption.frame = CGRect(x: 12, y: 12, width: max(0, bounds.width - 24), height: max(0, headerHeight - 12))
        code.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
    }
}
