@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// A conversation opened with a delegation brief: every call it makes is
/// admitted by the host at the revision it read, and what has no confined
/// implementation yet is refused rather than let through.
@Suite("Delegation admission")
struct DelegationGateTests {
    private func brief() -> AgentDelegationBrief {
        AgentDelegationBrief(
            objective: "Ship the fix",
            acceptance: ["The build passes"],
            steps: [
                .init(id: "write", title: "Write it", writeRoots: ["Sources"], capabilities: [.fileWrite]),
                .init(id: "check", title: "Check it"),
            ],
        )
    }

    private func toolResults(_ session: AgentSession) async throws -> [ToolResultRecord] {
        try await session.log.records(afterSeq: 0).map(\.event).compactMap { event in
            if case let .toolCallFinished(result) = event { return result }
            return nil
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a constrained conversation writes through the confined writer and admits its path`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(
                name: "file_write",
                arguments: ["path": "Sources/New.txt", "content": "written"],
            )], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Written.")),
        ])
        let brief = brief()
        let plan = try AgentDelegationPlan(brief: brief)
        let backend = MockBackend()
        await backend.setDelegation { _ in AgentDelegationResponse(plan: plan) }
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .full),
                dataRoot: home.dataRoot,
                delegationBrief: brief,
            ),
            backend: backend,
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Write the file")
        await session.waitForIdle()

        let written = home.projectURL.appendingPathComponent("Sources/New.txt")
        #expect(FileManager.default.fileExists(atPath: written.path), "the step's write root allowed it")
        #expect((try? String(contentsOf: written, encoding: .utf8)) == "written")

        let seen = await backend.delegationSeen()
        #expect(seen.first?.action == .read)
        let admit = try #require(seen.first { $0.action == .admit })
        #expect(admit.tool == "file_write")
        #expect(admit.path == "Sources/New.txt", "the call is admitted at the path it will write")
        #expect(admit.expectedRevision == plan.revision)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a write outside the open step's roots is refused before it runs`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(
                name: "file_write",
                arguments: ["path": "Elsewhere/New.txt", "content": "written"],
            )], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Reported the refusal.")),
        ])
        let brief = brief()
        let plan = try AgentDelegationPlan(brief: brief)
        let backend = MockBackend()
        await backend.setDelegation { _ in AgentDelegationResponse(plan: plan) }
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .full),
                dataRoot: home.dataRoot,
                delegationBrief: brief,
            ),
            backend: backend,
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Write outside the roots")
        await session.waitForIdle()

        #expect(!FileManager.default.fileExists(
            atPath: home.projectURL.appendingPathComponent("Elsewhere/New.txt").path,
        ), "nothing was written outside the step's roots")
        let results = try await toolResults(session)
        #expect(results.contains { $0.isError }, "the call ended as the tool's error")
        await session.close()
    }

    @Test
    func `the plan tool refuses a call the host cannot check`() throws {
        func refuses(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                Issue.record("allowed: \(name)")
            } catch is ToolArgumentError {
                // the tool's own words, which the model reads and corrects
            } catch {
                Issue.record("unexpected error for \(name): \(error)")
            }
        }
        let read = try DelegationPlanCall.read(.object(["action": .string("read")]), sessionID: "self")
        #expect(read.action == .read)
        #expect(read.revision == nil)

        // The assignment actions carry the ledger member's revision.
        refuses("acceptAssignment without a revision") {
            _ = try DelegationPlanCall.read(.object(["action": .string("acceptAssignment")]), sessionID: "self")
        }
        let accepted = try DelegationPlanCall.read(.object([
            "action": .string("acceptAssignment"),
            "expected_revision": .int(3),
        ]), sessionID: "self")
        #expect(accepted.revision == 3)
        #expect(accepted.note == nil)

        // Cancelling or failing the assignment must say why.
        refuses("cancelAssignment without a note") {
            _ = try DelegationPlanCall.read(.object([
                "action": .string("cancelAssignment"),
                "expected_revision": .int(3),
            ]), sessionID: "self")
        }
        refuses("failAssignment without a note") {
            _ = try DelegationPlanCall.read(.object([
                "action": .string("failAssignment"),
                "expected_revision": .int(3),
            ]), sessionID: "self")
        }
        let cancelled = try DelegationPlanCall.read(.object([
            "action": .string("cancelAssignment"),
            "expected_revision": .int(3),
            "note": .string("The user ended it"),
        ]), sessionID: "self")
        #expect(cancelled.action == .cancelAssignment)
        #expect(cancelled.note == "The user ended it")

        // Sealing names the group's revision.
        let sealed = try DelegationPlanCall.read(.object([
            "action": .string("seal"),
            "expected_revision": .int(9),
        ]), sessionID: "self")
        #expect(sealed.action == .seal)
        #expect(sealed.revision == 9)

        // An amendment carries the whole step, and the others never do.
        refuses("amend without the step") {
            _ = try DelegationPlanCall.read(.object([
                "action": .string("amend"),
                "expected_revision": .int(4),
            ]), sessionID: "self")
        }
        let amended = try DelegationPlanCall.read(.object([
            "action": .string("amend"),
            "expected_revision": .int(4),
            "step": .object(["id": .string("write"), "title": .string("Write it, again")]),
        ]), sessionID: "self")
        #expect(amended.step?.id == "write")
        #expect(amended.step?.title == "Write it, again")

        // The host's own admission is never a tool action, and unknown
        // actions are refused rather than forwarded.
        refuses("admit") {
            _ = try DelegationPlanCall.read(.object(["action": .string("admit")]), sessionID: "self")
        }
        refuses("an unknown action") {
            _ = try DelegationPlanCall.read(.object(["action": .string("finish")]), sessionID: "self")
        }
        // A step action without a revision is refused too: nothing reaches
        // the host without the revision it is based on.
        refuses("accept without a revision") {
            _ = try DelegationPlanCall.read(.object(["action": .string("accept")]), sessionID: "self")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a plan that moved refuses the call instead of running it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(
                name: "file_read",
                arguments: ["path": "Sources/New.txt"],
            )], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Reported the refusal.")),
        ])
        let brief = brief()
        let plan = try AgentDelegationPlan(brief: brief)
        let backend = MockBackend()
        // Reading answers the plan the call is admitted at; the admission is
        // refused, as a host whose plan moved refuses a stale revision.
        await backend.setDelegation { request in
            switch request.action {
            case .admit:
                throw ApelinError(.conflict, "the plan moved; read its current revision again")
            default:
                return AgentDelegationResponse(plan: plan)
            }
        }
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .full),
                dataRoot: home.dataRoot,
                delegationBrief: brief,
            ),
            backend: backend,
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Read the file")
        await session.waitForIdle()

        let results = try await toolResults(session)
        #expect(results.contains { $0.isError && $0.output.contains("the plan moved") },
                "the host's refusal is the tool's error")
        let seen = await backend.delegationSeen()
        let admit = try #require(seen.first { $0.action == .admit })
        #expect(admit.expectedRevision == plan.revision, "the admission carries the revision that was read")
        #expect(admit.tool == "file_read")
        await session.close()
    }
}
