@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Pending input starts complete runs")
struct PendingSessionTests {
    @Test(.timeLimit(.minutes(1)))
    func `held head blocks FIFO until edit and each input starts a new run`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("First finished.")),
            .message(fauxAssistantMessage("Second finished.")),
            .message(fauxAssistantMessage("Third finished.")),
        ])
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let stream = try await session.events(afterSeq: 0)
        let first = UUID(), second = UUID(), third = UUID()
        try await session.prompt("first", messageID: first)
        for await record in stream {
            if case let .approvalRequested(request) = record.event {
                try await session.prompt("second", messageID: second, files: [("notes.txt", "text/plain", Data("kept".utf8))])
                try await session.manageQueue(.init(sessionID: session.id, action: .hold, messageID: second))
                try await session.prompt("third", messageID: third)
                try await session.prompt("duplicate", messageID: third)
                try await session.approve(requestID: request.id, decision: .approve(.once))
            }
            if case .finished = record.event { break }
        }
        await session.waitForIdle()
        var events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(events.filter { if case .finished = $0 { return true }; return false }.count == 1)
        #expect(!events.contains { if case .userMessageQueued = $0 { return true }; return false })
        try await session.manageQueue(.init(sessionID: session.id, action: .edit, messageID: second, text: "edited"))
        await session.waitForIdle()
        events = try await session.log.records(afterSeq: 0).map(\.event)
        let ids = events.compactMap { event -> UUID? in
            if case let .userMessage(id, _, _) = event { return id }; return nil
        }
        #expect(ids == [first, second, third])
        var finished = 0
        for event in events {
            if case .finished(reason: .completed) = event { finished += 1 }
            if case .userMessage(second, "edited", let attachments) = event {
                #expect(finished == 1)
                let file = try #require(attachments.first)
                #expect(try Data(contentsOf: home.projectURL.appendingPathComponent(file.path)) == Data("kept".utf8))
            }
            if case .userMessage(third, _, _) = event { #expect(finished == 2) }
        }
        #expect(finished == 3)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `queued inputs apply their own model settings only when their run starts`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("First finished.")),
            .message(fauxAssistantMessage("Second finished.")),
            .message(fauxAssistantMessage("Third finished.")),
        ])
        let provider = ProviderConfiguration.registered(faux.getModel())
        let session = try await AgentSession(configuration: .init(project: home.project, provider: provider, approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        func choice(_ window: Int) -> PendingModelChoice {
            var parameters = AgentModelParameters()
            parameters.contextWindow = window
            return PendingModelChoice(provider: provider, parameters: parameters)
        }
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("first", modelChoice: choice(8192))
        for await record in stream {
            guard case let .approvalRequested(request) = record.event else { continue }
            try await session.prompt("second", modelChoice: choice(16384))
            try await session.prompt("third", modelChoice: choice(32768))
            let active = await session.contextFigure()
            #expect(active.window == 8192, "queued choices do not reconfigure the active run")
            try await session.approve(requestID: request.id, decision: .approve(.once))
            break
        }
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        var window: Int?
        var finishedWindows: [Int] = []
        for event in events {
            if case let .contextUsage(_, value) = event { window = value }
            if case .finished(reason: .completed) = event, let window { finishedWindows.append(window) }
        }
        #expect(finishedWindows == [8192, 16384, 32768])
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `missing queued credentials pause without consuming or skipping input`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let first = UUID(), second = UUID()
        let choice = PendingModelChoice(provider: .openAICompatible(model: "no-credentials"))
        try await session.prompt("keep first", messageID: first, modelChoice: choice)
        try await session.prompt("keep second", messageID: second)
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(!events.contains { if case .userMessage = $0 { return true }; return false })
        let snapshot = events.compactMap { event -> [PendingMessage]? in
            if case let .pendingQueue(messages, true) = event { return messages }; return nil
        }.last
        #expect(snapshot?.map(\.id) == [first, second])
        #expect(snapshot?.first?.modelChoice == choice)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `stop after handoff but before provider entry restores input paused`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        await session.observePendingModel { _ in
            entered.continuation.yield(())
            for await _ in release.stream { break }
        }
        let first = UUID(), second = UUID()
        try await session.prompt("first", messageID: first, modelChoice: PendingModelChoice(provider: .registered(faux.getModel())))
        for await _ in entered.stream { break }
        try await session.prompt("second", messageID: second)
        await session.abort()
        release.continuation.yield(())
        release.continuation.finish()
        entered.continuation.finish()
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        let snapshot = events.compactMap { event -> [PendingMessage]? in
            if case let .pendingQueue(messages, true) = event { return messages }; return nil
        }.last
        #expect(snapshot?.map(\.id) == [first, second])
        #expect(!events.contains { if case .messageStarted = $0 { return true }; return false })
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `stop and reopen preserve input paused until explicit resume`() async throws {
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
        let later = UUID()
        try await session.prompt("first", messageID: UUID())
        for await record in stream {
            if case .approvalRequested = record.event {
                try await session.prompt("later", messageID: later)
                await session.abort()
            }
            if case .finished = record.event { break }
        }
        await session.close()
        let reopened = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await reopened.prompt("duplicate", messageID: later)
        await reopened.waitForIdle()
        let before = try await reopened.log.records(afterSeq: 0).map(\.event)
        #expect(before.contains { if case .pendingQueue(let messages, true) = $0 { return messages.map(\.id) == [later] }; return false })
        #expect(!before.contains { if case .userMessage(later, _, _) = $0 { return true }; return false })
        try await reopened.manageQueue(.init(sessionID: reopened.id, action: .resume))
        await reopened.waitForIdle()
        let after = try await reopened.log.records(afterSeq: 0).map(\.event)
        #expect(after.filter { if case .userMessage(later, "later", _) = $0 { return true }; return false }.count == 1)
        await reopened.close()
    }
}
