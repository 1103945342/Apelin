import ApelinCore
import Foundation

/// Every terminal this app has opened, live or ended, and the records that let
/// one survive a relaunch of the app.
///
/// A session is kept here rather than by the page, so closing the page closes
/// nothing else: the shell the host runs and the record describing it stay, and
/// the next page attaches to the same task. Records are read once, one element
/// at a time (`PreservedList`), and a record whose folder no longer exists is
/// skipped rather than deleted.
///
/// Sessions are matched by `TerminalIdentity` — the record's target *and* the
/// canonical folder — so two folders outside Apelin's own storage, which both
/// record as `.elsewhere`, never share a shell.
///
/// Nothing here ends a shell or drops its record to make room. A record is a
/// shell the host may still be running, and a user cannot reattach to what was
/// deleted for them; when the bookkeeping is full, a new terminal is refused
/// and the page says why.
@MainActor
enum TerminalSessions {
    /// How many shells the app keeps books for at once. The host caps its own
    /// terminals at 32 as well.
    static let maximumSessions = TerminalLimits.sessions

    static let dataRoot = DataFolder.app.root
    private static let store = TerminalSessionStore(root: dataRoot)

    private static var models: [UUID: TerminalSession] = [:]
    private static var order: [UUID] = []
    private static var records = PreservedList<TerminalSessionRecord>()
    private static var didLoadRecords = false
    /// Why records cannot be trusted or written, if that happened: a file that
    /// could not be read is never replaced by an empty one.
    private(set) static var storageProblem: String?
    private static var maySave = true

    /// The session to show for `identity`: one whose shell is live, else one
    /// whose shell this app knew and has not verified yet, else a new one —
    /// nil when the books are full and no shell here is available.
    static func session(for identity: TerminalIdentity) -> TerminalSession? {
        loadRecordsIfNeeded()
        let matching = sessions(for: identity)
        if let live = matching.first(where: { $0.phase == .live }) {
            return live
        }
        if let restorable = matching.first(where: { $0.phase == .reconnecting || $0.phase == .idle }) {
            return restorable
        }
        return newSession(for: identity)
    }

    /// The sessions opened for one place, newest last.
    static func sessions(for identity: TerminalIdentity) -> [TerminalSession] {
        loadRecordsIfNeeded()
        return order.compactMap { models[$0] }.filter { $0.identity == identity }
    }

    /// A session with no shell yet, or nil when the app is already keeping
    /// books for as many shells as it will. A shell is never ended to make
    /// room here.
    static func newSession(for identity: TerminalIdentity) -> TerminalSession? {
        loadRecordsIfNeeded()
        guard runningCount < maximumSessions else {
            return nil
        }
        let session = TerminalSession(identity: identity, dataRoot: dataRoot)
        register(session)
        return session
    }

    /// Shells this app knows the host may still be running: live sessions, and
    /// records whose session is not in memory yet.
    private static var runningCount: Int {
        let live = models.values.filter { !$0.isFinished && $0.taskID != nil }.count
        let recorded = records.items.filter { models[$0.id] == nil }.count
        return live + recorded
    }

    private static func register(_ session: TerminalSession) {
        models[session.id] = session
        if !order.contains(session.id) {
            order.append(session.id)
        }
        session.onRecordChange = { record in
            save(record, for: session.id)
        }
    }

    private static func save(_ record: TerminalSessionRecord?, for id: UUID) {
        loadRecordsIfNeeded()
        guard maySave else {
            // The file on disk could not be read; writing this list over it
            // would make its records unrecoverable.
            return
        }
        records.items.removeAll { $0.id == id }
        if let record {
            records.items.append(record)
        }
        do {
            try store.save(records)
            storageProblem = nil
        } catch {
            storageProblem = error.localizedDescription
        }
    }

    private static func loadRecordsIfNeeded() {
        guard !didLoadRecords else { return }
        didLoadRecords = true
        switch store.load() {
        case .missing:
            records = PreservedList()
        case let .loaded(list):
            records = list
        case let .unreadable(message):
            // Nothing is written over a file nobody could read, and the page
            // says what happened rather than pretending there were no records.
            maySave = false
            storageProblem = message
            records = PreservedList()
        }
        for record in records.items {
            guard models[record.id] == nil else { continue }
            guard let directory = record.target.startDirectory(dataRoot: dataRoot),
                  isDirectory(directory)
            else { continue }
            let identity = TerminalIdentity(target: record.target, directory: directory)
            let session = TerminalSession(
                identity: identity,
                dataRoot: dataRoot,
                record: record
            )
            register(session)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
