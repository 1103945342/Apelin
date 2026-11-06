import struct ApelinCore.MemoryRecord
import struct ApelinCore.MemorySnapshot
import struct ApelinCore.MemoryStore
import enum ApelinCore.MemoryStoreError
import Foundation
import KWWKAI

struct MemoryTools {
    let store: MemoryStore
    /// The project whose records a call sees beside every chat's: the
    /// session's own, or the one the call names.
    let projectID: String
    /// Why no new record can be kept for that project, when none can:
    /// General Chat has no project, and a project that is gone takes none.
    var newRecordRefusal: String?

    func list() throws -> MemorySnapshot {
        try store.read().forProject(projectID)
    }

    /// Every record, each project's with the project it is kept for as
    /// apelin_project_list names it (`projects`, by projectID), or marked
    /// missing when no project has that id now.
    static func listEveryProject(_ snapshot: MemorySnapshot, projects: [String: MemoryListing.Project]) -> MemoryListing {
        MemoryListing(revision: snapshot.revision, records: snapshot.records.map { record in
            let project = record.projectID.flatMap { projects[$0] }
            return MemoryListing.Record(
                id: record.id,
                title: record.title,
                body: record.body,
                projectID: record.projectID,
                folder: project?.folder,
                displayName: project?.displayName,
                missing: record.projectID != nil && project == nil ? true : nil,
            )
        })
    }

    func save(_ arguments: JSONValue) throws -> MemorySnapshot {
        let revision = try arguments.requireString("revision")
        let id = arguments.argString("id")
        let all = try store.read()
        guard all.revision == revision else { throw MemoryStoreError.changed }
        let snapshot = all.forProject(projectID)
        let scope: String?
        if let id {
            guard let existing = snapshot.records.first(where: { $0.id == id }) else {
                throw Self.unknown(id, in: all, creating: true)
            }
            scope = existing.projectID
        } else {
            switch arguments.argString("scope") ?? "project" {
            case "global": scope = nil
            case "project":
                if let newRecordRefusal {
                    throw ToolArgumentError(newRecordRefusal)
                }
                scope = projectID
            default: throw ToolArgumentError("scope must be global or project")
            }
        }
        let record = try MemoryRecord(
            id: id ?? UUID().uuidString.lowercased(),
            title: arguments.requireString("title"),
            body: arguments.requireString("body"),
            projectID: scope,
        )
        return try store.save(record, replacing: id, revision: revision).forProject(projectID)
    }

    func delete(_ arguments: JSONValue) throws -> MemorySnapshot {
        let id = try arguments.requireString("id")
        let revision = try arguments.requireString("revision")
        let all = try store.read()
        guard all.revision == revision else { throw MemoryStoreError.changed }
        guard all.forProject(projectID).records.contains(where: { $0.id == id }) else {
            throw Self.unknown(id, in: all, creating: false)
        }
        return try store.delete(id: id, revision: revision).forProject(projectID)
    }

    /// An id the call's records do not hold. Memory has not changed since
    /// the model read it, so this is a wrong id, not a conflict, or the id
    /// of a record another project keeps, which the call reaches by naming it.
    private static func unknown(_ id: String, in all: MemorySnapshot, creating: Bool) -> ToolArgumentError {
        if let owner = all.records.first(where: { $0.id == id })?.projectID {
            return ToolArgumentError("Memory \(id) is kept for another project: pass project: \(owner) to change it.")
        }
        let hint = creating ? " To add a new record, leave id out." : ""
        return ToolArgumentError("No memory has id \(id); apelin_memory_list shows the ids.\(hint)")
    }

    /// The section for `records`, the ones this session sees; nil when the
    /// store could not be read.
    static func prompt(_ records: [MemoryRecord]?) -> String {
        // Sorted keys: the same memories give the same bytes, so the system
        // prompt, and the provider's cache of it, stays the same. Only the
        // records this session sees go in, never the revision: that changes
        // with every write, another project's included, and a change of the
        // prompt makes the provider write the whole conversation into its
        // cache again. apelin_memory_list answers the revision a change needs.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let contents = records.flatMap { try? encoder.encode(PromptRecords(records: $0)) }
            .map { String(decoding: $0, as: UTF8.self) }
            ?? "Memory storage is unavailable. Do not invent saved memories."
        return SystemPromptText.memory(
            maximumRecords: String(MemoryStore.maximumRecords),
            maximumContentBytes: String(MemoryStore.maximumContentBytes),
            records: contents,
        )
    }

    /// What the system prompt shows of a snapshot.
    private struct PromptRecords: Encodable {
        var records: [MemoryRecord]
    }
}

/// apelin_memory_list with all_projects: every record, as Settings ▸
/// Memories lists them, one of a project that is gone included, to clean up.
struct MemoryListing: Encodable {
    /// A project's folder and the name the sidebar shows.
    struct Project {
        var folder: String
        var displayName: String?
    }

    struct Record: Encodable {
        var id: String
        var title: String
        var body: String
        var projectID: String?
        /// The project's folder and the name the sidebar shows.
        var folder: String?
        var displayName: String?
        /// No project has the record's projectID now, so no chat sees it.
        var missing: Bool?
    }

    var revision: String
    var records: [Record]
}
