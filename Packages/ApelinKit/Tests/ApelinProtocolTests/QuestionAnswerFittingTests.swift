import ApelinProtocol
import XCTest

/// The card can reach answers its own question does not take — an option
/// tapped and then Other… written — and `fitting` is what it sends instead.
final class QuestionAnswerFittingTests: XCTestCase {
    private let one = AgentQuestion(question: "Which?", options: [.init(label: "A"), .init(label: "B")])
    private let several = AgentQuestion(
        question: "Which?",
        options: [.init(label: "A"), .init(label: "B")],
        multiple: true
    )

    func testAWrittenAnswerStandsInPlaceOfTheOptionTapped() {
        let answer = AgentQuestionRules.fitting(
            AgentQuestionAnswer(selected: ["A"], other: "Neither: a sheet"),
            to: one
        )
        XCTAssertEqual(answer.selected, [], "one option is one answer: what was written is it")
        XCTAssertEqual(answer.other, "Neither: a sheet")
        XCTAssertTrue(AgentQuestionRules.accepts(answer, for: one))
    }

    func testAQuestionThatTakesSeveralKeepsTheOptionsAndTheWords() {
        let answer = AgentQuestionRules.fitting(AgentQuestionAnswer(selected: ["A"], other: "and C"), to: several)
        XCTAssertEqual(answer.selected, ["A"])
        XCTAssertEqual(answer.other, "and C")
        XCTAssertTrue(AgentQuestionRules.accepts(answer, for: several))
    }

    func testWhatIsNotAnAnswerToTheQuestionGoes() {
        let labels = AgentQuestionRules.fitting(AgentQuestionAnswer(selected: ["A", "Z", "A", "B"]), to: one)
        XCTAssertEqual(labels.selected, ["A"], "only the question's labels, each once, and one of them")
        XCTAssertNil(labels.other)
        XCTAssertTrue(AgentQuestionRules.accepts(labels, for: one))
        let spaces = AgentQuestionRules.fitting(AgentQuestionAnswer(other: "  B  "), to: one)
        XCTAssertEqual(spaces.other, "B")
        XCTAssertEqual(spaces.selected, [])
        XCTAssertTrue(AgentQuestionRules.accepts(spaces, for: one))
    }

    func testOtherIsCutToWhatTheGateTakes() {
        let long = String(repeating: "x", count: AgentQuestionRules.maximumOtherLength + 40)
        let answer = AgentQuestionRules.fitting(AgentQuestionAnswer(other: long), to: one)
        XCTAssertEqual(answer.other?.count, AgentQuestionRules.maximumOtherLength)
        XCTAssertTrue(AgentQuestionRules.accepts(answer, for: one))
    }

    func testNothingIsInvented() {
        XCTAssertEqual(AgentQuestionRules.fitting(AgentQuestionAnswer(), to: one), AgentQuestionAnswer())
        XCTAssertEqual(
            AgentQuestionRules.fitting(AgentQuestionAnswer(selected: ["A"]), to: one),
            AgentQuestionAnswer(selected: ["A"]),
            "an answer that already fits goes through as it is"
        )
    }

    /// Every answer a card can build passes the gate, and one that gives
    /// nothing is the only one it refuses: the card waits on Confirm for
    /// that, and Other… sends only what was typed.
    func testEveryAnswerTheCardCanBuildIsOneTheGateTakes() {
        for question in [one, several] {
            for selected in [[], ["A"], ["B"], ["A", "B"]] {
                for other: String? in [nil, "  ", "Neither: a sheet"] {
                    let answer = AgentQuestionRules.fitting(AgentQuestionAnswer(selected: selected, other: other), to: question)
                    let given = answer.selected.count + (answer.other == nil ? 0 : 1)
                    XCTAssertEqual(
                        AgentQuestionRules.accepts(answer, for: question),
                        given >= 1,
                        "\(selected) \(other ?? "nil") multiple=\(question.multiple)"
                    )
                }
            }
        }
    }
}
