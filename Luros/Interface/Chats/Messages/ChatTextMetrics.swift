import UIKit

/// How tall a run of text is at a width, answered by TextKit instead of by a
/// label being laid out. A row's height is fitted on every pass of the list
/// and on every token of a running turn; asking a label for the same number
/// means laying the whole text out each time, which is what made an opened
/// thought or result stutter while the run went on.
///
/// `boundingRect` with `.usesLineFragmentOrigin` is the height a multi-line
/// label takes; `Scripts/test-text-height.sh` holds it to a label's own
/// answer on the device, in both faces the transcript draws with.
@MainActor
enum ChatTextMetrics {
    static func height(of text: String, font: UIFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 1 else { return 0 }
        return height(
            of: NSAttributedString(string: text, attributes: [.font: font]),
            width: width,
        )
    }

    static func height(of text: NSAttributedString?, width: CGFloat) -> CGFloat {
        guard let text, text.length > 0, width > 1 else { return 0 }
        return ceil(text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil,
        ).height)
    }
}
