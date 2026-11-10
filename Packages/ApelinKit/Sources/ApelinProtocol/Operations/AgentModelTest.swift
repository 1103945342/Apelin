import ApelinCore
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

/// One stage of a probe as it happens: the phase, and — once it has ended —
/// what it cost. A phase's event without `milliseconds` says it started; the
/// one that carries them says it ended. They travel as the task's `stage`
/// events, so a page shows the probe moving instead of waiting for the report.
public struct AgentModelTestProgress: Codable, Sendable, Equatable {
    /// The `kind` of the task event carrying one of these.
    public static let eventKind = "stage"

    public var phase: AgentModelTestPhase
    public var milliseconds: Double?

    public init(phase: AgentModelTestPhase, milliseconds: Double? = nil) {
        self.phase = phase
        self.milliseconds = milliseconds
    }

    /// The event payload: `{"phase": …, "milliseconds": …}`.
    public var payload: JSONValue {
        var object: [String: JSONValue] = ["phase": .string(phase.rawValue)]
        if let milliseconds { object["milliseconds"] = .number(milliseconds) }
        return .object(object)
    }

    public init?(payload: JSONValue?) {
        guard let phase = payload?["phase"]?.stringValue
            .flatMap(AgentModelTestPhase.init(rawValue:))
        else { return nil }
        self.phase = phase
        milliseconds = payload?["milliseconds"]?.doubleValue
    }
}

/// Starts one provider connectivity probe: a task of kind `modelTest`, read
/// with `agentAttach`. It answers at once with the task's handle; its events
/// are `stage` ones as each phase runs, then the final `state`, which carries
/// the report under `result`.
public struct AgentModelTestRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.agentModelTest

    public var provider: AgentProvider
    public var model: String

    public init(provider: AgentProvider, model: String) {
        self.provider = provider
        self.model = model
    }
}

public struct AgentModelTestResponse: Codable, Sendable, Equatable {
    /// The member of the task's final `state` payload that holds this report.
    public static let stateMember = "result"

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
    /// Starts one provider connectivity probe. The worker sends exactly one
    /// user message (`Hi`) without a system prompt, history, or tools; the
    /// report arrives as the `result` of the task's final `state`.
    func agentModelTest(_ request: AgentModelTestRequest) async throws -> TaskHandle {
        try await send(request)
    }
}
