import Foundation

/// The mode the conversation's *next* run goes with, told to a session that
/// is already open — a reader who changes the pill while a run is working
/// wants the message queued behind it to run that way, not this one to be
/// stopped or limited halfway. Nil puts the conversation back to whatever its
/// next prompt says.
///
/// A prompt always carries its own mode (`AgentPromptRequest.runMode`), which
/// wins over this one; the mode set here is what the run a queue starts after
/// this one ends goes with, since no prompt travels with it.
public struct AgentSetRunModeRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentSetRunMode

    public var sessionID: String
    public var mode: AgentRunMode?

    public init(sessionID: String, mode: AgentRunMode?) {
        self.sessionID = sessionID
        self.mode = mode
    }
}

public extension LurosService {
    @discardableResult
    func agentSetRunMode(sessionID: String, mode: AgentRunMode?) async throws -> Acknowledged {
        try await send(AgentSetRunModeRequest(sessionID: sessionID, mode: mode))
    }
}
