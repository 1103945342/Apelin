import Foundation

/// A question the agent asks the reader and waits on (`apelin_question_ask`,
/// 2026-11-05): a few options to pick from, or an answer of their own.
///
/// It rides the approval path rather than an operation of its own: the
/// call's `approvalRequested` carries it as `detail.question`, the app shows
/// it in the approval card's place, and `AgentApproveRequest` brings the
/// reply back, `approve` with `answer` for an answer and `deny` for a
/// question the reader skipped. So a question waits as an approval does —
/// through a closed app, a reconnect and the host's notification — and a
/// stop or a new process ends it as one.
///
/// The answer goes to the model as the call's result. It is never consent to
/// a step the agent is told needs explicit consent in the reader's reply.
public struct AgentQuestion: Sendable, Hashable, Codable {
    public struct Option: Sendable, Hashable, Codable {
        /// What the button says, and what the model reads back.
        public var label: String
        /// One line under the label: what choosing it means.
        public var detail: String?
        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    public var question: String
    public var options: [Option]
    /// Several options may be chosen at once.
    public var multiple: Bool

    public init(question: String, options: [Option], multiple: Bool = false) {
        self.question = question
        self.options = options
        self.multiple = multiple
    }
}

/// The reader's reply to an `AgentQuestion`: the labels they chose, in the
/// question's order, and what they wrote themselves under Other.
public struct AgentQuestionAnswer: Sendable, Hashable, Codable {
    public var selected: [String]
    public var other: String?
    public init(selected: [String] = [], other: String? = nil) {
        self.selected = selected
        self.other = other
    }
}

public enum AgentQuestionRules {
    /// The key of `detail` in the call's `approvalRequested`.
    public static let detailKey = "question"
    public static let maximumQuestionLength = 300
    public static let minimumOptions = 2
    public static let maximumOptions = 4
    public static let maximumLabelLength = 60
    public static let maximumDetailLength = 160
    /// What the reader may write under Other.
    public static let maximumOtherLength = 2000

    /// Whether `answer` answers `question`: every label one of its options,
    /// each once; something chosen or written; and, for a question that
    /// takes one option, one option or an answer of their own, not both.
    public static func accepts(_ answer: AgentQuestionAnswer, for question: AgentQuestion) -> Bool {
        let labels = Set(question.options.map(\.label))
        guard Set(answer.selected).count == answer.selected.count,
              answer.selected.allSatisfy(labels.contains)
        else { return false }
        let other = answer.other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard other.count <= maximumOtherLength else { return false }
        let given = answer.selected.count + (other.isEmpty ? 0 : 1)
        return question.multiple ? given >= 1 : given == 1
    }

    /// `answer` as `question` takes it, so a card sends what the gate will
    /// keep: labels that are not its options and repeats of one go, Other is
    /// cut to its limit, and a question that takes one option ends with one
    /// of the two — what the reader wrote standing in place of the option
    /// they had tapped, since a card reaches both (tap an option, then
    /// Other…) and `accepts` refuses that. Nothing is invented: an answer
    /// with neither still has neither.
    public static func fitting(_ answer: AgentQuestionAnswer, to question: AgentQuestion) -> AgentQuestionAnswer {
        let labels = Set(question.options.map(\.label))
        var seen: Set<String> = []
        var selected = answer.selected.filter { labels.contains($0) && seen.insert($0).inserted }
        let written = answer.other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let other = String(written.prefix(maximumOtherLength))
        if !question.multiple {
            if !other.isEmpty {
                selected = []
            } else {
                selected = Array(selected.prefix(1))
            }
        }
        return AgentQuestionAnswer(selected: selected, other: other.isEmpty ? nil : other)
    }
}
