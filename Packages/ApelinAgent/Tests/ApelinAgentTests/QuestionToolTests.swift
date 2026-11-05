@testable import ApelinAgent
import struct ApelinProtocol.AgentQuestion
import struct ApelinProtocol.AgentQuestionAnswer
import enum ApelinProtocol.AgentQuestionRules
import enum ApelinProtocol.AgentRunMode
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("apelin_question_ask")
struct QuestionToolTests {
    static let arguments: JSONValue = [
        "question": "Which design?",
        "options": [
            ["label": "Blocking (recommended)", "detail": "The call waits for the answer"],
            ["label": "End the turn"],
        ],
    ]

    /// Runs the tool while acting as the app: once the question waits,
    /// `reply` answers it through the gate. Answers the call's text and the
    /// requests the gate was asked.
    private static func ask(
        _ harness: DigestApprovalTests.Harness,
        _ arguments: JSONValue = Self.arguments,
        reply: @escaping @Sendable (ApprovalGate, ApprovalRequest) async -> Void,
    ) async throws -> (String, [ApprovalRequest]) {
        let gate = harness.gate
        let before = await harness.events.events.count
        let answering = Task {
            while !Task.isCancelled {
                if let request = await gate.pending.first {
                    await reply(gate, request)
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        defer { answering.cancel() }
        let result = try await harness.runner.run(
            .local(.questionAsk),
            toolCallID: "question-1",
            arguments: arguments,
            cancellation: nil,
            mcp: nil,
        )
        let text = result.content.compactMap { block -> String? in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }.joined()
        let requests = await harness.events.events.dropFirst(before).compactMap { event -> ApprovalRequest? in
            if case let .approvalRequested(request) = event {
                return request
            }
            return nil
        }
        return (text, requests)
    }

    @Test
    func `it asks in every mode and a plan run, and the answer is the result`() async throws {
        for mode in [ApprovalMode.relaxed, .full, .confirm] {
            for plan in [false, true] {
                let harness = try DigestApprovalTests.Harness(mode: mode)
                defer { harness.home.remove() }
                if plan {
                    await harness.runner.setRunMode(.plan)
                }
                let (text, asked) = try await Self.ask(harness) { gate, request in
                    try? await gate.resolve(request.id, decision: .approve(.once), answer: AgentQuestionAnswer(selected: ["End the turn"]))
                }
                #expect(asked.count == 1, "one card, the question itself: \(mode) plan=\(plan)")
                #expect(asked.first?.tool == "apelin_question_ask")
                #expect(asked.first?.allowsSessionScope == false)
                #expect(asked.first?.reason == "Which design?", "the host's banner shows the question")
                guard case let .question(question)? = asked.first?.detail else {
                    Issue.record("expected detail.question"); return
                }
                #expect(question.options.map(\.label) == ["Blocking (recommended)", "End the turn"])
                #expect(question.options.first?.detail == "The call waits for the answer")
                #expect(!question.multiple)
                #expect(text.contains("\"End the turn\""), "\(text)")
                #expect(text.contains("not consent"), "an answer is never consent to a step that needs it")
            }
        }
    }

    @Test
    func `an answer of the reader's own goes back as they wrote it`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (text, _) = try await Self.ask(harness) { gate, request in
            try? await gate.resolve(request.id, decision: .approve(.once), answer: AgentQuestionAnswer(other: "Neither: a sheet"))
        }
        #expect(text.contains("Neither: a sheet"))
        #expect(!text.contains("chose"))
    }

    @Test
    func `a skipped question is a result, not an error`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (text, _) = try await Self.ask(harness) { gate, request in
            try? await gate.resolve(request.id, decision: .deny(reason: nil))
        }
        #expect(text == UserQuestions.skipped)
    }

    @Test
    func `the gate refuses an answer that does not fit, and the question goes on waiting`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let refusals = Refusals()
        let (text, _) = try await Self.ask(harness) { gate, request in
            for answer: AgentQuestionAnswer? in [
                nil,
                AgentQuestionAnswer(),
                AgentQuestionAnswer(selected: ["Something else"]),
                AgentQuestionAnswer(selected: ["End the turn", "End the turn"]),
                AgentQuestionAnswer(selected: ["Blocking (recommended)", "End the turn"]),
                AgentQuestionAnswer(selected: ["End the turn"], other: "and more"),
                AgentQuestionAnswer(other: "   "),
            ] {
                do {
                    try await gate.resolve(request.id, decision: .approve(.once), answer: answer)
                } catch ApprovalError.answerDoesNotFit {
                    await refusals.add()
                } catch {}
            }
            try? await gate.resolve(request.id, decision: .approve(.once), answer: AgentQuestionAnswer(selected: ["Blocking (recommended)"]))
        }
        #expect(await refusals.count == 7)
        #expect(text.contains("\"Blocking (recommended)\""))
    }

    @Test
    func `an answer to a request that asked nothing is refused`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let refused = Refusals()
        let gate = harness.gate
        let answering = Task {
            while !Task.isCancelled {
                if let request = await gate.pending.first {
                    do {
                        try await gate.resolve(request.id, decision: .approve(.once), answer: AgentQuestionAnswer(selected: ["x"]))
                    } catch ApprovalError.answerDoesNotFit {
                        await refused.add()
                    } catch {}
                    try? await gate.resolve(request.id, decision: .deny(reason: nil))
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        defer { answering.cancel() }
        await #expect(throws: ToolDeniedError.self) {
            _ = try await harness.runner.run(.local(.packageRemove), toolCallID: "r", arguments: ["installation_id": "i"], cancellation: nil, mcp: nil)
        }
        #expect(await refused.count == 1)
    }

    @Test
    func `several options may be chosen where the question says so`() {
        let question = AgentQuestion(question: "Which?", options: [.init(label: "A"), .init(label: "B")], multiple: true)
        #expect(AgentQuestionRules.accepts(AgentQuestionAnswer(selected: ["A", "B"]), for: question))
        #expect(AgentQuestionRules.accepts(AgentQuestionAnswer(selected: ["B"], other: "and C"), for: question))
        #expect(!AgentQuestionRules.accepts(AgentQuestionAnswer(), for: question))
        let one = AgentQuestion(question: "Which?", options: [.init(label: "A"), .init(label: "B")])
        #expect(!AgentQuestionRules.accepts(AgentQuestionAnswer(selected: ["A", "B"]), for: one))
        #expect(!AgentQuestionRules.accepts(AgentQuestionAnswer(other: String(repeating: "x", count: AgentQuestionRules.maximumOtherLength + 1)), for: one))
    }

    @Test
    func `arguments the card cannot show are refused before anyone is asked`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let bad: [JSONValue] = [
            ["question": "  ", "options": [["label": "A"], ["label": "B"]]],
            ["question": "Which?", "options": [["label": "A"]]],
            ["question": "Which?", "options": [["label": "A"], ["label": "B"], ["label": "C"], ["label": "D"], ["label": "E"]]],
            ["question": "Which?", "options": [["label": "Same"], ["label": "same"]]],
            ["question": "Which?", "options": [["label": "A"], ["detail": "no label"]]],
            ["question": .string(String(repeating: "q", count: AgentQuestionRules.maximumQuestionLength + 1)), "options": [["label": "A"], ["label": "B"]]],
        ]
        for arguments in bad {
            await #expect(throws: ToolArgumentError.self, "\(arguments)") {
                _ = try await harness.runner.run(.local(.questionAsk), toolCallID: "q", arguments: arguments, cancellation: nil, mcp: nil)
            }
        }
        #expect(await harness.gate.pending.isEmpty)
    }

    @Test
    func `the prompt says when to ask, and that an answer is not consent`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, skills: [], mcpServers: [])
        #expect(prompt.contains("ask with apelin_question_ask"))
        #expect(prompt.contains("which a picked option is not"))
        #expect(AgentToolName.questionAsk.risk == .readOnly, "a plan run may ask")
        #expect(!ToolRunner.allowsSessionScope(.local(.questionAsk), detail: .question(AgentQuestion(question: "q", options: []))))
    }
}

private actor Refusals {
    private(set) var count = 0
    func add() {
        count += 1
    }
}
