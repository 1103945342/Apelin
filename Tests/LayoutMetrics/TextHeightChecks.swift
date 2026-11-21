import UIKit

/// The one assumption behind the transcript's Core Text measure: the height
/// `CTFramesetterSuggestFrameSizeWithConstraints` gives a block of text is the
/// height a `UILabel` draws it at, at the same width, font and attributes.
/// If the two disagree, an opened call would be clipped or padded — the row
/// height comes from Core Text now, and the label fills it.
///
/// Device: `bash Scripts/test-text-height.sh --device <tool.entitlements>`.
@main
struct TextHeightChecks {
    static func main() {
        var checks = 0
        let widths: [CGFloat] = [280, 320, 375, 430]
        let lengths = [1, 2, 7, 40, 200]

        let fonts: [(String, UIFont)] = [
            ("block", TraceBodyFonts.block),
            ("value", UIFont.preferredFont(forTextStyle: .subheadline)),
        ]
        for (name, font) in fonts {
            for width in widths {
                for lines in lengths {
                    let text = String(
                        repeating: "the quick brown fox jumps over the lazy dog 0123456789\n",
                        count: lines,
                    )
                    let attributed = NSAttributedString(string: text, attributes: [.font: font])
                    let label = UILabel()
                    label.numberOfLines = 0
                    label.attributedText = attributed
                    let drawn = label.sizeThatFits(
                        CGSize(width: width, height: .greatestFiniteMagnitude),
                    ).height
                    let measured = height(of: attributed, width: width)
                    let tolerance = max(1, font.lineHeight * 0.05)
                    guard abs(drawn - measured) <= tolerance else {
                        FileHandle.standardError.write(Data("""
                        FAILED: \(name) font, width \(Int(width)), \(lines) lines: \
                        label says \(drawn), Core Text says \(measured)

                        """.utf8))
                        exit(1)
                    }
                    checks += 1
                }
            }
        }
        print("\(checks) text height checks passed")
    }

    /// The measure `ToolCallSectionView` uses, kept identical to it here.
    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil,
        ).height
    }
}

/// The transcript's block face, as `TraceBody.Style.blockFont` builds it.
enum TraceBodyFonts {
    static var block: UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: 12, weight: .regular),
        )
    }
}
