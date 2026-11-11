import ApelinCore
import Foundation

/// A call as its trace row shows it: each argument by name with its value
/// under it, then the call's result. The arguments arrive as one line of
/// JSON, where a file's content is a single string full of `\n` and `\"`;
/// decoded, a string reads as itself, line breaks and all, and anything
/// else as compact JSON. Arguments that are not a JSON object show as they
/// came.
struct ToolCallDetail: Equatable {
    struct Section: Equatable {
        /// An argument's name, or "Result"; nil for arguments shown as they came.
        let name: String?
        let value: String
        /// The call's own result rather than one of its arguments.
        let isResult: Bool

        /// How the value is drawn. A call's arguments are not all the same
        /// thing: a path deserves a monospaced line, a file's content deserves
        /// a code block, and a diff deserves its own colours.
        enum Kind: Equatable {
            /// Prose: a reason, a short answer.
            case text
            /// Where something lives.
            case path
            /// What was run.
            case command
            /// Several lines of something, drawn monospaced.
            case code
            /// Added and removed lines, each in the colour it means.
            case diff
            /// What the call answered.
            case result
        }

        /// The argument names that hold a place rather than a sentence.
        private static let pathNames: Set<String> = [
            "path", "file", "files", "url", "target", "source", "destination",
            "directory", "project", "root", "cwd",
        ]
        private static let commandNames: Set<String> = ["argv", "command", "cmd"]

        var kind: Kind {
            if isResult { return looksLikeDiff ? .diff : .result }
            if looksLikeDiff { return .diff }
            guard let name else { return value.contains("\n") ? .code : .text }
            if Self.commandNames.contains(name) { return .command }
            if Self.pathNames.contains(name), !value.contains("\n") { return .path }
            return value.contains("\n") ? .code : .text
        }

        /// A unified diff, as git writes one: the header lines are what tell
        /// it apart from a file that happens to start with a minus.
        private var looksLikeDiff: Bool {
            guard value.contains("\n") else { return false }
            return value.contains("\n@@ ") || value.hasPrefix("@@ ")
                || value.contains("\n+++ ") || value.contains("\ndiff --git ")
        }
    }

    let sections: [Section]
    /// The file the call names, from its `path` argument.
    let path: String?
    /// What the call answered: the text after its arguments, as it was
    /// written, with the escape sequences a terminal colours itself with
    /// taken out.
    let result: String?

    /// `detail`: a tool row's, the arguments' JSON and, after a blank line,
    /// the result. `title`: the row's; a `reason` that only repeats it is
    /// left out.
    init(detail: String, title: String) {
        let separator = detail.range(of: "\n\n")
        let head = separator.map { String(detail[..<$0.lowerBound]) } ?? detail
        let answer = separator.map { Self.plain(String(detail[separator.upperBound...])) }
        let decoded = head.isEmpty ? JSONValue.object([:]) : try? JSONCoding.decode(JSONValue.self, from: Data(head.utf8))
        guard case let .object(values)? = decoded else {
            path = nil
            result = nil
            sections = detail.isEmpty ? [] : [Section(name: nil, value: Self.plain(detail), isResult: false)]
            return
        }
        path = values["path"]?.stringValue
        result = answer?.isEmpty == false ? answer : nil
        var sections = values
            .filter { name, value in !(name == "reason" && value.stringValue == title) }
            .map { name, value in Section(name: name, value: Self.text(of: value, named: name), isResult: false) }
            .sorted(by: Self.precedes)
        if let separator, !detail[separator.upperBound...].isEmpty {
            sections.append(Section(
                name: String(localized: "Result"),
                value: answer ?? "",
                isResult: true,
            ))
        }
        self.sections = sections
    }

    /// Everything as one plain text: what VoiceOver reads.
    var text: String {
        sections.map { section in section.name.map { $0 + "\n" + section.value } ?? section.value }
            .joined(separator: "\n\n")
    }

    /// A string as itself, anything else as compact JSON; a command's
    /// arguments, which come as an array, as the line they run.
    private static func text(of value: JSONValue, named name: String) -> String {
        if let string = value.stringValue {
            return string
        }
        if name == "argv", case let .array(words) = value {
            let parts = words.compactMap(\.stringValue)
            if parts.count == words.count {
                return CommandLineText.quoted(parts)
            }
        }
        return (try? JSONCoding.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// What a command wrote, without the escape sequences that told a
    /// terminal how to colour it: a result pasted here keeps its words and
    /// its lines, never `\u{1B}[31m` in the middle of them.
    private static func plain(_ text: String) -> String {
        guard text.utf8.contains(0x1B) else { return text }
        var result = text.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
            with: "",
            options: .regularExpression,
        )
        result = result.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression,
        )
        return result.replacingOccurrences(of: "\u{1B}", with: "")
    }

    /// The reason first, then the values that fit on a line, then the long
    /// ones, such as a file's content; by name within each.
    private static func precedes(_ first: Section, _ second: Section) -> Bool {
        func rank(_ section: Section) -> Int {
            if section.name == "reason" {
                return 0
            }
            return section.value.contains("\n") ? 2 : 1
        }
        let ranks = (rank(first), rank(second))
        return ranks.0 == ranks.1 ? (first.name ?? "") < (second.name ?? "") : ranks.0 < ranks.1
    }
}
