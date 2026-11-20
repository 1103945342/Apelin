import ApelinCore
import Foundation

/// How many shells the app keeps books for at once. The host caps its own
/// terminals at the same number; reaching the cap refuses a new terminal rather
/// than ending one the reader may still be using.
enum TerminalLimits {
    static let sessions = 32
}

/// One terminal the app opened, as it survives a relaunch of the app: the task
/// to reattach to and the logical place it runs in. It is written only for a
/// target that names itself without an install root (`TerminalTarget`) — a
/// record carrying an absolute path would open the wrong place after a
/// bootstrapping move, and a path that does not exist must never be presented
/// as something to resume.
struct TerminalSessionRecord: Codable, Equatable {
    var id: UUID
    var target: TerminalTarget
    /// The host's task, as `TaskID.rawValue`.
    var taskID: String
    var sessionID: String?
    var title: String?
    var openedAt: Date

    init(
        id: UUID = UUID(),
        target: TerminalTarget,
        taskID: String,
        sessionID: String? = nil,
        title: String? = nil,
        openedAt: Date = Date()
    ) {
        self.id = id
        self.target = target
        self.taskID = taskID
        self.sessionID = sessionID
        self.title = title
        self.openedAt = openedAt
    }
}

/// `Terminals/sessions.json` in the app's data folder, read the way the rest of
/// the app reads a list it writes back: one record at a time, so one record
/// this version cannot read is kept and written back, never replaced by an
/// empty list the next save makes permanent (`PreservedList`).
///
/// A file that is not there is a first run. A file that cannot be read at all —
/// permissions, a directory where the file should be — is neither: the caller
/// is told, and writes nothing over what it could not read.
struct TerminalSessionStore {
    enum ReadResult {
        /// No file yet: the first run.
        case missing
        case loaded(PreservedList<TerminalSessionRecord>)
        /// The file is there but could not be read. Saving would replace
        /// records nobody has seen, so the caller must not save.
        case unreadable(String)
    }

    let file: URL

    /// `Terminals/sessions.json` under `root`.
    init(root: URL) {
        file = root
            .appendingPathComponent("Terminals", isDirectory: true)
            .appendingPathComponent("sessions.json", isDirectory: false)
    }

    init(file: URL) {
        self.file = file
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    func load() -> ReadResult {
        guard exists else { return .missing }
        do {
            let data = try Data(contentsOf: file)
            guard let list = try? JSONCoding.decode(PreservedList<TerminalSessionRecord>.self, from: data) else {
                // Not a list at all: set it aside rather than overwrite what a
                // person might still read by hand, and start afresh safely.
                guard UnreadableFile.setAside(file) != nil || !exists else {
                    return .unreadable("The terminal sessions file could not be moved aside.")
                }
                return .loaded(PreservedList())
            }
            return .loaded(list)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Writes the list as it is, unreadable elements included.
    func save(_ list: PreservedList<TerminalSessionRecord>) throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder(pretty: true).encode(list)
        try data.write(to: file, options: .atomic)
    }
}
