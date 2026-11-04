import Litext
import SnapKit
import UIKit

/// What a step's page in the trace shows (`TraceStepController`): a thought's
/// text, or a call's arguments and its result, each as a card of its own.
///
/// Decoded once for each text and size, not again on every layout pass: a call
/// that writes a whole file is a string the size of the file.
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
        /// One argument or the result, on a card of its own.
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
}

/// One argument or result of a tool call, on a card of its own.
///
/// A page of a call is a set of unlike things — a path, a command, a file's
/// content, the lines a diff added — and a wall of text made all of them look
/// alike. The card separates one from the next, and its value is set in the
/// face its kind asks for.
final class ToolCallSectionView: UIView {
    private let card = UIView()
    private let nameLabel = UILabel()
    private let valueLabel = UILabel()

    private var valueTopToName: Constraint?
    private var valueTopToCard: Constraint?

    init(section: ToolCallDetail.Section) {
        super.init(frame: .zero)

        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        addSubview(card)

        nameLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .secondaryLabel
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(nameLabel)

        valueLabel.numberOfLines = 0
        card.addSubview(valueLabel)

        card.snp.makeConstraints { x in x.edges.equalToSuperview() }
        nameLabel.snp.makeConstraints { x in
            x.top.equalToSuperview().offset(10)
            x.leading.trailing.equalToSuperview().inset(12)
        }
        valueLabel.snp.makeConstraints { x in
            // Two places the value can sit; `configure` turns one of them on.
            // Both start off, or the pair would contradict each other before
            // there is a section to decide with.
            valueTopToName = x.top.equalTo(nameLabel.snp.bottom).offset(4).constraint.deactivated
            valueTopToCard = x.top.equalToSuperview().offset(11).constraint.deactivated
            x.leading.trailing.equalToSuperview().inset(12)
            x.bottom.equalToSuperview().offset(-11)
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
        // The value takes the card's own padding when there is no name above
        // it, and hangs under the name when there is.
        valueTopToName?.isActive = hasName
        valueTopToCard?.isActive = !hasName

        // The result of a call is what the call was for; its name says so in
        // the same colour as the values rather than the quiet grey of a label.
        nameLabel.textColor = section.isResult ? .label : .secondaryLabel

        valueLabel.attributedText = Self.value(section)

        // Read as one thing: the name, then what stands under it.
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = hasName ? section.name : String(localized: "Details")
        accessibilityValue = section.value
    }

    /// The value in the face its kind asks for, and — for a diff — each line
    /// in the colour it means.
    private static func value(_ section: ToolCallDetail.Section) -> NSAttributedString {
        let prose = UIFont.preferredFont(forTextStyle: .subheadline)
        let mono = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        )

        switch section.kind {
        case .text:
            return NSAttributedString(
                string: section.value,
                attributes: [.font: prose, .foregroundColor: UIColor.label],
            )
        case .diff:
            return diff(section.value, font: mono)
        case .path, .command, .code, .result:
            return NSAttributedString(
                string: section.value,
                attributes: [.font: mono, .foregroundColor: UIColor.label],
            )
        }
    }

    /// Added lines green, removed lines red, hunk headers quiet: the colours
    /// a diff is read in everywhere else.
    private static func diff(_ text: String, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
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
