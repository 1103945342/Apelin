import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI

/// One independent model request: no agent loop, history, tools, or retry loop.
enum AgentModelTester {
    static func run(
        _ request: AgentModelTestRequest,
        credentials: any CredentialSource,
        progress: (@Sendable (AgentModelTestProgress) -> Void)? = nil,
    ) async -> AgentModelTestResponse {
        let cancellation = CancellationHandle()
        let report = ModelTestReport(cancelRequest: { cancellation.cancel() }, progress: progress)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                report.attach(continuation)
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    report.finish(failure: "The model test timed out during \(report.phaseName) after 60 seconds.")
                }
                let operation = Task {
                    do {
                        try Task.checkCancellation()
                        try await perform(request, credentials: credentials, cancellation: cancellation, report: report)
                    } catch {
                        report.finish(failure: safeFailure(error, phase: report.phaseName))
                    }
                }
                report.attach(tasks: [operation, deadline])
            }
        } onCancel: {
            report.finish(failure: "The model test was cancelled.")
        }
    }

    private static func perform(
        _ request: AgentModelTestRequest,
        credentials: any CredentialSource,
        cancellation: CancellationHandle,
        report: ModelTestReport,
    ) async throws {
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report.finish(failure: "Choose a model before testing.")
            return
        }
        if let unsupported = unsupportedPureHiProvider(request.provider) {
            report.finish(failure: unsupported)
            return
        }
        let configuration = try AgentWorker.provider(provider: request.provider, model: request.model)
        report.begin(.credentials)
        let resolved = try await ProviderResolver.resolve(configuration, credentials: credentials) { diagnostic in
            // The resolver emits this only after the saved credential read.
            // Do not keep the diagnostic or any credential in the report.
            if diagnostic.hasPrefix("provider credentials read in ") { report.begin(.preparation) }
        }
        try Task.checkCancellation()
        try cancellation.throwIfCancelled()
        report.begin(.authorization)
        let auth = try await resolved.authResolver?(resolved.model, nil)
        try Task.checkCancellation()
        try cancellation.throwIfCancelled()
        report.beginRequest()
        let stream = try await KWWKAI.stream(
            model: resolved.model,
            context: context(),
            options: options(auth: auth, cancellation: cancellation),
        )
        for await event in stream {
            try Task.checkCancellation()
            observe(event, report: report)
        }
        try Task.checkCancellation()
        let final = await stream.result()
        record(final, report: report, event: false)
        if let failure = final.providerFailure {
            report.finish(failure: safeFailure(failure, phase: "response"))
        } else if final.stopReason != .stop, final.stopReason != .length {
            report.finish(failure: "The model did not complete a text response (\(final.stopReason.rawValue)).")
        } else {
            report.finish()
        }
    }

    static func context() -> Context {
        Context(systemPrompt: nil, messages: [.user(UserMessage(text: "Hi"))], tools: nil)
    }

    static func options(auth: ResolvedProviderAuth?, cancellation: CancellationHandle) -> StreamOptions {
        StreamOptions(
            maxTokens: 2048,
            transport: .sse,
            cacheRetention: CacheRetention.none,
            maxRetryDelayMs: 0,
            resolvedAuth: auth,
            reasoning: nil,
            cancellation: cancellation,
            toolChoice: ToolChoice.none,
            verbose: false,
        )
    }

    /// `start` can be emitted locally, before a connection. Text-start is not
    /// first text: record only a snapshot that actually contains characters.
    static func observe(_ event: AssistantMessageEvent, report: ModelTestReport) {
        switch event {
        case .start:
            break
        case let .textStart(_, partial), let .textDelta(_, _, partial), let .textEnd(_, _, partial),
             let .thinkingStart(_, partial), let .thinkingDelta(_, _, partial), let .thinkingEnd(_, _, partial),
             let .toolCallStart(_, partial), let .toolCallDelta(_, _, partial), let .toolCallEnd(_, _, partial):
            record(partial, report: report, event: true)
        case let .done(_, message):
            record(message, report: report, event: true)
        case let .error(_, message):
            // Errors may be produced locally (encoding/cancellation), not by
            // a remote event. Keep content, but don't fabricate a first event.
            record(message, report: report, event: false)
        }
    }

    private static func record(_ message: AssistantMessage, report: ModelTestReport, event: Bool) {
        let text = message.content.compactMap { block -> String? in
            if case let .text(value) = block { return value.text }
            return nil
        }.joined()
        let thinking = message.content.compactMap { block -> String? in
            if case let .thinking(value) = block { return value.thinking }
            return nil
        }.joined()
        report.record(text: text, thinking: thinking, event: event)
    }

    /// Fixed SDK transports which add required/default instructions even for
    /// nil systemPrompt. Refuse before resolving credentials or sending Hi.
    static func unsupportedPureHiProvider(_ provider: AgentProvider) -> String? {
        switch provider {
        case .anthropicOAuth:
            return "This provider adds a required Claude Code identity prompt, so a pure Hi test is unavailable."
        case .cursor:
            return "This provider adds a default system prompt, so a pure Hi test is unavailable."
        case .qoder, .qoderCN:
            return "This provider adds a required agent system prompt, so a pure Hi test is unavailable."
        case .workBuddy, .workBuddyAI:
            return "This provider adds a default system prompt, so a pure Hi test is unavailable."
        default:
            return nil
        }
    }

    /// No raw error body, URL, header, provider message or token crosses IPC.
    static func safeFailure(_ error: Error, phase: String) -> String {
        if error is ProviderResolutionError { return "No saved sign-in. Sign in again in Model Providers." }
        let failure = ProviderFailure.capture(error)
        let reason: String
        switch failure.outcome {
        case .signInRequired: reason = "Authentication failed. Sign in again."
        case .accessDenied: reason = "This account is not allowed to use the model."
        case .quotaExhausted: reason = "The model account's quota is exhausted."
        case .rateLimited: reason = "The model provider rate-limited the request."
        case .contextTooLong: reason = "The model provider rejected the input as too large."
        case .requestRejected: reason = "The model provider rejected the request."
        case .serviceUnavailable: reason = "The model provider is unavailable."
        case .timeout: reason = "The model request timed out."
        case .network: reason = "The connection to the model provider failed."
        case .contentRefused: reason = "The model provider refused the content."
        case .cancelled: reason = "The model request was cancelled."
        case .unknown: reason = "The model test failed."
        }
        let status = failure.httpStatus.map { " HTTP \($0)." } ?? ""
        return "\(reason)\(status) Stage: \(phase)."
    }
}
