import Foundation

/// What the reader has opened in the transcript: a turn's process, a thought
/// shown as prose, and a call showing what it was told and what it answered.
/// aimini's chat folds every one of them away until asked, and keeps what the
/// reader asked for over what the chat would have shown.
///
/// A turn's process is the one thing the transcript itself draws differently:
/// folded, its steps are not rows at all, and the turn header is the only way
/// in. Everything else is a row that redraws itself. Kept for as long as the
/// app runs, never written to disk: a row the list pooled and took back comes
/// back as the reader left it, and a conversation opened again starts folded.
/// An id kept for a message no longer on screen costs a few bytes and matches
/// nothing.
@MainActor
enum ChatTraceExpansion {
    private static var turns: [UUID: Bool] = [:]
    private static var thoughts: [UUID: Bool] = [:]
    private static var calls: [UUID: Bool] = [:]

    /// Forget only the shown conversation's rows, including nested steps.
    /// Other conversations keep what their reader opened.
    static func collapse(ids: Set<UUID>) {
        for id in ids {
            turns.removeValue(forKey: id)
            thoughts.removeValue(forKey: id)
            calls.removeValue(forKey: id)
        }
    }

    /// Whether turn `id` shows its process, folded unless the reader opened
    /// it.
    static func isExpanded(turn id: UUID) -> Bool {
        turns[id] == true
    }

    static func setExpanded(turn id: UUID, _ expanded: Bool) {
        turns[id] = expanded
    }

    /// Whether thought `id` shows its text, folded unless the reader opened
    /// it.
    static func isExpanded(thought id: UUID) -> Bool {
        thoughts[id] == true
    }

    static func setExpanded(thought id: UUID, _ expanded: Bool) {
        thoughts[id] = expanded
    }

    /// Whether call `id` shows what it was told and what it answered.
    static func isExpanded(call id: UUID) -> Bool {
        calls[id] == true
    }

    static func setExpanded(call id: UUID, _ expanded: Bool) {
        calls[id] = expanded
    }
}
