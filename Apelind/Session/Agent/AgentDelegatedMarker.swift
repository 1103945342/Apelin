import Darwin
import Foundation

/// Says a conversation was opened from a structured brief. The brief itself is
/// the authority (`AgentDelegationStore`); this marker only tells a child that
/// never had one — a conversation an agent opened before briefs existed — from
/// one whose record is gone, which must not reopen unrestricted
/// (`AgentHandler.open`) and may not mutate (`AgentDelegationAdmission`).
///
/// It is a file of its own beside the record (`agent-delegations/<id>.governed`)
/// so that a record the deletion transaction retires leaves the marker behind:
/// the conversation stays retired instead of falling back to an unconstrained
/// one. A child opened before this file existed has no marker and is read as it
/// always was.
enum AgentDelegatedMarker {
    static func exists(session sessionID: String, state: URL) -> Bool {
        guard let file = file(sessionID, state: state) else { return false }
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG
    }

    /// Written once, before the child's worker starts; a write that fails is
    /// the caller's to refuse the open with, never to swallow.
    static func mark(session sessionID: String, state: URL) throws {
        guard let file = file(sessionID, state: state) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data().write(to: file, options: .atomic)
    }

    /// Nil unless the session ID is a UUID, so it names one file.
    private static func file(_ sessionID: String, state: URL) -> URL? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        return state.appendingPathComponent("agent-delegations", isDirectory: true)
            .appendingPathComponent("\(sessionID).governed")
    }
}
