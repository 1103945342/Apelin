import ApelinProtocol

/// The provider, model, effort, tier and model figures a session runs with
/// now: what its open request named, then what each of the app's prompts
/// named. A conversation the session opens starts with the same.
public actor SessionModelChoice {
    public struct Choice: Sendable, Equatable {
        public var provider: AgentProvider?
        public var model: String?
        public var reasoningEffort: AgentReasoningEffort?
        public var serviceTier: AgentServiceTier?
        public var modelParameters: AgentModelParameters?
    }

    public private(set) var current = Choice()

    public init(
        provider: AgentProvider? = nil,
        model: String? = nil,
        reasoningEffort: AgentReasoningEffort? = nil,
        serviceTier: AgentServiceTier? = nil,
        modelParameters: AgentModelParameters? = nil,
    ) {
        current = Choice(
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            modelParameters: modelParameters,
        )
    }

    public func set(
        provider: AgentProvider?,
        model: String?,
        reasoningEffort: AgentReasoningEffort?,
        serviceTier: AgentServiceTier?,
        modelParameters: AgentModelParameters? = nil,
    ) {
        current = Choice(
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            modelParameters: modelParameters,
        )
    }
}
