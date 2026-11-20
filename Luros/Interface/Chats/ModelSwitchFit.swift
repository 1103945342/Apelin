import Foundation

/// Whether this conversation fits the model the reader just picked.
///
/// Two figures, and nothing else: what the chat already takes, which is what
/// the ring draws, and what the model that would answer holds. Both come from
/// outside — `ModelSwitchFit` decides nothing about where they came from, so
/// the rule can be read and tested on its own.
enum ModelSwitchFit: Equatable {
    /// The model holds at least what the conversation takes.
    case fits
    /// One of the figures is missing: no turn has recorded what the chat
    /// takes yet, or no catalog lists a window for the model. The pick goes
    /// through as it always did.
    case unknown
    /// The conversation already takes more than the model holds, and a
    /// request would arrive over its limit.
    case over(used: Int, window: Int)

    static func evaluate(used: Int?, candidateWindow: Int?) -> Self {
        guard let used, used > 0 else { return .unknown }
        guard let candidateWindow, candidateWindow > 0 else { return .unknown }
        return used <= candidateWindow ? .fits : .over(used: used, window: candidateWindow)
    }
}
