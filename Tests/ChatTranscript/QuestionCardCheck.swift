import ApelinCore
import ApelinProtocol
import Foundation

/// An apelin_question_ask card is its question and options, from
/// `detail.question`: the question is its title, the options its body in
/// the transcript, and its trace step says whether it was answered — never
/// the arguments the call named, nor Approve's words.
func checkQuestionCard() {
    let asked: [String: JSONValue] = [
        "approvalID": .string("q1"), "toolCallID": .string("call-q"), "tool": .string("apelin_question_ask"),
        "arguments": .string(#"{"question":"Which design?","options":[{"label":"A"},{"label":"B"}]}"#),
        "reason": .string("Which design?"),
        "detail": .object(["question": .object([
            "question": .string("Which design?"),
            "options": .array([
                .object(["label": .string("Blocking (recommended)"), "detail": .string("The call waits")]),
                .object(["label": .string("End the turn")]),
            ]),
            "multiple": .bool(false),
        ])]),
    ]
    precondition(ApprovalCardText.title(.object(asked)) == "Which design?", "the question is the title")
    let question = ApprovalCardText.question(.object(asked))
    precondition(question?.options.map(\.label) == ["Blocking (recommended)", "End the turn"], "\(String(describing: question))")
    precondition(question?.options.first?.detail == "The call waits" && question?.multiple == false)
    precondition(ApprovalCardText.question(.object(["tool": .string("git_push")])) == nil, "any other card asks nothing")

    let waiting = ChatTranscript(events: [
        event(1, "prompt", ["text": .string("Add the tool")]),
        event(2, "toolCall", ["id": .string("call-q"), "tool": .string("apelin_question_ask"), "arguments": asked["arguments"]!]),
        event(3, "approvalRequested", asked),
    ]) { _ in nil }.messages.first { $0.role.needsApproval }
    precondition(waiting?.question?.question == "Which design?", "the row carries the question")
    precondition(waiting?.approvalTitle == "Which design?")
    precondition(waiting?.approvalDetail == "Blocking (recommended)\nEnd the turn", "\(waiting?.approvalDetail ?? "")")
    precondition(waiting?.approvalSections.isEmpty == true, "no arguments on the card")
    precondition(waiting.map { TraceStep($0).subtitle } == String(localized: "Answer Needed"))

    var answered = waiting
    answered?.role = .approval(.approve)
    precondition(answered.map { TraceStep($0).subtitle } == String(localized: "Answered"))
    answered?.role = .approval(.deny)
    precondition(answered.map { TraceStep($0).subtitle } == String(localized: "Skipped"))
    print("ok: a question's card is its question and options, and its step says whether it was answered")
}
