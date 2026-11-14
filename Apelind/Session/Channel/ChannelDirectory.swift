import ApelinCore
import ApelinProtocol
import Foundation

/// What the channel lists when a phone asks: the projects this device has,
/// and the conversations in them (2026-11-15).
///
/// A conversation is either one this host is running — the session table
/// knows its title and when it moved — or one on disk that nothing serves
/// now, read from `sessions/<id>/session.json`: its project, and when its
/// log last grew. Both are listed by the time they last moved, most recent
/// first, because that is the one a phone is usually reaching for.
enum ChannelDirectory {
    struct SessionBrief: Sendable, Equatable {
        var id: String
        var title: String
        var projectName: String?
        /// General Chat's workspace id, when the conversation has no
        /// project: reopening it needs the same one.
        var temporaryID: String?
        var updatedAt: Date
        var running: Bool
    }

    /// The projects under `Projects/`, by folder name, in the order the
    /// projects page shows them.
    static func projects(home: String) -> [String] {
        let folder = DataFolder(home: home).projects
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return urls.compactMap { url -> String? in
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard directory else { return nil }
            let name = url.lastPathComponent
            return ProjectName.validate(name) == nil ? name : nil
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Every conversation this device can be sent to, the running ones and
    /// the saved ones, most recently used first.
    static func sessions(home: String, registry: TaskRegistry, limit: Int = 20) async -> [SessionBrief] {
        var byID: [String: SessionBrief] = [:]
        for summary in await AgentSessionTable.shared.summaries(registry: registry) {
            byID[summary.sessionID] = SessionBrief(
                id: summary.sessionID,
                title: summary.title ?? fallbackTitle(summary.sessionID, project: summary.projectName),
                projectName: summary.projectName,
                temporaryID: temporaryID(summary.projectID),
                updatedAt: summary.updatedAt,
                running: !summary.state.isTerminal
            )
        }
        for stored in storedSessions(home: home) where byID[stored.id] == nil {
            byID[stored.id] = SessionBrief(
                id: stored.id,
                title: fallbackTitle(stored.id, project: stored.projectName),
                projectName: stored.projectName,
                temporaryID: stored.temporaryID,
                updatedAt: stored.updatedAt,
                running: false
            )
        }
        return byID.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// One saved conversation, as its folder says it is.
    struct StoredSession: Sendable, Equatable {
        var id: String
        var projectName: String?
        var temporaryID: String?
        var updatedAt: Date
    }

    /// The conversation folders under `sessions/`. A folder that does not
    /// read costs only itself: it is listed without a project.
    static func storedSessions(home: String) -> [StoredSession] {
        let folder = DataFolder(home: home).sessions
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return urls.compactMap { url -> StoredSession? in
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard directory else { return nil }
            let id = url.lastPathComponent
            guard UUID(uuidString: id) != nil else { return nil }
            let metadata = url.appendingPathComponent("session.json")
            var projectName: String?
            var temporary: String?
            if let data = try? Data(contentsOf: metadata),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let project = object["project"] as? [String: Any]
            {
                projectName = name(of: project)
                temporary = temporaryID(project["id"] as? String)
            }
            // The log grows with every event; its own date is the one that
            // says when the conversation last moved.
            let log = url.appendingPathComponent("events.jsonl")
            let date = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date.distantPast
            return StoredSession(id: id, projectName: projectName, temporaryID: temporary, updatedAt: date)
        }
    }

    /// `ProjectIdentity.name` is a `ProjectName`, which encodes as a string
    /// on this version; a build that wrote something else costs the name,
    /// never the conversation.
    private static func name(of project: [String: Any]) -> String? {
        if let name = project["name"] as? String {
            return name
        }
        if let nested = project["name"] as? [String: Any] {
            for value in nested.values {
                if let name = value as? String, !name.isEmpty {
                    return name
                }
            }
        }
        return nil
    }

    /// The UUID of General Chat's workspace from a project id
    /// (`temporary:<uuid>`), nil for a project's conversation.
    private static func temporaryID(_ projectID: String?) -> String? {
        guard let projectID, projectID.hasPrefix("temporary:") else { return nil }
        let id = String(projectID.dropFirst("temporary:".count))
        return UUID(uuidString: id) == nil ? nil : id
    }

    /// What a conversation with no title of its own is called: its project
    /// and enough of its id to tell it from the next one.
    static func fallbackTitle(_ id: String, project: String?) -> String {
        let short = String(id.prefix(8))
        return project.map { "\($0) · \(short)" } ?? "· \(short)"
    }
}
