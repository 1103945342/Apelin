import ApelinProtocol
import Foundation
import XCTest

/// A message read as an answer to an approval or a question, and the ask as
/// WeChat shows it (2026-11-15).
final class ChannelRepliesTests: XCTestCase {
    private func approval(needsApp: Bool = false) -> ChannelAsk {
        ChannelAsk(approvalID: "a1", sessionID: "s1", tool: "shell_run", needsAppToApprove: needsApp, text: "")
    }

    private func question(multiple: Bool = false) -> ChannelAsk {
        ChannelAsk(
            approvalID: "q1",
            sessionID: "s1",
            question: AgentQuestion(
                question: "Which one?",
                options: [
                    .init(label: "Small", detail: "fast"),
                    .init(label: "Large", detail: nil),
                    .init(label: "Skip it", detail: nil),
                ],
                multiple: multiple
            ),
            text: ""
        )
    }

    func testApprovalTakesYesAndNoWords() {
        for text in ["同意", "批准", "好的", "OK", "yes", "Approve!", " 行 "] {
            guard case let .answer(answer) = ChannelReplies.read(text, ask: approval()) else {
                return XCTFail("\(text) was not read as an answer")
            }
            XCTAssertTrue(answer.approved, text)
        }
        for text in ["拒绝", "不要", "no", "Deny", "取消"] {
            guard case let .answer(answer) = ChannelReplies.read(text, ask: approval()) else {
                return XCTFail("\(text) was not read as an answer")
            }
            XCTAssertFalse(answer.approved, text)
        }
    }

    func testASentenceIsNotAnApproval() {
        XCTAssertEqual(ChannelReplies.read("帮我同意这个吧", ask: approval()), .unclear)
        XCTAssertEqual(ChannelReplies.read("", ask: approval()), .unclear)
        XCTAssertEqual(ChannelReplies.read("再跑一次", ask: approval()), .unclear)
    }

    func testARootApprovalIsOnlyGivenInTheApp() {
        XCTAssertEqual(ChannelReplies.read("同意", ask: approval(needsApp: true)).needsApp, true)
        XCTAssertEqual(ChannelReplies.read("yes", ask: approval(needsApp: true)).needsApp, true)
    }

    func testQuestionNumbersPickItsOptions() {
        guard case let .answer(answer) = ChannelReplies.read("2", ask: question()) else {
            return XCTFail("a number was not read as a choice")
        }
        XCTAssertTrue(answer.approved)
        XCTAssertEqual(answer.answer?.selected, ["Large"])
        XCTAssertNil(answer.answer?.other)

        // A question that takes one option keeps one, whatever was typed.
        guard case let .answer(one) = ChannelReplies.read("1,3", ask: question()) else {
            return XCTFail("two numbers were not read")
        }
        XCTAssertEqual(one.answer?.selected.count, 1)
    }

    func testSeveralOptionsCanBeChosen() {
        guard case let .answer(answer) = ChannelReplies.read("1、3", ask: question(multiple: true)) else {
            return XCTFail("two numbers were not read")
        }
        XCTAssertEqual(answer.answer?.selected, ["Small", "Skip it"])
    }

    func testANumberThatIsNotAnOptionIsNotAnAnswer() {
        XCTAssertEqual(ChannelReplies.read("9", ask: question()), .unclear)
        XCTAssertEqual(ChannelReplies.read("0", ask: question()), .unclear)
    }

    func testWordsUnderAQuestionAreTheReadersOwnAnswer() {
        guard case let .answer(answer) = ChannelReplies.read("用中等大小", ask: question()) else {
            return XCTFail("free text was not read as an answer")
        }
        XCTAssertEqual(answer.answer?.selected, [])
        XCTAssertEqual(answer.answer?.other, "用中等大小")
    }

    func testSkippingAQuestionIsADeny() {
        guard case let .answer(answer) = ChannelReplies.read("跳过", ask: question()) else {
            return XCTFail("skip was not read")
        }
        XCTAssertFalse(answer.approved)
        XCTAssertNil(answer.answer)
    }

    /// A question whose option is called "Small" still reads "1" as its
    /// first option, never as the word for yes.
    func testTheAskTextNumbersTheOptions() {
        let text = ChannelReplies.text(for: question(), language: "zh-Hans")
        XCTAssertTrue(text.contains("Which one?"))
        XCTAssertTrue(text.contains("1. Small — fast"))
        XCTAssertTrue(text.contains("2. Large"))
        XCTAssertTrue(text.contains("回复序号"))
    }

    func testAnApprovalSaysWhatItIsFor() {
        let text = ChannelReplies.text(
            for: approval(),
            reason: "needs to rebuild",
            arguments: #"{"argv":["git","status"]}"#,
            language: "en"
        )
        XCTAssertTrue(text.contains("Apelin needs your approval"))
        XCTAssertTrue(text.contains("shell_run"))
        XCTAssertTrue(text.contains("needs to rebuild"))
        XCTAssertTrue(text.contains("approve"))
        XCTAssertFalse(text.contains("Apelin 需要"))
    }

    func testARootApprovalSaysWhereItIsGiven() {
        let text = ChannelReplies.text(for: approval(needsApp: true), language: "zh-Hans")
        XCTAssertTrue(text.contains("在 Apelin 里确认"))
    }
}

private extension ChannelReplies.Reading {
    var needsApp: Bool {
        if case .needsApp = self { return true }
        return false
    }
}
