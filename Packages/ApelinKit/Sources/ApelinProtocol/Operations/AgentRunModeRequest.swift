import Foundation

/// A request that the conversation change its run mode (`apelin_run_mode`,
/// 2026-11-11): the mode asked for, and the agent's own sentence saying why,
/// which the card shows the reader before they agree.
///
/// A switch to `plan` is the agent's to make, with nobody asked: a plan run
/// can only read, so stopping to ask would leave a task too large for one
/// step unthought-through. A switch to `build` hands the run the work the
/// plan refused, so it is the reader's decision and rides the approval path
/// as `detail.runMode`, as a question does.
public struct AgentRunModeRequest: Sendable, Hashable, Codable {
    public var mode: AgentRunMode
    public var reason: String

    public init(mode: AgentRunMode, reason: String) {
        self.mode = mode
        self.reason = reason
    }
}

public enum AgentRunModeRules {
    /// The key of `detail` in the call's `approvalRequested`.
    public static let detailKey = "runMode"
    /// One or two sentences: why the conversation should go the other way.
    public static let maximumReasonLength = 300
    /// The modes an agent may ask for. `auto` is the reader's alone: a run
    /// that stops asking is a choice about the device, not about the task.
    public static let requestable: [AgentRunMode] = [.plan, .build]
}
