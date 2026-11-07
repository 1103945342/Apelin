import CoreText
import Litext
import LitextAnimation
import UIKit

/// A conversation's name on the bar, drawn as the bar draws its own title
/// and rolled to the next one by Litext's numeric transition when another
/// conversation is picked.
///
/// It asks the bar for all the room it has, so its frame holds still while
/// one name rolls into the next, and places the text itself at the leading
/// edge of that room, right beside the item that opens the sidebar, cut
/// short with an ellipsis when it does not fit.
///
/// A name longer than that one line is carried on two, in a smaller face,
/// kept to the leading edge as the one line is, and cut with an ellipsis
/// after the second: the length a name is shown at is the bar's, not the
/// name's.
final class ChatTitleView: UIView {
    private let label = LTXAnimatableLabel()
    private(set) var title = ""
    /// Whether the change waiting for the next layout pass rolls in.
    private var animatesNextChange = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // sized by the bar from `intrinsicContentSize`, not by its frame
        translatesAutoresizingMaskIntoConstraints = false
        label.animator = LTXNumericTransitionAnimator()
        label.animationPolicy = LTXNumericTransitionAnimator.policy
        label.isSelectable = false
        label.backgroundColor = .clear
        addSubview(label)

        isAccessibilityElement = true
        accessibilityTraits = .header
        // the bar's own title is shown larger on a long press at the
        // largest text sizes; so is this one
        showsLargeContentViewer = true
        addInteraction(UILargeContentViewerInteraction())
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// Shows `title`, rolling the old one out when `animated` and the label
    /// is on screen.
    func setTitle(_ title: String, animated: Bool) {
        guard title != self.title else { return }
        self.title = title
        accessibilityLabel = title
        largeContentTitle = title
        animatesNextChange = animated
        setNeedsLayout()
    }

    /// The bar's inline title: headline at the default text size, which the
    /// bar keeps at every size.
    private static var font: UIFont {
        UIFont.preferredFont(
            forTextStyle: .headline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large),
        )
    }

    /// The face a name too long for one line is carried on: a step down from
    /// the bar's own, so two of its lines still sit inside the bar.
    private static var twoLineFont: UIFont {
        UIFont.systemFont(ofSize: 13, weight: .semibold)
    }

    private static var oneLineHeight: CGFloat {
        ceil(font.lineHeight)
    }

    private static var twoLineHeight: CGFloat {
        ceil(twoLineFont.lineHeight) * 2
    }

    /// As wide as the bar allows, which narrows it to the room between its
    /// items; as tall as the two lines a long name takes, so the bar holds
    /// that room for every name and never moves as one name replaces
    /// another.
    override var intrinsicContentSize: CGSize {
        CGSize(width: 10000, height: max(Self.oneLineHeight, Self.twoLineHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let room = bounds.width
        let twoLines = room > 0 && Self.width(of: title, font: Self.font) > room
        let lineHeight = ceil((twoLines ? Self.twoLineFont : Self.font).lineHeight)
        let textHeight = twoLines ? lineHeight * 2 : lineHeight
        let box = textFrame(width: room, height: textHeight)
        label.frame = box
        let attributed = attributedTitle(twoLines: twoLines, room: room, box: box)
        let animated = animatesNextChange
        animatesNextChange = false
        guard !attributed.isEqual(to: label.attributedText) else { return }
        // a change of room alone moves or cuts the text at once
        label.setAttributedText(attributed, animated: animated)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    // MARK: - Text

    /// `title` as it is drawn: one line, fitted to the room and starting at
    /// its leading edge, or two smaller lines kept to that edge.
    private func attributedTitle(twoLines: Bool, room: CGFloat, box: CGRect) -> NSAttributedString {
        guard twoLines else {
            return NSAttributedString(string: fittedText(width: room), attributes: Self.attributes)
        }
        let text = Self.fitted(twoLine: title, width: box.width, height: box.height)
        return NSAttributedString(string: Self.isolated(text), attributes: Self.twoLineAttributes)
    }

    /// `text` between a first-strong isolate and its end: laid out in the
    /// direction of its own first letter inside the left-to-right line it
    /// starts on, so an Arabic name reads right to left as a whole and its
    /// ellipsis lands on its left. The marks take no room.
    private static func isolated(_ text: String) -> String {
        "\u{2068}" + text + "\u{2069}"
    }

    /// The title, or as much of it as fits with an ellipsis after it, set
    /// in its own direction (`isolated`).
    private func fittedText(width: CGFloat) -> String {
        guard width > 0, Self.width(of: title) > width else { return Self.isolated(title) }
        let characters = Array(title)
        var low = 0
        var high = characters.count
        // the longest prefix that fits with its ellipsis
        while low < high {
            let middle = (low + high + 1) / 2
            if Self.width(of: Self.truncated(characters, to: middle)) <= width {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return Self.truncated(characters, to: low)
    }

    private static func truncated(_ characters: [Character], to count: Int) -> String {
        isolated(truncatedRaw(characters, to: count))
    }

    /// The first `count` characters with an ellipsis after them, before the
    /// isolate the line is drawn in.
    private static func truncatedRaw(_ characters: [Character], to count: Int) -> String {
        String(characters.prefix(count)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `title`, or as much of it as the two smaller lines hold with an
    /// ellipsis after it, so a name is never cut without saying so.
    private static func fitted(twoLine title: String, width: CGFloat, height: CGFloat) -> String {
        guard width > 0, height > 0 else { return "" }
        guard !holdsOnTwoLines(title, width: width, height: height) else { return title }
        let characters = Array(title)
        var low = 0
        var high = characters.count
        // the longest prefix that fits with its ellipsis
        while low < high {
            let middle = (low + high + 1) / 2
            if holdsOnTwoLines(truncatedRaw(characters, to: middle), width: width, height: height) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return truncatedRaw(characters, to: low)
    }

    /// Whether `text` typesets no taller than `height` in `width`: the room
    /// the two smaller lines are given.
    private static func holdsOnTwoLines(_ text: String, width: CGFloat, height: CGFloat) -> Bool {
        let string = NSAttributedString(string: isolated(text), attributes: twoLineAttributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil,
        )
        return size.height <= height + 0.5
    }

    // MARK: - Placement

    /// Where the label goes: all of the bar's room the view was given, at
    /// the text's own height about the middle of it, so a name on one line
    /// and on two both start at the same leading edge.
    private func textFrame(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: 0, y: floor((bounds.height - height) / 2), width: width, height: height)
    }

    // MARK: - Attributes

    private static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        // placed from the leading edge whatever the script: the text is
        // measured there, and one line in either direction fits it
        paragraph.alignment = .left
        paragraph.baseWritingDirection = .leftToRight
        paragraph.lineBreakMode = .byClipping
        return [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
    }

    /// Two lines of the smaller face, each starting at the same edge, broken
    /// where they must be: the text handed here is already cut to the room.
    private static var twoLineAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.baseWritingDirection = .leftToRight
        paragraph.lineBreakMode = .byCharWrapping
        return [
            .font: twoLineFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
    }

    /// The width CoreText, which draws the label, gives `text` on one line.
    private static func width(of text: String, font: UIFont) -> CGFloat {
        var textAttributes = attributes
        textAttributes[.font] = font
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: textAttributes),
        )
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    private static func width(of text: String) -> CGFloat {
        width(of: text, font: font)
    }
}
