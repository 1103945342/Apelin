import ApelinCore
import Foundation

/// The terminal sessions list's rules, from the same source the app runs
/// (`TerminalSessionList.swift`): which rows may be deleted, which terminal the
/// page shows after deleting one, and what a deletion does to the record file.
/// Run by `Tests/TerminalUI/run.sh`.
enum TerminalSessionListCheck {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("ok   \(message)")
        } else {
            failures += 1
            print("FAIL \(message)")
        }
    }

    static func entry(
        _ title: String,
        _ status: TerminalSessionListEntry.Status
    ) -> TerminalSessionListEntry {
        TerminalSessionListEntry(id: UUID(), title: title, status: status)
    }

    static func record(taskID: String) -> TerminalSessionRecord {
        TerminalSessionRecord(
            id: UUID(),
            target: TerminalTarget(location: .project(folder: "Project", relativePath: nil)),
            taskID: taskID,
            sessionID: "session-" + taskID,
            title: "Project",
            openedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    static func run() -> Int {
        failures = 0

        // Only a terminal that ended may be deleted. A failed one may still
        // have a shell on the host, so it is not an ended one.
        check(entry("ended", .ended).canDelete, "an ended row can be deleted")
        check(!entry("running", .running).canDelete, "a running row cannot be deleted")
        check(!entry("connecting", .connecting).canDelete, "a connecting row cannot be deleted")
        check(!entry("unavailable", .unavailable).canDelete, "a failed row cannot be deleted")

        // Deleting a row that is not the one on screen keeps the screen.
        var entries = [
            entry("a", .running),
            entry("b", .ended),
            entry("c", .running),
        ]
        check(
            TerminalSessionList.removal(of: entries[1].id, from: entries, current: entries[0].id)
                == .remove(nextCurrent: entries[0].id),
            "deleting another row leaves the current one"
        )

        // Deleting the row on screen moves to the row that took its place.
        entries = [
            entry("a", .ended),
            entry("b", .running),
            entry("c", .ended),
        ]
        check(
            TerminalSessionList.removal(of: entries[0].id, from: entries, current: entries[0].id)
                == .remove(nextCurrent: entries[1].id),
            "deleting the first row shows the next one"
        )

        // The last row, deleted while on screen: the one before it remains.
        entries = [
            entry("a", .running),
            entry("b", .ended),
            entry("c", .ended),
        ]
        check(
            TerminalSessionList.removal(of: entries[2].id, from: entries, current: entries[2].id)
                == .remove(nextCurrent: entries[1].id),
            "deleting the last row shows the one before it"
        )

        // The only row: nothing is left, and nothing is opened in its place.
        let only = entry("only", .ended)
        check(
            TerminalSessionList.removal(of: only.id, from: [only], current: only.id)
                == .remove(nextCurrent: nil),
            "deleting the only row leaves no current terminal"
        )

        // A row that did not end is refused, whatever the page is showing.
        entries = [
            entry("a", .running),
            entry("b", .connecting),
            entry("c", .unavailable),
            entry("d", .ended),
        ]
        check(
            TerminalSessionList.removal(of: entries[0].id, from: entries, current: entries[3].id)
                == .refusedStillRunning,
            "a running row is refused"
        )
        check(
            TerminalSessionList.removal(of: entries[1].id, from: entries, current: entries[3].id)
                == .refusedStillRunning,
            "a connecting row is refused"
        )
        check(
            TerminalSessionList.removal(of: entries[2].id, from: entries, current: entries[3].id)
                == .refusedStillRunning,
            "a failed row is refused"
        )

        // A row the list no longer has.
        check(
            TerminalSessionList.removal(of: UUID(), from: entries, current: entries[3].id)
                == .refusedUnknown,
            "an unknown row is refused"
        )

        // Nothing is current (the sheet opened over an empty page): deleting a
        // row cannot invent a current one.
        entries = [entry("a", .ended), entry("b", .ended)]
        check(
            TerminalSessionList.removal(of: entries[0].id, from: entries, current: nil)
                == .remove(nextCurrent: nil),
            "a deletion with no current row picks none"
        )

        // The record list: only the deleted record goes, and a record this
        // version cannot read is kept as it was.
        let first = record(taskID: "task-1")
        let second = record(taskID: "task-2")
        let third = record(taskID: "task-3")
        let list = PreservedList([first, second, third])
        let afterRemoval = TerminalSessionList.records(list, removing: second.id)
        check(afterRemoval.items == [first, third], "only the deleted record leaves the list")
        check(list.items == [first, second, third], "the original record list is not changed")

        let unknownRemoval = TerminalSessionList.records(list, removing: UUID())
        check(unknownRemoval.items == list.items, "deleting a record that is not there changes nothing")

        let good = String(data: try! JSONCoding.encode(second), encoding: .utf8)!
        let mixed = """
        [
          \(good),
          {"bogus":true}
        ]
        """
        var decoded = PreservedList<TerminalSessionRecord>()
        if let parsed = try? JSONCoding.decode(
            PreservedList<TerminalSessionRecord>.self,
            from: Data(mixed.utf8)
        ) {
            decoded = parsed
        }
        check(decoded.items == [second], "the mixed file reads its one good record")
        check(decoded.unreadable.count == 1, "the mixed file keeps its unreadable element")
        let mixedAfter = TerminalSessionList.records(decoded, removing: second.id)
        check(mixedAfter.items.isEmpty, "the deleted record is gone from the mixed list")
        check(
            mixedAfter.unreadable.count == 1,
            "an unreadable record survives a deletion"
        )

        // A deletion is written before it is forgotten: a file that cannot be
        // written leaves every record where it was, and the same deletion goes
        // through once the file can be written again.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("apelin-terminal-delete-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("Terminals/sessions.json")
        let folder = file.deletingLastPathComponent()
        let store = TerminalSessionStore(file: file)
        let kept = record(taskID: "task-kept")
        let doomed = record(taskID: "task-doomed")
        try? store.save(PreservedList([kept, doomed]))
        let reduced = TerminalSessionList.records(
            PreservedList([kept, doomed]),
            removing: doomed.id
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: folder.path
        )
        var refused = false
        do {
            try store.save(reduced)
        } catch {
            refused = true
        }
        check(refused, "a save into a folder that cannot be written fails")
        var stillThere: [TerminalSessionRecord] = []
        if case let .loaded(list) = store.load() {
            stillThere = list.items
        }
        check(stillThere == [kept, doomed], "a failed save leaves every record in the file")
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: folder.path
        )
        try? store.save(reduced)
        var afterRetry: [TerminalSessionRecord] = []
        if case let .loaded(list) = store.load() {
            afterRetry = list.items
        }
        check(afterRetry == [kept], "the same deletion writes through on a retry")

        print(failures == 0 ? "TerminalSessionListCheck: all checks passed" : "TerminalSessionListCheck: \(failures) failed")
        return failures
    }
}
