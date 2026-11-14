import ApelinCore
import Foundation

/// One row of the terminal page's sessions list, and the rules the list obeys,
/// with no UIKit in sight: the page makes an entry from each `TerminalSession`,
/// the list controller draws them, and `Tests/TerminalUI` checks the deletion
/// decisions against the same source the app runs.
///
/// Why the rules live here: deleting is the one row action that destroys
/// something, and what it may destroy — only a terminal that ended — and which
/// terminal the page shows afterwards are worth checking without a device.
struct TerminalSessionListEntry: Equatable {
    enum Status: Equatable {
        case running
        case connecting
        case ended
        case unavailable
    }

    let id: UUID
    let title: String
    let status: Status

    /// Only a terminal that ended may be forgotten. One that is running, still
    /// connecting or failed keeps its place: the host may still have a shell
    /// for it, and a record is a shell a user cannot reattach to once it is
    /// gone.
    var canDelete: Bool {
        status == .ended
    }
}

/// What deleting a row of the list the user is looking at would mean.
enum TerminalSessionListRemoval: Equatable {
    /// The row may go. `nextCurrent` is the session the page should show once
    /// it has: nil when no terminal is left at all.
    case remove(nextCurrent: UUID?)
    /// The row is not one that ended, so it is never deleted.
    case refusedStillRunning
    /// The row is no longer in the list.
    case refusedUnknown
}

/// What became of a deletion the page actually performed, re-checked against
/// the live session rather than the row the user tapped.
enum TerminalSessionDeletionOutcome: Equatable {
    case removed
    /// Between the tap and the deletion the session stopped being one that
    /// ended — it is kept.
    case stillRunning
    case notFound
    /// The record on disk could not be rewritten. The session and its record
    /// stay as they were, and the message says what failed.
    case failed(String)
}

enum TerminalSessionList {
    /// The decision for deleting `id` from `entries`, which are in the order the
    /// list shows them (oldest first), with `current` the one on screen.
    ///
    /// Deleting the session on screen moves the page to the row that took its
    /// place, or to the last one left; deleting any other row leaves the
    /// screen exactly as it is.
    static func removal(
        of id: UUID,
        from entries: [TerminalSessionListEntry],
        current: UUID?
    ) -> TerminalSessionListRemoval {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return .refusedUnknown
        }
        guard entries[index].canDelete else {
            return .refusedStillRunning
        }
        let remaining = entries.enumerated()
            .filter { $0.offset != index }
            .map(\.element)
        guard current == id else {
            let stays = remaining.contains { $0.id == current }
            return .remove(nextCurrent: stays ? current : nil)
        }
        let next = remaining.indices.contains(index) ? remaining[index] : remaining.last
        return .remove(nextCurrent: next?.id)
    }

    /// The record list with `id` taken out, and every other record — including
    /// one this version cannot read — left exactly as it was.
    ///
    /// Nothing else is touched: the session's folder and the host's task log
    /// are not this list's to delete.
    static func records(
        _ list: PreservedList<TerminalSessionRecord>,
        removing id: UUID
    ) -> PreservedList<TerminalSessionRecord> {
        var next = list
        next.items.removeAll { $0.id == id }
        return next
    }
}
