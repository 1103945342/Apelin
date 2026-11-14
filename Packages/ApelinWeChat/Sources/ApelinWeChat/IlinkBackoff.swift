import Foundation

/// The pause between failed `getupdates` rounds: 2 s, doubling, no more than
/// 60 s. Attempt 0 is the first failure, so it waits the initial delay.
public struct IlinkBackoff: Sendable, Equatable {
    public var initial: TimeInterval
    public var maximum: TimeInterval
    public var multiplier: Double

    public init(initial: TimeInterval = 2, maximum: TimeInterval = 60, multiplier: Double = 2) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
    }

    public func delay(forAttempt attempt: Int) -> Duration {
        guard attempt > 0 else { return .seconds(initial) }
        var seconds = initial * pow(multiplier, Double(attempt))
        if seconds > maximum { seconds = maximum }
        if seconds < 0 || !seconds.isFinite { seconds = maximum }
        return .seconds(seconds)
    }

    /// The same delay in whole seconds, for a log line.
    public func seconds(forAttempt attempt: Int) -> Int {
        let duration = delay(forAttempt: attempt)
        return Int(duration.components.seconds)
    }
}
