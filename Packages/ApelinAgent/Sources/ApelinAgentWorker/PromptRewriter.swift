import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI

/// Rewrites a composer draft with one turn of the chosen model, and answers the
/// text.
///
/// A turn of its own, not a session: no tools, no history, and nothing written
/// into a conversation. The shape is `AgentSession`'s title pass — a system
/// prompt, one user message, a token cap — because that is the one place this
/// package already asks a model for text with no conversation around it.
///
/// The instructions are a file, `PromptOptimization.md`, read when the wand is
/// tapped rather than compiled in, so what a rewrite is told can change without
/// a build. A reader's own copy in the data folder wins over the one the
/// package installs.
enum PromptRewriter {
    static let instructionsFileName = "PromptOptimization.md"

    /// The instructions as they stand now: the reader's copy in
    /// `~/Documents/wiki.qaq.apelin/` first, then the one the package puts in
    /// `usr/share/apelin/`. A missing or emptied file is passed over, so a copy
    /// cleared by accident falls back to the shipped words instead of failing.
    static func instructions(home: URL, installRoot: String) throws -> String {
        let shipped = URL(fileURLWithPath: installRoot, isDirectory: true)
            .appendingPathComponent("usr/share/apelin", isDirectory: true)
            .appendingPathComponent(instructionsFileName)
        let mine = ApelinDataRoot(home: home).url.appendingPathComponent(instructionsFileName)
        for url in [mine, shipped] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        throw ApelinError(
            .unavailable,
            """
            The prompt optimization instructions are missing from this install. Reinstall Apelin \
            with your preferred package manager, then try again.
            """,
        )
    }

    /// Past this many characters the draft is cut for the model: a rewrite of
    /// the opening is worth more than a request the provider rejects.
    private static let inputLimit = 12000

    /// How long the whole rewrite may take. A composer waiting on a magic wand
    /// is worse than no magic wand, and a reader who wanted to send can still
    /// send.
    private static let timeout: Duration = .seconds(45)

    static func rewrite(
        _ request: AgentRewritePromptRequest,
        home: URL,
        installRoot: String,
        credentials source: any CredentialSource,
    ) async throws -> AgentRewritePromptResponse {
        let draft = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else {
            throw ApelinError(.badRequest, "There is nothing to rewrite.")
        }
        let systemPrompt = try instructions(home: home, installRoot: installRoot)
        // The app names the provider and model it is about to message with, as
        // a prompt does; nothing here reads a setting of its own. A rewrite
        // without a model is refused rather than answered by another provider:
        // the text would come back in a voice the reader did not pick.
        guard let provider = request.provider else {
            throw ApelinError(.badRequest, "Choose a model before rewriting.")
        }
        let configuration = try AgentWorker.provider(
            provider: provider,
            model: request.model,
        )
        let resolved = try await ProviderResolver.resolve(configuration, credentials: source)

        let cancellation = CancellationHandle()
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            cancellation.cancel()
        }
        defer { deadline.cancel() }

        let answer: String = try await withTaskCancellationHandler {
            let auth = try await resolved.authResolver?(resolved.model, nil)
            // The stream the rest of the package uses, so the rewrite rides the
            // same paths as a turn: the caller reads it to its end and takes
            // the message it finishes with.
            let stream = try await KWWKAI.stream(
                model: resolved.model,
                context: Context(
                    systemPrompt: systemPrompt,
                    messages: [.user(UserMessage(text: String(draft.prefix(inputLimit))))],
                ),
                options: StreamOptions(
                    maxTokens: 2048,
                    maxRetryDelayMs: 0,
                    resolvedAuth: auth,
                    reasoning: nil,
                    cancellation: cancellation,
                    verbose: false,
                ),
            )
            for await _ in stream {}
            let final = await stream.result()
            guard final.stopReason == .stop || final.stopReason == .length else {
                throw ApelinError(
                    .badRequest,
                    final.providerFailure?.message ?? "The model did not answer the rewrite.",
                )
            }
            return text(of: final.content)
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        try cancellation.throwIfCancelled()

        let rewritten = unfenced(answer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rewritten.isEmpty else {
            throw ApelinError(.badRequest, "The model returned nothing to use.")
        }
        return AgentRewritePromptResponse(text: rewritten)
    }

    /// The answer's text blocks, joined. A model that also emitted a thought or
    /// a tool call leaves those behind.
    private static func text(of content: [AssistantBlock]) -> String {
        content.compactMap { block -> String? in
            if case let .text(value) = block {
                return value.text
            }
            return nil
        }.joined()
    }

    /// A model that wrapped the answer in a fence despite being asked not to:
    /// the fence goes, its language tag with it.
    private static func unfenced(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 else { return text }
        var inner = text.dropFirst(3).dropLast(3)
        if let newline = inner.firstIndex(where: \.isNewline), inner[..<newline].allSatisfy(\.isLetter) {
            inner = inner[inner.index(after: newline)...]
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
