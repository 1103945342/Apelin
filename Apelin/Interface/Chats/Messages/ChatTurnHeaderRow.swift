import ListViewKit
import UIKit

/// The header of a turn, under the message that began it: whether the run is
/// going or done. One per turn, as aimini draws a turn's header — a turn that
/// writes a reply and then works on is one turn, not a finished process, a
/// reply, and a running process after it.
///
/// What the turn is doing is the line under it (the newest call) and the
/// stretches it opens; this says only where the run stands.
final class ChatTurnHeaderRow: ListRowView {
    private let header = ThinkingStatusLabel()
    private static let sizing = UILabel()
    /// Between the message above, the line, and what follows.
    private static let topSpacing: CGFloat = 2
    private static let bottomSpacing: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.isAccessibilityElement = false
        addSubview(header)
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .header]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        header.isThinking = false
        header.animationIdentity = nil
        header.text = nil
        accessibilityLabel = nil
    }

    func show(_ message: ChatMessage) {
        guard case let .turn(running, _) = message.role else { return }
        let title = running ? String(localized: "Running") : String(localized: "Completed")
        header.animationIdentity = message.id
        header.font = .preferredFont(forTextStyle: .subheadline)
        header.text = title
        // While the run goes the line shimmers, as aimini's turn header does;
        // a finished one is drawn flat.
        header.isThinking = running
        accessibilityLabel = title
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = bounds.inset(by: ChatMessageRow.insets(for: bounds.width))
        header.font = .preferredFont(forTextStyle: .subheadline)
        let height = ceil(header.sizeThatFits(
            CGSize(width: max(1, content.width), height: .greatestFiniteMagnitude),
        ).height)
        header.frame = CGRect(
            x: content.minX,
            y: content.minY + Self.topSpacing,
            width: max(1, content.width),
            height: height,
        )
    }

    static func height(for message: ChatMessage, width: CGFloat) -> CGFloat {
        let insets = ChatMessageRow.insets(for: width)
        let textWidth = max(1, width - insets.left - insets.right)
        sizing.font = .preferredFont(forTextStyle: .subheadline)
        sizing.numberOfLines = 1
        sizing.text = "Completed"
        let line = ceil(sizing.sizeThatFits(
            CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        ).height)
        return insets.top + topSpacing + line + bottomSpacing + insets.bottom
    }
}
