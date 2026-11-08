@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Conversation message acceptance")
struct ConversationMessageTests {
    @Test(.timeLimit(.minutes(1)))
    func `a source follow-up waits for the reader turn and cannot steal steering or runtime messages`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove it", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Reader work finished.")),
            .message(fauxAssistantMessage("Source work finished.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource()
        )
        let events = try await session.events(afterSeq: 0)
        try await session.prompt("Remove it", messageID: UUID())
        let reader = UUID()
        var source: UUID?
        for await record in events {
            guard case let .approvalRequested(request) = record.event else { continue }
            try await session.prompt("Review afterwards", from: ConversationSender(sessionID: "reviewer"))
            try await session.prompt("Keep the logs", messageID: reader)
            let before = try await session.log.records(afterSeq: 0).map(\.event)
            source = before.compactMap { event -> UUID? in
                if case let .conversationMessageQueued(id, _, _) = event { return id }
                return nil
            }.first
            #expect(!before.contains { if case .conversationMessageTaken = $0 { return true }; return false })
            let agent = await session.agent
            agent.aside("A runtime notice, not either queued message")
            try await session.approve(requestID: request.id, decision: .approve(.once))
            break
        }
        await session.waitForIdle()
        let all = try await session.log.records(afterSeq: 0).map(\.event)
        let sourceID = try #require(source)
        let readerAt = try #require(all.firstIndex(of: .userMessage(id: reader, text: "Keep the logs", attachments: [])))
        let sourceAt = try #require(all.firstIndex(of: .conversationMessageTaken(id: sourceID, text: "Review afterwards", from: "reviewer")))
        let readerFinished = try #require(all.firstIndex(of: .messageFinished(text: "Reader work finished.")))
        #expect(readerAt < readerFinished && readerFinished < sourceAt)
        #expect(all.filter { if case .conversationMessageTaken = $0 { return true }; return false }.count == 1)
        #expect(!all.contains { if case .conversationMessagesDropped = $0 { return true }; return false })
        let transcript = try await session.log.readTranscript()
        #expect(transcript.contains { message in
            guard case let .user(user) = message else { return false }
            return ConversationHistory.text(of: user).contains("conversation reviewer,")
        })
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `stopping drops source follow-ups without returning them to the composer or next run`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove it", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Resumed.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource()
        )
        let events = try await session.events(afterSeq: 0)
        try await session.prompt("Remove it", messageID: UUID())
        for await record in events {
            guard case .approvalRequested = record.event else { continue }
            try await session.prompt("Never consume this", from: ConversationSender(sessionID: "reviewer"))
            await session.abort()
            break
        }
        await session.waitForIdle()
        try await session.prompt("Continue without the source message", messageID: UUID())
        await session.waitForIdle()
        let all = try await session.log.records(afterSeq: 0).map(\.event)
        let source = try #require(all.compactMap { event -> UUID? in
            if case let .conversationMessageQueued(id, _, _) = event { return id }
            return nil
        }.first)
        #expect(all.contains(.conversationMessagesDropped(ids: [source])))
        #expect(!all.contains { if case .conversationMessageTaken = $0 { return true }; return false })
        #expect(!all.contains { event in
            if case let .queuedMessagesDropped(ids) = event { return ids.contains(source) }
            return false
        })
        let transcript = try await session.log.readTranscript()
        #expect(!transcript.contains { message in
            guard case let .user(user) = message else { return false }
            return ConversationHistory.text(of: user).contains("Never consume this")
        })
        await session.close()
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
        let first = try #require(AgentSession.forkRecords(records, through: reader)).map(\.event)
        #expect(first == [.userMessage(id: reader, text: "Work", attachments: []), .messageFinished(text: "Reader reply"), .finished(reason: .aborted)])
        let sourceFork = try #require(AgentSession.forkRecords(records, through: source)).map(\.event)
        #expect(sourceFork.contains(taken) && sourceFork.contains(.messageFinished(text: "Source reply")))
        #expect(sourceFork.filter { $0 == taken }.count == 1)
        let later = try #require(AgentSession.forkRecords(records, through: nextReader)).map(\.event)
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
