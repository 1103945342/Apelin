import Foundation

/// What the empty box says in place of a placeholder: a tip, then another,
/// rolled every few seconds. The box is the one control a reader has in front
/// of them the whole time they are in a conversation, and it has room for one
/// line — asking a question there and never answering it wastes the line.
enum ComposerTips {
    /// In the order they roll. Each fits one line of the band at the default
    /// size: the placeholder is a single line and the band clips what grows
    /// past it.
    static var all: [String] {
        [
            String(localized: "Try typing / in the message box"),
            String(localized: "Hallucinations? Try compacting the context."),
            String(localized: "A shorter context keeps the model focused."),
            String(localized: "Long-press go-to-bottom to fold the process."),
            String(localized: "For complex tasks, let the model plan first."),
        ]
    }

    /// The one about folding what the reader opened, as its place in `all`:
    /// shown first while something in the transcript is open, since that is
    /// the moment it is about.
    static let collapseHint = 3
}

/// Which tip is showing and which comes next. Counted here, clocked by the
/// view: the order is the part worth reasoning about, and it walks without a
/// label, a timer or a run loop.
struct ComposerTipRotation {
    let count: Int
    private(set) var index: Int

    init(count: Int, index: Int = 0) {
        self.count = max(0, count)
        self.index = self.count > 0 ? min(max(0, index), self.count - 1) : 0
    }

    /// The tip after this one, wrapping back to the first.
    mutating func advance() {
        guard count > 0 else { return }
        index = (index + 1) % count
    }

    /// Shows `target` now, or the tip nearest to it when it is off the list.
    mutating func lead(_ target: Int) {
        guard count > 0 else { return }
        index = min(max(0, target), count - 1)
    }
}
