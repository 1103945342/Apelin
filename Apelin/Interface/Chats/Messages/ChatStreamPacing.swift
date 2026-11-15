import Foundation

/// How often a thought the model is still writing is drawn again.
///
/// An opened thought is one label holding all of it, and the model writes it a
/// token at a time: redrawing and measuring the whole text on every event of a
/// long run is what made an opened thought stutter. The row that draws it and
/// the list's height measurement ask this same clock, keyed by the step, so
/// what is measured is what is drawn — a little behind the stream, never ahead
/// of the row, which would clip it.
@MainActor
enum ChatStreamPacing {
    /// Between two drawings of a thought still being written: long enough to
    /// keep the label's layout off the stream's path, short enough to read as
    /// writing.
    static let interval: TimeInterval = 0.3

    /// How much of a thought still being written its text draws: the newest
    /// of it, which is what a reader watching a run wants, and never a label
    /// whose layout grows with the run. The whole of it is drawn once it has
    /// stopped.
    static let streamingLength = 6000

    /// What a shortened text starts with.
    static let mark = "…"

    private struct Drawn {
        var text: String
        var at: Date
    }

    private static var drawn: [UUID: Drawn] = [:]
    /// Past this many the older entries go: only the thoughts of a run still
    /// being written are worth keeping.
    private static let capacity = 64

    /// What step `id` draws now: its text whole once the thought has stopped,
    /// else the end of it as of the last drawing, advanced at most every
    /// `interval` and at most `streamingLength` long.
    static func text(of id: UUID, newest: String, streaming: Bool, now: Date = Date()) -> String {
        guard streaming else {
            drawn[id] = nil
            return newest
        }
        if let entry = drawn[id], now.timeIntervalSince(entry.at) < interval {
            return entry.text
        }
        let text = shortened(newest)
        if drawn.count >= capacity {
            forgetOlder(than: now.addingTimeInterval(-interval * 20))
        }
        drawn[id] = Drawn(text: text, at: now)
        return text
    }

    /// Forget what was drawn: the conversation on screen has changed.
    static func forget() {
        drawn.removeAll(keepingCapacity: true)
    }

    /// The newest `streamingLength` characters of `newest`, marked when any
    /// were left out.
    private static func shortened(_ newest: String) -> String {
        guard newest.count > streamingLength else { return newest }
        return mark + newest.suffix(streamingLength)
    }

    private static func forgetOlder(than date: Date) {
        drawn = drawn.filter { $0.value.at >= date }
        if drawn.count >= capacity {
            drawn.removeAll(keepingCapacity: true)
        }
    }
}
