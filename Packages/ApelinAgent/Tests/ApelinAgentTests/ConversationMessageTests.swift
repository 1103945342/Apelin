@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Conversation message acceptance")
struct ConversationMessageTests {
    @Test(.timeLimit(.minutes(1)))
    func `queued source starts a new run automatically and shares reader FIFO`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("First finished.")),
            .message(fauxAssistantMessage("Source finished.")),
            .message(fauxAssistantMessage("Reader finished.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let stream = try await session.events(afterSeq: 0)
        let source = UUID(), reader = UUID()
        try await session.prompt("First")
        for await record in stream {
            guard case let .approvalRequested(request) = record.event else { continue }
            try await session.prompt("Review afterwards", messageID: source, from: ConversationSender(sessionID: "reviewer"), delivery: .queue)
            try await session.prompt("Keep logs", messageID: reader)
            let before = try await session.log.records(afterSeq: 0).map(\.event)
            #expect(!before.contains { if case .conversationMessageTaken = $0 { return true }; return false })
            let agent = await session.agent
            agent.aside("A runtime notice, not a queued message")
            try await session.approve(requestID: request.id, decision: .approve(.once))
            break
        }
        await session.waitForIdle()
        let all = try await session.log.records(afterSeq: 0).map(\.event)
        let sourceAt = try #require(all.firstIndex(of: .conversationMessageTaken(id: source, text: "Review afterwards", from: "reviewer")))
        let readerAt = try #require(all.firstIndex(of: .userMessage(id: reader, text: "Keep logs", attachments: [])))
        let firstEnd = try #require(all.firstIndex(of: .finished(reason: .completed)))
        #expect(firstEnd < sourceAt && sourceAt < readerAt)
        #expect(all.filter { if case .finished(reason: .completed) = $0 { return true }; return false }.count == 3)
        #expect(all.filter { if case .conversationMessageTaken = $0 { return true }; return false }.count == 1)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `explicit source steering guides the current run before it finishes`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Changed direction.")),
            .message(fauxAssistantMessage("Repeated direction received.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let stream = try await session.events(afterSeq: 0)
        let source = UUID(), repeated = UUID()
        try await session.prompt("First")
        for await record in stream {
            guard case let .approvalRequested(request) = record.event else { continue }
            try await session.prompt("Change direction", messageID: source, from: ConversationSender(sessionID: "reviewer"), delivery: .steer)
            try await session.prompt("Change direction", messageID: repeated, from: ConversationSender(sessionID: "reviewer"), delivery: .steer)
            // Sending must not approve or cancel the executing tool on our behalf.
            #expect(await session.pendingApprovals.contains { $0.id == request.id })
            try await session.approve(requestID: request.id, decision: .approve(.once))
            break
        }
        await session.waitForIdle()
        let all = try await session.log.records(afterSeq: 0).map(\.event)
        let sourceAt = try #require(all.firstIndex(of: .conversationMessageTaken(id: source, text: "Change direction", from: "reviewer")))
        let endedAt = try #require(all.firstIndex(of: .finished(reason: .completed)))
        let repeatedAt = try #require(all.firstIndex(of: .conversationMessageTaken(id: repeated, text: "Change direction", from: "reviewer")))
        #expect(sourceAt < repeatedAt && repeatedAt < endedAt)
        #expect(all.filter { if case .conversationMessageTaken = $0 { return true }; return false }.count == 2)
        let takenIDs = all.compactMap { event -> UUID? in
            if case let .conversationMessageTaken(id, _, _) = event { return id }; return nil
        }
        #expect(takenIDs == [source, repeated])
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `stop and reopen retain source input paused until resume`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Resumed.")),
        ])
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let stream = try await session.events(afterSeq: 0)
        let source = UUID()
        try await session.prompt("First")
        for await record in stream {
            guard case .approvalRequested = record.event else { continue }
            try await session.prompt("Keep this", messageID: source, from: ConversationSender(sessionID: "reviewer", title: "Review"))
            await session.abort()
            break
        }
        await session.close()
        let reopened = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        await reopened.waitForIdle()
        let before = try await reopened.log.records(afterSeq: 0).map(\.event)
        #expect(!before.contains { if case .conversationMessageTaken = $0 { return true }; return false })
        #expect(before.contains { event in
            if case let .pendingQueue(messages, true) = event { return messages.contains { $0.id == source && $0.sender?.sessionID == "reviewer" } }
            return false
        })
        try await reopened.manageQueue(.init(sessionID: reopened.id, action: .resume))
        await reopened.waitForIdle()
        let after = try await reopened.log.records(afterSeq: 0).map(\.event)
        #expect(after.filter { $0 == .conversationMessageTaken(id: source, text: "Keep this", from: "reviewer") }.count == 1)
        await reopened.close()
    }

    @Test
    func `forks exclude untaken source messages and split only at acceptance`() throws {
        let reader = UUID()
        let nextReader = UUID()
        let source = UUID()
        let queued = AgentSessionEvent.conversationMessageQueued(id: source, text: "Review", from: "reviewer")
        let taken = AgentSessionEvent.conversationMessageTaken(id: source, text: "Review", from: "reviewer")
        let events: [AgentSessionEvent] = [
            .userMessage(id: reader, text: "Work", attachments: []),
            queued,
            .messageFinished(text: "Reader reply"),
            taken,
            .messageFinished(text: "Source reply"),
            .finished(reason: .completed),
            .userMessage(id: nextReader, text: "Next", attachments: []),
            .messageFinished(text: "Next reply"),
            .finished(reason: .completed),
        ]
        let records = events.enumerated().map {
            SessionEventRecord(seq: UInt64($0.offset + 1), date: Date(), event: $0.element)
        }
        let first = try #require(records.forkRecords(through: reader)).map(\.event)
        #expect(first == [.userMessage(id: reader, text: "Work", attachments: []), .messageFinished(text: "Reader reply"), .finished(reason: .aborted)])
        let sourceFork = try #require(records.forkRecords(through: source)).map(\.event)
        #expect(sourceFork.contains(taken) && sourceFork.contains(.messageFinished(text: "Source reply")))
        #expect(sourceFork.filter { $0 == taken }.count == 1)
        let later = try #require(records.forkRecords(through: nextReader)).map(\.event)
        #expect(later.contains(queued) && later.contains(taken))
        #expect(later.filter { $0 == queued }.count == 1)
    }

    @Test
    func `new source events round trip and legacy sender prompts still decode`() throws {
        let id = UUID()
        let events: [AgentSessionEvent] = [
            .promptSubmitted(text: "Old log", from: "reviewer"),
            .conversationMessageQueued(id: id, text: "Review", from: "reviewer"),
            .conversationMessageTaken(id: id, text: "Review", from: "reviewer"),
            .conversationMessagesDropped(ids: [id]),
        ]
        for event in events {
            #expect(try JSONDecoder().decode(AgentSessionEvent.self, from: JSONEncoder().encode(event)) == event)
        }
        let legacy = Data(#"{"promptSubmitted":{"text":"Old log","from":"reviewer"}}"#.utf8)
        #expect(try JSONDecoder().decode(AgentSessionEvent.self, from: legacy) == events[0])
    }
}
