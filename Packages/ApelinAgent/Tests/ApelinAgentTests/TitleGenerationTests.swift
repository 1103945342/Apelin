@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

@Suite("Opening-message titles")
struct TitleGenerationTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["", "{\"title\":", "```\ninvalid\n```", "{\"title\":\" \"}"])
    func `an unusable first answer retries without another user message`(_ answer: String) async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let asked = Inputs()
        provider.setResponses([
            .factory { context, _, _, _ in
                await asked.add(context)
                return fauxAssistantMessage(answer)
            },
            .factory { context, options, _, _ in
                await asked.add(context)
                #expect((options?.maxTokens ?? 0) >= 512)
                return fauxAssistantMessage(#"{"title":"Weather widget","projectName":null}"#)
            },
        ])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(
            project: home.project, provider: .registered(provider.getModel()),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        ), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        await session.generateTitle(for: "Build a weather widget")
        await session.waitForTitle()
        #expect(await asked.values == ["Build a weather widget", "Build a weather widget"])
        #expect(try await session.log.records(afterSeq: 0).filter {
            $0.event == .titleUpdated("Weather widget")
        }.count == 1)
        #expect(try await session.log.readTranscript().isEmpty)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a second message during a retry never becomes the title source`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let asked = Inputs()
        provider.setResponses([
            .factory { context, _, _, _ in
                await asked.add(context)
                return fauxAssistantMessage("")
            },
            .factory { context, _, _, _ in
                await asked.add(context)
                return fauxAssistantMessage("Opening topic")
            },
        ])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(
            project: home.project, provider: .registered(provider.getModel()),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        ), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        await session.generateTitle(for: "Opening topic")
        await session.generateTitle(for: "Unrelated second message")
        await session.waitForTitle()
        #expect(await asked.values == ["Opening topic", "Opening topic"])
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a provider error is retried rather than saved as a plain title`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        provider.setResponses([
            .message(fauxAssistantMessage("Service unavailable", stopReason: .error)),
            .message(fauxAssistantMessage("Opening topic")),
        ])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(
            project: home.project, provider: .registered(provider.getModel()),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        ), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        await session.generateTitle(for: "Opening topic")
        await session.waitForTitle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(events.contains(.titleUpdated("Opening topic")))
        #expect(!events.contains(.titleUpdated("Service unavailable")))
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `reopening an unnamed chat retains its first raw message`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let id = UUID().uuidString
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: id)
        try await log.append(.userMessage(id: UUID(), text: "  Original request\n", attachments: []))
        try await log.append(.userMessage(id: UUID(), text: "Later request", attachments: []))
        try await log.append(.finished(reason: .completed))
        await log.close()
        let asked = Inputs()
        provider.setResponses([.factory { context, _, _, _ in
            await asked.add(context)
            return fauxAssistantMessage("Original topic")
        }])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(
            id: id, project: home.project, provider: .registered(provider.getModel()),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        ), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        await session.generateTitle(for: "Newest request")
        await session.waitForTitle()
        #expect(await asked.values == ["Original request"])
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `accepted input wins even if a later title trigger arrives first`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        provider.setResponses([.message(fauxAssistantMessage("Reply"))])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(
            project: home.project, provider: .registered(provider.getModel()),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        ), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await session.prompt("Original request")
        await session.waitForIdle()
        let asked = Inputs()
        provider.setResponses([.factory { context, _, _, _ in
            await asked.add(context)
            return fauxAssistantMessage("Original topic")
        }])
        await session.generateTitle(for: "Later trigger")
        await session.waitForTitle()
        #expect(await asked.values == ["Original request"])
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `stopping during the retry delay does not send another title request`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let asked = Inputs()
        provider.setResponses([.factory { context, _, _, _ in
            await asked.add(context)
            return fauxAssistantMessage("")
        }, .message(fauxAssistantMessage("Late title"))])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(
            project: home.project, provider: .registered(provider.getModel()),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        ), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        await session.generateTitle(for: "Opening topic")
        for _ in 0 ..< 100 {
            if await !asked.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await asked.values.count == 1)
        await session.abort()
        await session.waitForTitle()
        #expect(await asked.values.count == 1)
        #expect(try await session.log.records(afterSeq: 0).allSatisfy {
            if case .titleUpdated = $0.event { return false }
            return true
        })
        await session.close()
    }

    private actor Inputs {
        private(set) var values: [String] = []
        func add(_ context: Context) {
            values.append(context.messages.compactMap { message -> String? in
                guard case let .user(user) = message else { return nil }
                return ConversationHistory.text(of: user)
            }.joined(separator: "\n"))
        }
    }
}
