import ListViewKit
import UIKit

/// A message another conversation's agent sent this one, or the host's report
/// about one: one quiet line naming the conversation and what it began with,
/// never a bubble of the reader's own. Tapping it opens the whole message
/// (`ChatCooperationController`); the text stays out of the chat window.
final class ChatCooperationRow: ListRowView {
    @objc dynamic var onOpen: (() -> Void)?
    private let icon = UIImageView(image: UIImage(systemName: "bubble.left.and.bubble.right"))
    private let label = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.forward"))
    private var opensText = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(icon)

        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = true
        addSubview(label)

        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(chevron)

        isAccessibilityElement = true
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(open)))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ message: ChatMessage) {
        let sender = message.sender ?? String(localized: "From another chat")
        let preview = message.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let text = NSMutableAttributedString(
            string: sender,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .subheadline),
                .foregroundColor: UIColor.label,
            ]
        )
        if !preview.isEmpty {
            text.append(NSAttributedString(
                string: " — " + preview,
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .subheadline),
                    .foregroundColor: UIColor.secondaryLabel,
                ]
            ))
        }
        label.attributedText = text
        label.adjustsFontForContentSizeCategory = true
        opensText = !message.text.isEmpty
        accessibilityLabel = sender
        accessibilityValue = preview.isEmpty ? nil : preview
        accessibilityHint = opensText ? String(localized: "Opens the message") : nil
        accessibilityTraits = opensText ? .button : .staticText
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onOpen = nil
        opensText = false
        label.attributedText = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let insets = ChatMessageRow.insets(for: bounds.width)
        let side = ChatMessageRow.horizontalPadding
        let glyph: CGFloat = 20
        let content = bounds.inset(by: insets)
        icon.frame = CGRect(
            x: content.minX,
            y: content.midY - glyph / 2,
            width: glyph,
            height: glyph
        )
        chevron.frame = CGRect(
            x: content.maxX - glyph,
            y: content.midY - glyph / 2,
            width: glyph,
            height: glyph
        )
        label.frame = CGRect(
            x: icon.frame.maxX + side / 2,
            y: content.minY,
            width: max(1, chevron.frame.minX - icon.frame.maxX - side),
            height: content.height
        )
    }

    override func accessibilityActivate() -> Bool {
        guard opensText else { return false }
        open()
        return true
    }

    @objc dynamic private func open() {
        guard opensText else { return }
        onOpen?()
    }

    static func height(for _: ChatMessage, width: CGFloat) -> CGFloat {
        let insets = ChatMessageRow.insets(for: width)
        let line = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        return insets.top + ceil(line) + insets.bottom
    }
}
