import struct ApelinProtocol.AgentQuestion
import struct ApelinProtocol.AgentQuestionAnswer
import enum ApelinProtocol.AgentQuestionRules
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI

/// `apelin_question_ask` (2026-11-05): a question the call waits on, asked
/// through the approval gate as `detail.question`, so it waits as an
/// approval does — through a closed app, a reconnect, the host's banner —
/// and a stop ends it as one. The answer is the call's result.
enum UserQuestions {
    /// The question the arguments ask, plain and within the rules, or why
    /// not, in words the model can act on.
    static func question(_ arguments: JSONValue) throws -> AgentQuestion {
        guard let question = plain(arguments.argString("question")) else {
            throw ToolArgumentError("question is empty: ask it in a sentence or two, in the user's language")
        }
        guard question.count <= AgentQuestionRules.maximumQuestionLength else {
            throw ToolArgumentError("question is \(question.count) characters; keep it to \(AgentQuestionRules.maximumQuestionLength) and put what explains it in your message before the call")
        }
        guard case let .object(object) = arguments, case let .array(entries)? = object["options"] else {
            throw ToolArgumentError("options is a list of \(AgentQuestionRules.minimumOptions) to \(AgentQuestionRules.maximumOptions) objects, each with a label")
        }
        guard (AgentQuestionRules.minimumOptions ... AgentQuestionRules.maximumOptions).contains(entries.count) else {
            throw ToolArgumentError("options has \(entries.count); give \(AgentQuestionRules.minimumOptions) to \(AgentQuestionRules.maximumOptions). Other is added by Apelin: do not list it. A question with no options to offer goes in your reply.")
        }
        var options: [AgentQuestion.Option] = []
        var seen: Set<String> = []
        for entry in entries {
            guard let label = plain(entry.argString("label")) else {
                throw ToolArgumentError("Every option needs a label.")
            }
            guard label.count <= AgentQuestionRules.maximumLabelLength else {
                throw ToolArgumentError("The label \"\(label.prefix(20))…\" is \(label.count) characters; keep each to \(AgentQuestionRules.maximumLabelLength) and put the rest in its detail.")
            }
            guard seen.insert(label.lowercased()).inserted else {
                throw ToolArgumentError("Two options are labelled \"\(label)\"; give each a label of its own.")
            }
            let detail = plain(entry.argString("detail"))
            if let detail, detail.count > AgentQuestionRules.maximumDetailLength {
                throw ToolArgumentError("The detail of \"\(label)\" is \(detail.count) characters; keep it to \(AgentQuestionRules.maximumDetailLength), one line.")
            }
            options.append(AgentQuestion.Option(label: label, detail: detail))
        }
        return AgentQuestion(question: question, options: options, multiple: arguments.argBool("multiple") ?? false)
    }

    /// What the model reads once the reader answered.
    static func answered(_ answer: AgentQuestionAnswer) -> String {
        var lines: [String] = []
        if !answer.selected.isEmpty {
            lines.append("The user chose " + answer.selected.map { "\"\($0)\"" }.joined(separator: ", ") + ".")
        }
        let other = answer.other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !other.isEmpty {
            lines.append("The user wrote their own answer:\n\(other)")
        }
        lines.append("Go on from their answer. It answers this question only: it is not consent to a step that needs the user's explicit consent in their reply.")
        return lines.joined(separator: "\n\n")
    }

    /// What the model reads when the reader skipped the question.
    static let skipped = "The user skipped the question without answering. Do not ask it again now: go on with an assumption you state in your reply, or ask in your reply if you cannot."

    /// One line, as a card shows it: runs of white space one space, control
    /// characters and bidirectional overrides out. Nil when nothing is left.
    static func plain(_ text: String?) -> String? {
        guard let text else { return nil }
        var line = String.UnicodeScalarView()
        var space = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                space = !line.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .control || bidirectionalControls.contains(scalar.value) {
                continue
            }
            if space {
                line.append(" ")
                space = false
            }
            line.append(scalar)
        }
        return line.isEmpty ? nil : String(line)
    }

    private static let bidirectionalControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
    ]
}

extension ToolRunner {
    /// Asks the question and waits for the reader: their answer, or that
    /// they skipped it. A stop while it waits ends the call as a stop.
    func askQuestion(
        _ arguments: JSONValue,
        toolCallID: String,
        cancellation: CancellationHandle?,
    ) async throws -> AgentToolResult {
        let question = try UserQuestions.question(arguments)
        let name = AgentToolName.questionAsk.rawValue
        let request = ApprovalRequest(
            id: UUID().uuidString,
            toolCallID: toolCallID,
            tool: name,
            arguments: arguments.canonicalJSON,
            workingDirectory: ".",
            projectID: project.id,
            fingerprint: ApprovalFingerprint.make(
                tool: name,
                arguments: arguments,
                workingDirectory: ".",
                projectID: project.id,
                digest: nil,
            ),
            // what the host's banner says while Apelin is not in front
            reason: question.question,
            detail: .question(question),
            allowsSessionScope: false,
        )
        let answer = await gate.ask(request, cancellation: cancellation)
        try cancellation?.throwIfCancelled()
        try Task.checkCancellation()
        guard let answer else {
            journal?.note(ToolCallOutcome(.denied, "the user skipped the question"), for: toolCallID)
            return AgentToolResult(content: [.text(TextContent(text: UserQuestions.skipped))])
        }
        return AgentToolResult(content: [.text(TextContent(text: UserQuestions.answered(answer)))])
    }
}
