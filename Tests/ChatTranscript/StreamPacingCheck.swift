import Foundation

/// A thought the model is still writing is drawn a few times a second, and
/// shortened while it streams: one label holds it, and redrawing and measuring
/// all of it on every event of a long run is what made an opened thought
/// stutter.
@MainActor
func checkStreamPacing() {
    ChatStreamPacing.forget()
    let step = UUID()
    let start = Date(timeIntervalSince1970: 1000)
    func text(_ newest: String, streaming: Bool = true, after: TimeInterval) -> String {
        ChatStreamPacing.text(of: step, newest: newest, streaming: streaming, now: start.addingTimeInterval(after))
    }

    precondition(text("Thinking", after: 0) == "Thinking")
    precondition(text("Thinking about the hook", after: 0.1) == "Thinking", "a redraw waits for the interval")
    precondition(text("Thinking about the hook", after: 0.31) == "Thinking about the hook")
    precondition(text("Thinking about the hook, then more", after: 0.5) == "Thinking about the hook",
                 "the clock starts again at the drawing")

    // A finished thought is drawn whole at once, however long it is.
    let long = String(repeating: "reasoning. ", count: 2000)
    precondition(text(long, streaming: true, after: 0.65).count == ChatStreamPacing.streamingLength + 1)
    let shortened = text(long, streaming: true, after: 0.9)
    precondition(shortened.hasPrefix(ChatStreamPacing.mark), "a shortened text says so")
    precondition(shortened.hasSuffix(String(long.suffix(40))), "and keeps the newest of it")
    precondition(text(long, streaming: false, after: 0.95) == long, "finished, the whole of it")
    precondition(text("after", streaming: false, after: 0.96) == "after",
                 "and a finished thought is never held back")

    // A text exactly at the limit is not shortened, and a second step has a
    // clock of its own.
    let exact = String(repeating: "x", count: ChatStreamPacing.streamingLength)
    let other = UUID()
    precondition(ChatStreamPacing.text(of: other, newest: exact, streaming: true,
                                      now: start.addingTimeInterval(2)) == exact)
    precondition(ChatStreamPacing.text(of: step, newest: "another", streaming: true,
                                      now: start.addingTimeInterval(2)) == "another",
                 "the second step's own clock")

    ChatStreamPacing.forget()
    print("ok: a streaming thought is drawn every \(ChatStreamPacing.interval)s, shortened while it streams, whole once it ends")
}
