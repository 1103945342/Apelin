import Foundation

/// Which pick is judged before it is taken: the chat's own figure against the
/// model's window, with neither known letting it through as it always did.
func checkModelSwitchFit() {
    precondition(ModelSwitchFit.evaluate(used: 900_000, candidateWindow: 1_000_000) == .fits)
    precondition(ModelSwitchFit.evaluate(used: 1_000_000, candidateWindow: 1_000_000) == .fits, "exactly full still fits")
    precondition(ModelSwitchFit.evaluate(used: 900_000, candidateWindow: 272_000) == .over(used: 900_000, window: 272_000))
    precondition(ModelSwitchFit.evaluate(used: 272_001, candidateWindow: 272_000) == .over(used: 272_001, window: 272_000))
    precondition(ModelSwitchFit.evaluate(used: 900_000, candidateWindow: 0) == .unknown, "a window nothing states is not a refusal")
    precondition(ModelSwitchFit.evaluate(used: 900_000, candidateWindow: nil) == .unknown)
    precondition(ModelSwitchFit.evaluate(used: nil, candidateWindow: 272_000) == .unknown, "a chat that never ran says nothing")
    precondition(ModelSwitchFit.evaluate(used: 0, candidateWindow: 272_000) == .unknown)
    print("ok: a pick is judged against the chat's own figure, and an unknown one goes through")
}
