import Foundation

/// What the reader has opened in the transcript's process rows: a summary
/// whose steps are shown under its title, and a call whose instruction and
/// result are shown under its own line. aimini's chat keeps both folded until
/// asked, and a call is asked for one at a time.
///
/// Kept for as long as the app runs, never written to disk: a row the list
/// pooled and took back comes back as the reader left it, and a conversation
/// opened again starts folded, as aimini's does. An id kept for a message no
/// longer on screen costs a few bytes and matches nothing.
@MainActor
enum ChatTraceExpansion {
    private static var summaries: Set<UUID> = []
    private static var calls: Set<UUID> = []

    /// Whether summary `id` shows its steps.
    static func isExpanded(summary id: UUID) -> Bool {
        summaries.contains(id)
    }

    static func toggle(summary id: UUID) {
        if summaries.contains(id) {
            summaries.remove(id)
        } else {
            summaries.insert(id)
        }
    }

    /// Whether call `id` shows what it was told and what it answered.
    static func isExpanded(call id: UUID) -> Bool {
        calls.contains(id)
    }

    static func toggle(call id: UUID) {
        if calls.contains(id) {
            calls.remove(id)
        } else {
            calls.insert(id)
        }
    }
}
