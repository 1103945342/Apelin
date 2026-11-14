import Foundation

/// An approval — or one of the agent's questions (`AgentQuestion`) — carried
/// into WeChat (2026-11-15).
///
/// The app answers both with `agentApprove`; a channel user answers with a
/// message, so this is what reads one: the words that mean yes and no, and
/// the numbers that pick a question's options. Everything here is text the
/// far side shows a person, so it is not the app's string catalog: the three
/// languages the ask is written in are the ones a message can reasonably be
/// read in, and anything else falls back to English.
public struct ChannelAsk: Sendable, Equatable {
    public var approvalID: String
    public var sessionID: String
    /// The tool the call names (`shell_run`, `gitPush`), when it named one.
    public var tool: String?
    /// The question, when the request is one rather than an approval.
    public var question: AgentQuestion?
    /// A `shell_run` as root needs the device owner's check (Face ID, Touch
    /// ID or the passcode, `ownerVerified`), which a chat message cannot
    /// give: the channel announces it and only Apelin can approve it.
    public var needsAppToApprove: Bool
    /// What was sent to WeChat, kept so a reply is read against the same ask.
    public var text: String

    public init(
        approvalID: String,
        sessionID: String,
        tool: String? = nil,
        question: AgentQuestion? = nil,
        needsAppToApprove: Bool = false,
        text: String
    ) {
        self.approvalID = approvalID
        self.sessionID = sessionID
        self.tool = tool
        self.question = question
        self.needsAppToApprove = needsAppToApprove
        self.text = text
    }
}

/// What a message means as an answer to an ask.
public struct ChannelAnswer: Sendable, Equatable {
    public var approved: Bool
    /// The labels chosen (or what was written) for a question; nil for an
    /// approval, and for a question the reader skipped.
    public var answer: AgentQuestionAnswer?

    public init(approved: Bool, answer: AgentQuestionAnswer? = nil) {
        self.approved = approved
        self.answer = answer
    }
}

public enum ChannelReplies {
    public enum Reading: Equatable {
        case answer(ChannelAnswer)
        /// An approval only Apelin can give: the message is answered with a
        /// word about that, and the ask stays waiting.
        case needsApp
        /// Neither yes, no, nor a choice: the message is a new turn.
        case unclear
    }

    /// A message read as an answer to `ask`.
    ///
    /// A question's numbers win over the words, since its options were sent
    /// numbered; "跳过" and "skip" skip it, which is a deny. Anything else
    /// written under a question is an answer of the reader's own. An
    /// approval takes the yes and no words, and nothing else: a sentence
    /// that merely mentions approving is a new message.
    public static func read(_ text: String, ask: ChannelAsk) -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unclear }
        if let question = ask.question {
            if let selected = selection(in: trimmed, of: question) {
                return .answer(ChannelAnswer(approved: true, answer: selected))
            }
            if skipWords.contains(folded(trimmed)) {
                return .answer(ChannelAnswer(approved: false))
            }
            // A number that is not one of the options is a mistake, not an
            // answer of the reader's own.
            let numbersOnly = trimmed.unicodeScalars.allSatisfy {
                CharacterSet.decimalDigits.union(CharacterSet(charactersIn: " ,，、/;；")).contains($0)
            }
            if numbersOnly {
                return .unclear
            }
            guard !ask.needsAppToApprove else { return .needsApp }
            // Anything else is what the reader wrote under Other.
            let written = String(trimmed.prefix(AgentQuestionRules.maximumOtherLength))
            let answer = AgentQuestionRules.fitting(AgentQuestionAnswer(other: written), to: question)
            guard AgentQuestionRules.accepts(answer, for: question) else { return .unclear }
            return .answer(ChannelAnswer(approved: true, answer: answer))
        }
        let word = folded(trimmed)
        guard yesWords.contains(word) || noWords.contains(word) else { return .unclear }
        guard !ask.needsAppToApprove else { return .needsApp }
        return .answer(ChannelAnswer(approved: yesWords.contains(word)))
    }

    /// The options `text` names by number — "2", "1,3", "1 3", "选项 2" —
    /// fitted to the question; nil when it names none, or when the question
    /// is asked in a language whose numbers are not read here.
    static func selection(in text: String, of question: AgentQuestion) -> AgentQuestionAnswer? {
        let digits = text.compactMap { character -> Int? in
            guard let value = character.wholeNumberValue, (1 ... 9).contains(value) else { return nil }
            return value
        }
        // Only a message that is numbers and separators counts: "3 个文件"
        // is a sentence that mentions a number, not a choice.
        let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: " ,，、/;；"))
        guard text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let chosen = digits.compactMap { number -> String? in
            let index = number - 1
            guard index >= 0, index < question.options.count else { return nil }
            return question.options[index].label
        }
        guard !chosen.isEmpty else { return nil }
        let answer = AgentQuestionRules.fitting(
            AgentQuestionAnswer(selected: chosen),
            to: question
        )
        return AgentQuestionRules.accepts(answer, for: question) ? answer : nil
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    static let yesWords: Set<String> = [
        "同意", "批准", "允許", "允许", "確認", "确认", "好", "好的", "可以", "行", "是", "是的",
        "yes", "y", "ok", "okay", "approve", "approved", "allow", "accept",
    ]

    static let noWords: Set<String> = [
        "拒絕", "拒绝", "不同意", "不批准", "不行", "不可以", "不要", "不", "否", "取消",
        "no", "n", "deny", "reject", "cancel", "stop",
    ]

    static let skipWords: Set<String> = [
        "跳過", "跳过", "不回答", "取消", "skip", "cancel", "pass",
    ]

    // MARK: What WeChat is shown

    /// The ask as one WeChat message: a question with its numbered options,
    /// or what the approval is for and how to answer it.
    public static func text(
        for request: ChannelAsk,
        reason: String? = nil,
        arguments: String? = nil,
        language: String = ChannelReplies.language
    ) -> String {
        let words = Wording(language: language)
        var lines: [String] = []
        if let question = request.question {
            lines.append(question.question)
            lines.append("")
            for (index, option) in question.options.enumerated() {
                var line = "\(index + 1). \(option.label)"
                if let detail = option.detail, !detail.isEmpty {
                    line += " — " + detail
                }
                lines.append(line)
            }
            lines.append("")
            lines.append(question.multiple ? words.pickSeveral : words.pickOne)
        } else {
            lines.append(words.needsApproval)
            lines.append("")
            if let tool = request.tool, !tool.isEmpty {
                lines.append(tool)
            }
            if let reason, !reason.isEmpty {
                lines.append(reason)
            }
            if let arguments, !arguments.isEmpty {
                lines.append("")
                lines.append(cut(arguments, at: 400))
            }
            lines.append("")
            lines.append(words.answerApproval)
        }
        if request.needsAppToApprove {
            lines.append("")
            lines.append(words.onlyInApp)
        }
        return lines.joined(separator: "\n")
    }

    /// What a channel says once a decision is taken there. A question the
    /// reader skipped is a deny with no answer; the skipped word says so.
    public static func acknowledged(
        _ answer: ChannelAnswer,
        wasQuestion: Bool,
        language: String = ChannelReplies.language
    ) -> String {
        let words = Wording(language: language)
        if answer.approved {
            return words.approved
        }
        return wasQuestion && answer.answer == nil ? words.skipped : words.denied
    }

    /// The line a message that only Apelin can settle is answered with.
    public static func onlyInApp(language: String = ChannelReplies.language) -> String {
        Wording(language: language).onlyInApp
    }

    /// The phone's own language, as the three the asks are written in; the
    /// app and the host are on the same device, so this is the reader's.
    public static var language: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") {
            return "zh-Hant"
        }
        if preferred.hasPrefix("zh") {
            return "zh-Hans"
        }
        return "en"
    }

    private static func cut(_ text: String, at limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    struct Wording {
        var needsApproval: String
        var answerApproval: String
        var onlyInApp: String
        var approved: String
        var denied: String
        var skipped: String
        var pickOne: String
        var pickSeveral: String
        var isQuestion = false

        init(language: String) {
            switch language {
            case "zh-Hans":
                needsApproval = "Apelin 需要你批准这一步。"
                answerApproval = "回复「同意」批准，「拒绝」不批准。"
                onlyInApp = "这一条需要在 Apelin 里确认，在微信里的回复不会生效。"
                approved = "已批准。"
                denied = "已拒绝。"
                skipped = "已跳过。"
                pickOne = "回复序号，或直接写你的答案。"
                pickSeveral = "回复序号（可多选，用逗号分开），或直接写你的答案。"
                isQuestion = true
            case "zh-Hant":
                needsApproval = "Apelin 需要你核准這一步。"
                answerApproval = "回覆「同意」核准，「拒絕」不核准。"
                onlyInApp = "這一項需要在 Apelin 裡確認，在微信裡的回覆不會生效。"
                approved = "已核准。"
                denied = "已拒絕。"
                skipped = "已略過。"
                pickOne = "回覆序號，或直接寫你的答案。"
                pickSeveral = "回覆序號（可多選，用逗號分開），或直接寫你的答案。"
                isQuestion = true
            default:
                needsApproval = "Apelin needs your approval for this step."
                answerApproval = "Reply approve to allow it, or deny to refuse it."
                onlyInApp = "This one is approved in Apelin: a reply here does not count."
                approved = "Approved."
                denied = "Denied."
                skipped = "Skipped."
                pickOne = "Reply with a number, or write your own answer."
                pickSeveral = "Reply with numbers (comma-separated for several), or write your own answer."
                isQuestion = true
            }
        }
    }
}
