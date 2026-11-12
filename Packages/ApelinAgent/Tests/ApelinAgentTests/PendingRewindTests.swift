@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Stop continuation and conversation restore")
struct PendingRewindTests {
    @Test(.timeLimit(.minutes(1)))
    func `manual stop sequence continues waiting input in order`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Second finished.")),
            .message(fauxAssistantMessage("Third finished.")),
        ])
        let session = try await AgentSession(configuration: .init(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let stream = try await session.events(afterSeq: 0)
        let first = UUID(), second = UUID(), third = UUID()
        try await session.prompt("first", messageID: first)
        for await record in stream {
            guard case .approvalRequested = record.event else { continue }
            try await session.prompt("second", messageID: second)
            try await session.prompt("third", messageID: third)
            // The app does these in order, with the host cancelling old
            // shell calls between the abort response and the resume request.
            await session.abort()
            try await session.manageQueue(.init(sessionID: session.id, action: .resume))
            break
        }
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        let sent = events.compactMap { event -> UUID? in
            if case let .userMessage(id, _, _) = event { return id }; return nil
        }
        #expect(sent == [first, second, third])
        #expect(events.filter { $0 == .finished(reason: .completed) }.count == 2)
        #expect(await session.pendingApprovals.isEmpty)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `rewind clears waiting reader source and held input even after reopening`(running: Bool) async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("New draft sent.")),
        ])
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let first = UUID(), held = UUID(), source = UUID()
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("original", messageID: first, files: [("original.txt", "text/plain", Data("original".utf8))])
        for await record in stream {
            guard case .approvalRequested = record.event else { continue }
            try await session.prompt("waiting", messageID: held, files: [("waiting.txt", "text/plain", Data("waiting".utf8))])
            try await session.manageQueue(.init(sessionID: session.id, action: .hold, messageID: held))
            try await session.prompt("source", messageID: source, from: .init(sessionID: "reviewer", title: "Review"))
            break
        }
        if !running {
            await session.abort()
            await session.waitForIdle()
        }
        try await session.rewind(to: first, truncate: true)
        let state = try JSONDecoder().decode(PendingQueue.State.self, from: Data(contentsOf: session.log.directory.appendingPathComponent("pending.json")))
        #expect(state.messages.isEmpty && state.handoffs.isEmpty && state.paused)
        #expect(state.seen.isSuperset(of: [first, held, source]))
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(events.contains(.historyRewound(id: first)))
        #expect(events.contains(.pendingQueue(messages: [], paused: true)))
        #expect(!events.contains { if case .userMessage(held, _, _) = $0 { return true }; return false })
        #expect(try await session.log.readTranscript().isEmpty)
        await session.close()
        let reopened = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await reopened.prompt("duplicate", messageID: held)
        try await reopened.manageQueue(.init(sessionID: reopened.id, action: .resume))
        await reopened.waitForIdle()
        let before = try await reopened.log.records(afterSeq: 0).map(\.event)
        #expect(!before.contains { if case .userMessage(held, _, _) = $0 { return true }; return false })
        // refillComposer creates a fresh ID; only sending that new draft
        // starts another run, never any of the cleared waiting messages.
        let fresh = UUID()
        try await reopened.prompt("original", messageID: fresh)
        await reopened.waitForIdle()
        let after = try await reopened.log.records(afterSeq: 0).map(\.event)
        #expect(after.filter { if case .userMessage(fresh, "original", _) = $0 { return true }; return false }.count == 1)
        await reopened.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `empty stop continuation leaves later source input paused`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let session = try await AgentSession(configuration: .init(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        await session.abort()
        try await session.manageQueue(.init(sessionID: session.id, action: .resume))
        let source = UUID()
        try await session.prompt("later source", messageID: source, from: .init(sessionID: "reviewer", title: "Review"))
        await session.waitForIdle()
        let state = try JSONDecoder().decode(PendingQueue.State.self, from: Data(contentsOf: session.log.directory.appendingPathComponent("pending.json")))
        #expect(state.paused && state.messages.map(\.id) == [source])
        await session.close()
    }
}
