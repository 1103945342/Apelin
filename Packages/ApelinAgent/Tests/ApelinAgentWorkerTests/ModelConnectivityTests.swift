@testable import ApelinAgentWorker
import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ModelConnectivityTests {
    @Test func `request is exactly Hi without prompts history or tools`() throws {
        let context = AgentModelTester.context()
        #expect(context.systemPrompt == nil)
        #expect(context.tools == nil)
        #expect(context.messages.count == 1)
        guard case let .user(user) = try #require(context.messages.first) else {
            Issue.record("not a user message"); return
        }
        #expect(user.content.count == 1)
        guard case let .text(text) = try #require(user.content.first) else {
            Issue.record("not plain text"); return
        }
        #expect(text.text == "Hi")
        let options = AgentModelTester.options(auth: nil, cancellation: CancellationHandle())
        #expect(options.reasoning == nil && options.verbose == false)
        #expect(options.toolChoice == ToolChoice.none)
        #expect(options.transport == .sse && options.maxRetryDelayMs == 0)
        #expect(options.cacheRetention == CacheRetention.none)
    }

    @Test func `local start is not latency and empty error keeps streamed reply`() async {
        let report = ModelTestReport {}
        let reply = await withCheckedContinuation { continuation in
            report.attach(continuation)
            report.beginRequest()
            AgentModelTester.observe(.start(partial: fauxAssistantMessage("")), report: report)
            AgentModelTester.observe(.textStart(contentIndex: 0, partial: fauxAssistantMessage("")), report: report)
            AgentModelTester.observe(.textDelta(contentIndex: 0, delta: "Hello", partial: fauxAssistantMessage("Hello")), report: report)
            AgentModelTester.observe(.error(reason: .error, error: fauxAssistantMessage("")), report: report)
            report.finish(failure: "disconnected")
        }
        #expect(!reply.success && reply.text == "Hello")
        #expect(reply.stages.contains { $0.name == .firstText })
    }

    @Test func `missing credentials and required prompt providers fail explicitly`() async {
        let source = DeliveredCredentialSource()
        let missing = await AgentModelTester.run(.init(provider: .anthropic, model: "test"), credentials: source)
        #expect(!missing.success && missing.failure?.contains("sign-in") == true)
        #expect(missing.stages.map(\.name) == [.credentials, .total])
        for provider in [AgentProvider.anthropicOAuth, .cursor, .qoder, .qoderCN, .workBuddy, .workBuddyAI] {
            let reply = await AgentModelTester.run(.init(provider: provider, model: "test"), credentials: source)
            #expect(!reply.success && reply.failure?.contains("pure Hi") == true)
            #expect(reply.stages.map(\.name) == [.total])
        }
    }

    @Test func `failure descriptions expose category and status but no provider secrets`() {
        let secret = "Bearer private-token https://example.invalid/?api_key=private-token"
        let failure = ProviderFailure(message: secret, httpStatus: 401, upstreamMessage: secret)
        let reason = AgentModelTester.safeFailure(failure, phase: "authorization")
        #expect(reason.contains("401") && reason.contains("authorization"))
        #expect(!reason.contains("private-token") && !reason.contains("https://"))
    }
}
