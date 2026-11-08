import Foundation

public enum AgentModelTestPhase: String, Codable, Sendable, CaseIterable {
    case credentials
    case preparation
    case authorization
    case firstEvent
    case firstText
    case response
    case total
}

public struct AgentModelTestStage: Codable, Sendable, Equatable {
    public var name: AgentModelTestPhase
    public var milliseconds: Double

    public init(name: AgentModelTestPhase, milliseconds: Double) {
        self.name = name
        self.milliseconds = milliseconds
    }
}

public struct AgentModelTestRequest: OperationRequest {
    public typealias Response = AgentModelTestResponse
    public static let operation = AppOperation.agentModelTest

    public var provider: AgentProvider
    public var model: String

    public init(provider: AgentProvider, model: String) {
        self.provider = provider
        self.model = model
    }
}

public struct AgentModelTestResponse: Codable, Sendable, Equatable {
    public var success: Bool
    public var stages: [AgentModelTestStage]
    public var text: String
    public var thinking: String
    public var failure: String?

    public init(
        success: Bool,
        stages: [AgentModelTestStage] = [],
        text: String = "",
        thinking: String = "",
        failure: String? = nil,
    ) {
        self.success = success
        self.stages = stages
        self.text = text
        self.thinking = thinking
        self.failure = failure
    }
}

public extension ApelinService {
    /// Runs one provider connectivity probe. The worker sends exactly one
    /// user message (`Hi`) without a system prompt, history, or tools.
    func agentModelTest(_ request: AgentModelTestRequest) async throws -> AgentModelTestResponse {
        try await send(request)
    }
}
