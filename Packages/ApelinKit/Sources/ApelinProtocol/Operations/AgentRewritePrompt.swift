import Foundation

/// One turn of a model with no conversation around it: what the composer's
/// rewrite button sends.
///
/// Deliberately not a session. A rewrite is a single answer, it takes no tools,
/// and it must not appear in any conversation's history — an agent session would
/// give it all three of those things and a task to clean up afterwards.
public struct AgentRewritePromptRequest: OperationRequest {
    public typealias Response = AgentRewritePromptResponse
    public static let operation = AppOperation.agentRewritePrompt

    /// What the reader typed.
    public var text: String
    /// Which account and model to ask. Nil takes the app's current choice, as
    /// a message does.
    public var provider: AgentProvider?
    public var model: String?

    public init(text: String, provider: AgentProvider? = nil, model: String? = nil) {
        self.text = text
        self.provider = provider
        self.model = model
    }
}

public struct AgentRewritePromptResponse: Codable, Sendable, Equatable {
    /// The rewritten prompt, without the wrapper the model was asked to use.
    public var text: String

    public init(text: String) {
        self.text = text
    }
}
