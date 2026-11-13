import ApelinCore
import Foundation

/// `Terminals/sessions.json`: what survives a relaunch, what one unreadable
/// record costs the others, what a file that is not a list at all does, and
/// what a file that cannot be read at all is never allowed to cost. Run by
/// `Tests/TerminalUI/run.sh`.
enum TerminalSessionStoreCheck {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("ok   \(message)")
        } else {
            failures += 1
            print("FAIL \(message)")
        }
    }

    static func record(
        project: String = "Project",
        relativePath: String? = nil,
        taskID: String = "task-1",
        openedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> TerminalSessionRecord {
        TerminalSessionRecord(
            id: UUID(),
            target: TerminalTarget(location: .project(folder: project, relativePath: relativePath)),
            taskID: taskID,
            sessionID: "session-1",
            title: "Project",
            openedAt: openedAt
        )
    }

    static func run() -> Int {
        failures = 0
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("apelin-terminal-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Nothing there yet: a first run, not a failure.
        let file = base.appendingPathComponent("Terminals/sessions.json")
        let store = TerminalSessionStore(file: file)
        if case .missing = store.load() {
            check(true, "a missing file reads as a first run")
        } else {
            check(false, "a missing file reads as a first run")
        }

        let first = record(relativePath: "Sources/App", taskID: "task-a")
        try? store.save(PreservedList([first]))
        var loadedItems: [TerminalSessionRecord] = []
        switch store.load() {
        case let .loaded(list):
            loadedItems = list.items
        case .missing, .unreadable:
            break
        }
        check(loadedItems == [first], "a record round-trips through the file")
        check(FileManager.default.fileExists(atPath: file.path), "saving writes the file")

        // One record this version cannot read is kept, not dropped, and never
        // takes the good one with it.
        let unreadableRaw = #"{"bogus":true}"#
        let mixed = """
        [
          \(String(data: try! JSONCoding.encode(first), encoding: .utf8)!),
          {"bogus":true}
        ]
        """
        try? Data(mixed.utf8).write(to: file, options: .atomic)
        var partial = PreservedList<TerminalSessionRecord>()
        switch store.load() {
        case let .loaded(list):
            partial = list
        case .missing, .unreadable:
            break
        }
        check(partial.items == [first], "an unreadable record does not take the readable one")
        check(partial.unreadable.count == 1, "the unreadable record is kept as it was")
        check(partial.unreadable.first == (try? JSONCoding.decode(JSONValue.self, from: Data(unreadableRaw.utf8))),
              "the unreadable record is kept byte for byte as JSON")
        try? store.save(partial)
        switch store.load() {
        case let .loaded(list):
            check(list.items == [first] && list.unreadable.count == 1,
                  "saving the list back keeps the unreadable element")
        case .missing, .unreadable:
            check(false, "saving the list back keeps the unreadable element")
        }

        // A file that is not a list at all is set aside, never overwritten.
        try? Data("not a list".utf8).write(to: file, options: .atomic)
        switch store.load() {
        case let .loaded(list):
            check(list.items.isEmpty, "a file that does not decode reads as no records")
        case .missing, .unreadable:
            check(false, "a file that does not decode reads as no records")
        }
        let siblings = (try? FileManager.default.contentsOfDirectory(
            atPath: base.appendingPathComponent("Terminals").path
        )) ?? []
        check(siblings.contains { $0.hasPrefix("sessions.json.unreadable-") },
              "a file that does not decode is set aside")

        // A file that cannot be read at all is reported, and left where it is.
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        switch store.load() {
        case let .unreadable(message):
            check(!message.isEmpty, "a file that cannot be read is reported, not read as empty")
        case .missing, .loaded:
            check(false, "a file that cannot be read is reported, not read as empty")
        }
        var isDirectory: ObjCBool = false
        check(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue,
              "a file that cannot be read is left in place for its owner")

        // No record is dropped for being old: a record is a shell the host may
        // still be running, and a user cannot reattach to what was deleted.
        try? FileManager.default.removeItem(at: file)
        let many = (0 ..< (TerminalLimits.sessions + 8)).map { index in
            record(taskID: "task-\(index)", openedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)))
        }
        try? store.save(PreservedList(many))
        switch store.load() {
        case let .loaded(list):
            check(list.items.count == many.count, "every record is written and read back, none trimmed")
        case .missing, .unreadable:
            check(false, "every record is written and read back, none trimmed")
        }

        print(failures == 0 ? "TerminalSessionStoreCheck: all checks passed" : "TerminalSessionStoreCheck: \(failures) failed")
        return failures
    }
}
