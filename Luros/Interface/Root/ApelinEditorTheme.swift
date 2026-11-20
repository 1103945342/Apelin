import Runestone
import UIKit

/// The colours the editor draws a file in, taken from the system's own.
///
/// A theme of its own rather than the package's examples: those are fixed
/// light or dark palettes, and a file opened from the sidebar should look
/// like it belongs to the app in either mode. Every colour here is a dynamic
/// one, so the editor follows a change of appearance without being rebuilt.
final class ApelinEditorTheme: Theme {
    let font: UIFont
    let lineNumberFont: UIFont

    init(size: CGFloat = 14) {
        font = .monospacedSystemFont(ofSize: size, weight: .regular)
        lineNumberFont = .monospacedSystemFont(ofSize: max(10, size - 2), weight: .regular)
    }

    var textColor: UIColor { .label }
    var gutterBackgroundColor: UIColor { .secondarySystemBackground }
    var gutterHairlineColor: UIColor { .separator }
    var lineNumberColor: UIColor { .tertiaryLabel }
    var selectedLineBackgroundColor: UIColor { .tertiarySystemFill }
    var selectedLinesLineNumberColor: UIColor { .secondaryLabel }
    var selectedLinesGutterBackgroundColor: UIColor { .secondarySystemBackground }
    var invisibleCharactersColor: UIColor { .quaternaryLabel }
    var pageGuideHairlineColor: UIColor { .separator }
    var pageGuideBackgroundColor: UIColor { .secondarySystemBackground }
    var markedTextBackgroundColor: UIColor { .tertiarySystemFill }

    /// The ground the text view sits on: the page's, not a colour of its
    /// own, so the sheet has no second background inside it.
    var backgroundColor: UIColor { .systemBackground }

    /// A capture name with dots falls back to its prefix, as the package's
    /// own themes do: `string.special.key` reads as `string`.
    func textColor(for rawHighlightName: String) -> UIColor? {
        switch Self.highlightName(rawHighlightName) {
        case .comment: .secondaryLabel
        case .keyword: .systemPink
        case .string: .systemRed
        case .number: .systemOrange
        case .function: .systemBlue
        case .property: .systemTeal
        case .variableBuiltin: .systemPurple
        case .operator, .punctuation: .secondaryLabel
        case nil: nil
        }
    }

    func fontTraits(for rawHighlightName: String) -> FontTraits {
        Self.highlightName(rawHighlightName) == .keyword ? .bold : []
    }

    private enum HighlightName {
        case comment, function, keyword, number, `operator`, property, punctuation
        case string, variableBuiltin

        init?(_ raw: String) {
            var components = raw.split(separator: ".")
            while !components.isEmpty {
                switch components.joined(separator: ".") {
                case "comment": self = .comment
                case "function": self = .function
                case "keyword": self = .keyword
                case "number": self = .number
                case "operator": self = .operator
                case "property": self = .property
                case "punctuation": self = .punctuation
                case "string": self = .string
                case "variable.builtin": self = .variableBuiltin
                default:
                    components.removeLast()
                    continue
                }
                return
            }
            return nil
        }
    }

    private static func highlightName(_ raw: String) -> HighlightName? {
        HighlightName(raw)
    }
}
