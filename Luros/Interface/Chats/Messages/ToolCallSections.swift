import ApelinCore
import ApelinProtocol
import Foundation

/// What a call opens into, by the tool it is:
///
/// - a file tool that writes one is shown as what it changed under the
///   file's own name — the diff an edit answered with, and for a write or a
///   create, whose result only counts the file, the content it was handed;
/// - a file read is shown as what it read, under the file's name;
/// - anything else shows its arguments and its result.
///
/// The reason is never among them: the line above already says why the call
/// was made, and repeating it under the line only pushes the answer down.
enum ToolCallSections {
    static func sections(of step: ChatMessage) -> [ToolCallDetail.Section] {
        let detail = ToolCallDetail(detail: step.detail, title: step.text)
        let file = detail.path.map { ($0 as NSString).lastPathComponent } ?? ""
        func named(_ value: String) -> ToolCallDetail.Section {
            ToolCallDetail.Section(name: file.isEmpty ? nil : file, value: value, isResult: true)
        }
        guard let tool = step.tool.flatMap(AgentToolName.canonical) else {
            return detail.sections.filter { $0.name != "reason" }
        }
        if ToolCallBanner.fileTools.contains(tool) {
            // "Patched Tweak.x (1 replacement, +3 -1)", then the diff.
            if let result = detail.result, let diff = afterFirstLine(result) {
                return [named(diff)]
            }
            // A write or a create answers with one line counting the file and
            // no diff: what it wrote is the content its arguments carry, and
            // that is what opening the call shows.
            if let content = content(of: detail), !content.isEmpty {
                return [named(content)]
            }
            return []
        }
        if tool == .fileRead {
            guard let result = detail.result, !result.isEmpty else { return [] }
            return [named(withoutLineNumbers(result))]
        }
        return detail.sections.filter { $0.name != "reason" }
    }

    /// The `content` a write or a create was given.
    private static func content(of detail: ToolCallDetail) -> String? {
        detail.sections.first { $0.name == "content" }?.value
    }

    /// What a call answered past the line that counts it: a file tool's
    /// result opens with "Patched Tweak.x (1 replacement, +3 -1)" and the
    /// diff follows.
    private static func afterFirstLine(_ result: String) -> String? {
        guard let line = result.firstIndex(of: "\n") else { return nil }
        let rest = String(result[result.index(after: line)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// A file's text without the line numbers `file_read` puts in front of
    /// every line: what the reader wants of it is the file.
    private static func withoutLineNumbers(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let tab = line.firstIndex(of: "\t"), tab > line.startIndex,
                  line[..<tab].allSatisfy(\.isNumber)
            else { return String(line) }
            return String(line[tab...].dropFirst())
        }.joined(separator: "\n")
    }
}
