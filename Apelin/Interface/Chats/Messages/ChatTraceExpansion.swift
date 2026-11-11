import Foundation

/// What the reader has opened in the transcript's process rows: a summary
/// whose steps are shown under its title, a thought shown as prose, and a
/// call showing what it was told and what it answered. aimini's chat folds
/// every one of them away until asked, and keeps what the reader asked for
/// over what the chat would have shown.
///
/// An id with no entry here takes the default the row computes — a summary
/// of a run still going is open, everything else is folded — so the reader's
/// own choice is what is remembered, not a copy of the default. Kept for as
/// long as the app runs, never written to disk: a row the list pooled and
/// took back comes back as the reader left it, and a conversation opened
/// again starts as the chat shows it. An id kept for a message no longer on
/// screen costs a few bytes and matches nothing.
@MainActor
enum ChatTraceExpansion {
    private static var summaries: [UUID: Bool] = [:]
    private static var thoughts: [UUID: Bool] = [:]
    private static var calls: [UUID: Bool] = [:]

    /// Whether summary `id` shows its steps: what the reader chose, else
    /// `fallback`.
    static func isExpanded(summary id: UUID, fallback: Bool) -> Bool {
        summaries[id] ?? fallback
    }

    static func setExpanded(summary id: UUID, _ expanded: Bool) {
        summaries[id] = expanded
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
