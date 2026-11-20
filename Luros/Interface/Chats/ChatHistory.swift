import ApelinProtocol
import Foundation

/// Where a conversation's fold starts. A conversation can hold a hundred
/// thousand events — megabytes of them — and reading all of it to show the
/// last few turns is what made opening a long one take a while. The fold
/// starts at the last turns, and each answer the reader asks for folds in
/// another page of the ones before.
///
/// The window always begins on a prompt, so a turn is never cut in half: the
/// rows of every turn after it are whole.
enum ChatHistory {
    /// Turns kept when a conversation is opened.
    static let turns = 20
    /// Turns folded in each time the reader loads earlier ones.
    static let step = 20

    /// The index among `events` the fold should start at to keep `turns`
    /// prompts and everything after them; 0 when it holds no more than that.
    static func start(of events: [TaskEvent], keeping turns: Int) -> Int {
        guard turns > 0 else { return 0 }
        var seen = 0
        var index = events.count - 1
        while index >= 0 {
            if events[index].kind == "prompt" {
                seen += 1
                if seen >= turns {
                    return index
                }
            }
            index -= 1
        }
        return 0
    }
}
