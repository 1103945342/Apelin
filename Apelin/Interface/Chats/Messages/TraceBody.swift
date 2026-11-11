import Litext
import SnapKit
import UIKit

/// What a step's page in the trace shows (`TraceStepController`): a thought's
/// text, or a call's arguments and its result.
///
/// The page is a document, not a stack of boxes: a thought is prose on the
/// ground, an argument is a line of label and value, and only the things that
/// are content — a command's output, a file's text, a diff — rise into a
/// panel of their own. Decoded once for each text and size, not again on
/// every layout pass.
@MainActor
enum TraceBody {
    struct Key: Hashable {
        /// The thought's text, the call's detail, or the approval's card text.
        let source: String
        /// A call's title, whose repeat as `reason` is left out; nil for
        /// plain text, a thought's or an approval's.
        let callTitle: String?
        let size: UIContentSizeCategory
    }

    /// One thing to draw on the page.
    enum Block: Equatable {
        /// A thought, or what an approval asked: prose, on the page itself.
        case text(String)
        /// One argument or the result, drawn as a line of the document.
        case section(ToolCallDetail.Section)
    }

    private static var cache: [Key: [Block]] = [:]
    /// Past this many entries the cache starts again: a step that streams is a
    /// new key each time it grows.
    private static let capacity = 64

    /// A step's key, or nil for a step with nothing to show.
    static func key(for message: ChatMessage) -> Key? {
        let size = UIApplication.shared.preferredContentSizeCategory
        switch message.role {
        case .thinking:
            return message.text.isEmpty ? nil : Key(source: message.text, callTitle: nil, size: size)
        case .approval:
            let detail = message.approvalDetail
            return detail.isEmpty ? nil : Key(source: detail, callTitle: nil, size: size)
        default:
            return message.detail.isEmpty ? nil : Key(source: message.detail, callTitle: message.text, size: size)
        }
    }

    static func blocks(for key: Key) -> [Block] {
        if let blocks = cache[key] {
            return blocks
        }
        if cache.count >= capacity {
            cache.removeAll()
        }
        let blocks = build(key)
        cache[key] = blocks
        return blocks
    }

    /// The whole page as one string, for the copy button: what a reader wants
    /// when they take a call away from here.
    static func plainText(for key: Key) -> String {
        blocks(for: key).map { block in
            switch block {
            case let .text(text):
                return text
            case let .section(section):
                return section.name.map { $0 + "\n" + section.value } ?? section.value
            }
        }.joined(separator: "\n\n")
    }

    private static func build(_ key: Key) -> [Block] {
        guard let title = key.callTitle else {
            return key.source.isEmpty ? [] : [.text(key.source)]
        }
        return ToolCallDetail(detail: key.source, title: title).sections.map(Block.section)
    }

    // MARK: - The page's measures

    /// What the page and the lines on it are drawn with. The scale is aimini's
    /// message document: one ground the whole page shares, hairlines between
    /// things, and a panel for content that is more than a line.
    enum Style {
        /// Between one section and the next.
        static let sectionSpacing: CGFloat = 14
        /// The label above a value, and the value under it.
        static let labelSpacing: CGFloat = 3
        /// A block value: its label, and then the panel's own room.
        static let blockSpacing: CGFloat = 6
        /// Inside a block panel.
        static let panelPadding: CGFloat = 10
        static let panelCorner: CGFloat = 8
        /// Between a rule and what follows it.
        static let ruleSpacing: CGFloat = 10

        static var hairline: CGFloat { 1 / max(UIScreen.main.scale, 1) }

        /// The label above a value: small, quiet, and never the point.
        static var labelFont: UIFont {
            UIFontMetrics(forTextStyle: .caption1).scaledFont(
                for: .systemFont(ofSize: 11, weight: .semibold),
            )
        }

        /// A value that is a word or a line.
        static var valueFont: UIFont { UIFont.preferredFont(forTextStyle: .subheadline) }

        /// A value that is a path or a command.
        static var monospacedValueFont: UIFont {
            UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: .monospacedSystemFont(ofSize: 13, weight: .regular),
            )
        }

        /// A block: the output of a command, a file's text, a diff.
        static var blockFont: UIFont {
            UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(ofSize: 12, weight: .regular),
            )
        }

        /// The ground a block sits on: a shade off the page, never a card's
        /// white lifted above it.
        static var panelColor: UIColor { .secondarySystemFill }
        static var ruleColor: UIColor { .separator }
    }
}

/// One argument or result of a tool call, as a line of the document: a quiet
/// label, then its value. A value that is more than a line — a command's
/// output, a file's text, a diff — drops into a panel of its own, so the page
/// reads as a document with blocks in it rather than a stack of cards.
final class ToolCallSectionView: UIView {
    private let stack = UIStackView()
    private let rule = UIView()
    private let nameLabel = UILabel()
    private let valueLabel = UILabel()
    private let panel = UIView()
    /// A block's text, held whole in a scroll view of its own: the panel is
    /// as tall as the text, or as tall as `maximumBlockHeight` lets it be,
    /// and the rest of the text is reached by scrolling inside it.
    private let panelScroll = UIScrollView()
    private let panelLabel = UILabel()

    /// `maximumBlockHeight`: the tallest a block is drawn, as aimini's tool
    /// sections are. Nil draws a block as tall as it is, which is what the
    /// trace's page does with the room it has.
    init(section: ToolCallDetail.Section, maximumBlockHeight: CGFloat? = nil) {
        super.init(frame: .zero)

        stack.axis = .vertical
        stack.spacing = TraceBody.Style.labelSpacing
        addSubview(stack)
        stack.snp.makeConstraints { x in x.edges.equalToSuperview() }

        rule.backgroundColor = TraceBody.Style.ruleColor
        rule.snp.makeConstraints { x in x.height.equalTo(TraceBody.Style.hairline) }

        nameLabel.font = TraceBody.Style.labelFont
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .tertiaryLabel
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail

        valueLabel.numberOfLines = 0

        panel.backgroundColor = TraceBody.Style.panelColor
        panel.layer.cornerRadius = TraceBody.Style.panelCorner
        panel.layer.cornerCurve = .continuous
        panelScroll.alwaysBounceVertical = false
        panelScroll.showsVerticalScrollIndicator = maximumBlockHeight != nil
        panelLabel.numberOfLines = 0
        panel.addSubview(panelScroll)
        panelScroll.addSubview(panelLabel)
        panelScroll.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(TraceBody.Style.panelPadding)
        }
        // The text fills the scroll view across, and is as tall as it is: the
        // guides below are UIKit's own, which this SnapKit has no shorthand
        // for.
        panelLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panelLabel.leadingAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.leadingAnchor),
            panelLabel.trailingAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.trailingAnchor),
            panelLabel.topAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.topAnchor),
            panelLabel.bottomAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.bottomAnchor),
            panelLabel.widthAnchor.constraint(equalTo: panelScroll.frameLayoutGuide.widthAnchor),
        ])

        // The panel is as tall as its text while that fits, and as tall as
        // the limit once it does not: the height it would take from the text
        // is the stronger wish, the limit is what is left when the text is
        // longer, and the view scrolls the part it cannot show. Both are
        // constraints, so the row measured before it is laid out and the row
        // drawn come out the same height.
        let fits = panelScroll.heightAnchor.constraint(equalTo: panelLabel.heightAnchor)
        fits.priority = UILayoutPriority(999)
        fits.isActive = true
        if let maximumBlockHeight {
            panelScroll.heightAnchor.constraint(lessThanOrEqualToConstant: maximumBlockHeight).isActive = true
            let holds = panelScroll.heightAnchor.constraint(equalToConstant: maximumBlockHeight)
            holds.priority = UILayoutPriority(750)
            holds.isActive = true
        }

        for view in [rule as UIView, nameLabel, valueLabel, panel] {
            stack.addArrangedSubview(view)
        }

        configure(section)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(section:)")
    }

    func configure(_ section: ToolCallDetail.Section) {
        let hasName = section.name?.isEmpty == false
        nameLabel.text = section.name
        nameLabel.isHidden = !hasName

        let kind = section.kind
        // Blocks are the things that are content; everything else is a line.
        let isBlock = kind == .code || kind == .diff || kind == .result
        valueLabel.isHidden = isBlock
        panel.isHidden = !isBlock
        if isBlock {
            panelLabel.attributedText = Self.blockText(section, kind: kind)
        } else {
            valueLabel.attributedText = Self.lineText(section, kind: kind)
        }

        // A result is what the call was for: it gets a hairline above it, so
        // the page says where the arguments end and the answer begins.
        rule.isHidden = !section.isResult
        stack.setCustomSpacing(TraceBody.Style.ruleSpacing, after: rule)
        // A block wants a little more air under its label than a single line.
        stack.setCustomSpacing(
            isBlock ? TraceBody.Style.blockSpacing : TraceBody.Style.labelSpacing,
            after: nameLabel,
        )

        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = hasName ? section.name : String(localized: "Details")
        accessibilityValue = section.value
    }

    /// A value that is a word or a line, in the face its kind asks for.
    private static func lineText(_ section: ToolCallDetail.Section, kind: ToolCallDetail.Section.Kind) -> NSAttributedString {
        let isMonospaced = kind == .path || kind == .command
        return NSAttributedString(
            string: section.value,
            attributes: [
                .font: isMonospaced ? TraceBody.Style.monospacedValueFont : TraceBody.Style.valueFont,
                .foregroundColor: isMonospaced ? UIColor.secondaryLabel : UIColor.label,
            ],
        )
    }

    /// A value that is a block of text: monospaced, and — for a diff — each
    /// line in the colour it means.
    private static func blockText(
        _ section: ToolCallDetail.Section,
        kind: ToolCallDetail.Section.Kind,
    ) -> NSAttributedString {
        let font = TraceBody.Style.blockFont
        guard kind == .diff else {
            return NSAttributedString(
                string: section.value,
                attributes: [.font: font, .foregroundColor: UIColor.label],
            )
        }
        let result = NSMutableAttributedString()
        let lines = section.value.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let string = String(line)
            let colour: UIColor
            if string.hasPrefix("+++") || string.hasPrefix("---") {
                colour = .secondaryLabel
            } else if string.hasPrefix("+") {
                colour = .systemGreen
            } else if string.hasPrefix("-") {
                colour = .systemRed
            } else if string.hasPrefix("@@") {
                colour = .systemTeal
            } else {
                colour = .label
            }
            let isLast = index == lines.count - 1
            result.append(NSAttributedString(
                string: isLast ? string : string + "\n",
                attributes: [.font: font, .foregroundColor: colour],
            ))
        }
        return result
    }
}
