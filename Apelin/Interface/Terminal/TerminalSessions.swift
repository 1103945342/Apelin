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
/// and the page says why. The one way a record goes is the reader deleting a
/// terminal they can see has ended (`remove`), and only that.
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

    /// The session with this id, when the app still keeps it: what a list row
    /// names, and what the page switches to after a deletion.
    static func session(_ id: UUID) -> TerminalSession? {
        loadRecordsIfNeeded()
        return models[id]
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
        // The id, not the session: the session holds this closure, and holding
        // it back would keep every session alive for as long as the app runs.
        let id = session.id
        session.onRecordChange = { record in
            save(record, for: id)
        }
    }

    /// Forgets one terminal that ended: its model and its record, and nothing
    /// else. The folder it ran in and the host's task log for it are left as
    /// they are, and no other shell is touched.
    ///
    /// The state is checked here rather than trusted from the row the reader
    /// tapped — a session that stopped being one that ended is kept — and the
    /// record is written before anything is forgotten: when the write fails the
    /// session and its record stay, and the page shows why.
    static func remove(_ id: UUID) -> TerminalSessionDeletionOutcome {
        loadRecordsIfNeeded()
        guard let session = models[id] else {
            return .notFound
        }
        guard session.isRemovable else {
            return .stillRunning
        }
        let hadRecord = records.items.contains { $0.id == id }
        if hadRecord {
            guard maySave else {
                return .failed(storageProblem ?? String(localized: "The terminal is not available."))
            }
            let remaining = TerminalSessionList.records(records, removing: id)
            do {
                try store.save(remaining)
            } catch {
                storageProblem = error.localizedDescription
                return .failed(storageProblem ?? error.localizedDescription)
            }
            records = remaining
            storageProblem = nil
        }
        models.removeValue(forKey: id)
        order.removeAll { $0 == id }
        // Nothing may reach the removed session any more: a late change must
        // not write its record back, or put it on screen again.
        session.onChange = nil
        session.onTruncation = nil
        session.onRecordChange = nil
        session.detach()
        return .removed
    }

    private static func save(_ record: TerminalSessionRecord?, for id: UUID) {
        loadRecordsIfNeeded()
        guard maySave else {
            // The file on disk could not be read; writing this list over it
            // would make its records unrecoverable.
            return
        }
        // The file is written before the list in memory changes: when the
        // write fails, the record still on disk must still be the one the app
        // holds, or a later deletion would think there is nothing left to
        // remove and leave it behind.
        var candidate = records
        candidate.items.removeAll { $0.id == id }
        if let record {
            candidate.items.append(record)
        }
        do {
            try store.save(candidate)
            records = candidate
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
