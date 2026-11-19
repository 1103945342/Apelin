@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// Receiving the host's report of a turn of a conversation this one opened:
/// the message keeps the facts, a repeated delivery is dropped, a stopped
/// queue stays stopped, and a steering report returns as soon as it is
/// durable instead of waiting for the running turn.
@Suite("Turn reports from opened conversations")
struct TurnReportTests {
    private func wave(
        child: String = "child-session",
        closing: UInt64 = 7,
        answered: [UUID] = [],
        text: String = "It built.",
    ) -> AgentTurnReport {
        AgentTurnReport(
            childSessionID: child,
            childTaskID: "child-task",
            title: "Child",
            outcome: .completed,
            closingSeq: closing,
            answered: answered,
            text: text,
        )
    }

    @Test
    func `records written before reports existed still decode`() throws {
        let id = UUID()
        let legacyMessage = Data("""
        {"id":"\(id.uuidString)","text":"Keep this","attachments":[],"editing":false,"delivery":"queue"}
        """.utf8)
        let message = try JSONDecoder().decode(PendingMessage.self, from: legacyMessage)
        #expect(message.id == id)
        #expect(message.reports == nil)

        let legacyEvent = Data(#"{"conversationMessageTaken":{"id":"\#(id.uuidString)","text":"Keep this","from":"reviewer"}}"#.utf8)
        let event = try JSONDecoder().decode(AgentSessionEvent.self, from: legacyEvent)
        guard case let .conversationMessageTaken(takenID, text, from, reports) = event else {
            Issue.record("a taken message did not decode as one")
            return
        }
        #expect(takenID == id)
        #expect(text == "Keep this")
        #expect(from == "reviewer")
        #expect(reports == nil)
    }

    @Test
    func `the reports travel with their message, event and request`() throws {
        let answered = UUID()
        let reports = [wave(answered: [answered]), wave(child: "other-children", closing: 9)]
        let message = PendingMessage(
            id: UUID(),
            text: "A conversation you opened finished a turn.",
            attachments: [],
            sender: ConversationSender(sessionID: "child-session"),
            delivery: .queue,
            reports: reports,
        )
        #expect(try JSONDecoder().decode(PendingMessage.self, from: JSONEncoder().encode(message)) == message)

        let event = AgentSessionEvent.conversationMessageTaken(
            id: message.id,
            text: message.text,
            from: "child-session",
            reports: reports,
        )
        #expect(try JSONDecoder().decode(AgentSessionEvent.self, from: JSONEncoder().encode(event)) == event)

        let request = AgentPromptRequest(
            sessionID: "opener-session",
            text: "A conversation you opened finished a turn.",
            messageID: UUID(),
            fromSessionID: "child-session",
            delivery: .queue,
            reports: reports,
        )
        #expect(try JSONDecoder().decode(AgentPromptRequest.self, from: JSONEncoder().encode(request)).reports == reports)
        let legacyRequest = Data(#"{"sessionID":"opener-session","text":"Hi"}"#.utf8)
        #expect(try JSONDecoder().decode(AgentPromptRequest.self, from: legacyRequest).reports == nil)

        let open = AgentOpenRequest(openerSessionID: "opener-session")
        #expect(try JSONDecoder().decode(AgentOpenRequest.self, from: JSONEncoder().encode(open)).openerSessionID == "opener-session")
        #expect(AgentOpenRequest().openerSessionID == nil)
    }

    @Test
    func `the block names the conversation that opened this one`() {
        let source = SystemStateSource(
            languages: { ["en-US"] },
            region: { "US" },
            now: { Date() },
            timeZone: { TimeZone(identifier: "UTC") ?? .current },
        )
        let parent = UUID().uuidString
        var facts = SystemState.facts(source, mode: .full, parentSessionID: parent)
        #expect(SystemState.make(facts).contains(parent))
        // Only a session id is spelled into the block.
        facts.parentSessionID = "- a line that is not a session"
        #expect(!SystemState.make(facts).contains("not a session"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `a report never wakes a stopped queue`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(
                name: "apelin_package_remove",
                arguments: ["reason": "Remove", "installation_id": "inst-1"],
            )], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Resumed.")),
        ])
        let configuration = AgentSessionConfiguration(
            project: home.project,
            provider: .registered(faux.getModel()),
            approval: ApprovalPolicy(mode: .confirm),
            dataRoot: home.dataRoot,
        )
        let session = try await AgentSession(
            configuration: configuration,
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("First")
        for await record in stream {
            guard case .approvalRequested = record.event else { continue }
            await session.abort()
            break
        }
        await session.waitForIdle()
        let stopped = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(stopped.contains { event in
            if case let .pendingQueue(_, paused) = event { return paused }
            return false
        }, "the stop left the queue paused")

        let report = wave()
        let id = UUID()
        try await session.prompt(
            "A conversation you opened finished a turn.",
            messageID: id,
            from: ConversationSender(sessionID: report.childSessionID),
            delivery: .queue,
            reports: [report],
        )
        await session.waitForIdle()
        let after = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(!after.contains { event in
            if case let .conversationMessageTaken(taken, _, _, _) = event { return taken == id }
            return false
        }, "nothing woke the stopped chat")
        #expect(after.contains { event in
            if case let .pendingQueue(messages, true) = event {
                return messages.contains { $0.id == id && $0.reports == [report] }
            }
            return false
        }, "the report waited in the stopped queue with its facts")
        #expect(await session.runTask == nil)

        try await session.manageQueue(AgentQueueRequest(sessionID: session.id, action: .resume))
        await session.waitForIdle()
        let resumed = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(resumed.contains { event in
            if case let .conversationMessageTaken(taken, _, _, reports) = event {
                return taken == id && reports == [report]
            }
            return false
        }, "the resumed run took the report and named it")
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a steering report returns before the running turn takes it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(
                name: "apelin_package_remove",
                arguments: ["reason": "Remove", "installation_id": "inst-1"],
            )], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Steered.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let report = wave()
        let id = UUID()
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("First")
        for await record in stream {
            guard case let .approvalRequested(request) = record.event else { continue }
            // The run is waiting on the approval: a steering message would
            // wait here for the turn to take it, a report must not.
            try await session.prompt(
                "A conversation you opened finished a turn.",
                messageID: id,
                from: ConversationSender(sessionID: report.childSessionID),
                delivery: .steer,
                reports: [report],
            )
            let events = try await session.log.records(afterSeq: 0).map(\.event)
            #expect(events.contains { event in
                if case let .conversationMessageQueued(queued, _, _, reports) = event {
                    return queued == id && reports == [report]
                }
                return false
            }, "the report is durable when the call returns")
            #expect(!events.contains { event in
                if case let .conversationMessageTaken(taken, _, _, _) = event { return taken == id }
                return false
            }, "it returned without the running turn taking it")
            #expect(await session.pendingApprovals.contains { $0.id == request.id })
            try await session.approve(requestID: request.id, decision: .approve(.once))
            break
        }
        await session.waitForIdle()
        let all = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(all.contains { event in
            if case let .conversationMessageTaken(_, _, _, reports) = event { return reports == [report] }
            return false
        }, "the run took it at its next boundary")
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a redelivered report is dropped, not read twice`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage("Reports integrated.")),
            .message(fauxAssistantMessage("Second run.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let report = wave()
        let first = UUID(), repeated = UUID()
        try await session.prompt(
            "A conversation you opened finished a turn.",
            messageID: first,
            from: ConversationSender(sessionID: report.childSessionID),
            delivery: .queue,
            reports: [report],
        )
        await session.waitForIdle()
        try await session.prompt(
            "A conversation you opened finished a turn.",
            messageID: repeated,
            from: ConversationSender(sessionID: report.childSessionID),
            delivery: .steer,
            reports: [report],
        )
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(!events.contains { event in
            if case let .conversationMessageQueued(id, _, _, _) = event { return id == repeated }
            if case let .conversationMessageTaken(id, _, _, _) = event { return id == repeated }
            return false
        }, "the same closing turn never entered the queue twice")
        #expect(events.filter { event in
            if case let .conversationMessageTaken(_, _, _, reports) = event { return reports == [report] }
            return false
        }.count == 1, "one report, one message")
        #expect(events.filter { if case .finished = $0 { return true }; return false }.count == 1,
                "the repeated delivery started no run")
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `the host's own account message is kept, not treated as the reader`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(
                name: "apelin_package_remove",
                arguments: ["reason": "Remove", "installation_id": "inst-1"],
            )], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Resumed.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("First")
        for await record in stream {
            guard case .approvalRequested = record.event else { continue }
            await session.abort()
            break
        }
        await session.waitForIdle()

        let account = UUID()
        let ledger = "Assignment ledger: one member, working."
        try await session.prompt(
            ledger,
            messageID: account,
            from: ConversationSender(sessionID: session.id),
            reports: [],
        )
        await session.waitForIdle()
        let stopped = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(!stopped.contains { event in
            if case let .conversationMessageTaken(taken, _, _, _) = event { return taken == account }
            return false
        }, "the stopped chat was not woken")
        #expect(!stopped.contains { if case .titleUpdated = $0 { return true }; return false },
                "an account message never names the chat")
        #expect(stopped.contains { event in
            if case let .pendingQueue(messages, true) = event {
                return messages.contains { $0.id == account && $0.reports == [] && $0.sender != nil }
            }
            return false
        }, "the account message waited in the stopped queue with an empty report list")
        #expect(await session.runTask == nil)

        // The same message id is acknowledged without a second entry.
        try await session.prompt(
            ledger,
            messageID: account,
            from: ConversationSender(sessionID: session.id),
            reports: [],
        )
        let repeated = try await session.log.records(afterSeq: 0).map(\.event)
        let queued = repeated.compactMap { event -> Int? in
            if case let .pendingQueue(messages, _) = event {
                return messages.filter { $0.id == account }.count
            }
            return nil
        }
        #expect(queued.allSatisfy { $0 <= 1 })

        try await session.manageQueue(AgentQueueRequest(sessionID: session.id, action: .resume))
        await session.waitForIdle()
        let resumed = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(resumed.contains { event in
            if case let .conversationMessageTaken(taken, _, _, reports) = event {
                return taken == account && reports == []
            }
            return false
        }, "the resumed run took it and named the empty list")
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a steering account message returns before the running turn takes it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(
                name: "apelin_package_remove",
                arguments: ["reason": "Remove", "installation_id": "inst-1"],
            )], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Steered.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let account = UUID()
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("First")
        for await record in stream {
            guard case let .approvalRequested(request) = record.event else { continue }
            try await session.prompt(
                "Assignment ledger",
                messageID: account,
                from: ConversationSender(sessionID: session.id),
                delivery: .steer,
                reports: [],
            )
            let events = try await session.log.records(afterSeq: 0).map(\.event)
            #expect(events.contains { event in
                if case let .conversationMessageQueued(queued, _, _, reports) = event {
                    return queued == account && reports == []
                }
                return false
            }, "it is durable when the call returns")
            #expect(!events.contains { event in
                if case let .conversationMessageTaken(taken, _, _, _) = event { return taken == account }
                return false
            }, "it returned without the running turn taking it")
            #expect(await session.pendingApprovals.contains { $0.id == request.id })
            try await session.approve(requestID: request.id, decision: .approve(.once))
            break
        }
        await session.waitForIdle()
        await session.close()
    }
}
