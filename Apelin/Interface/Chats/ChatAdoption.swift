import ApelinCore
import ApelinProtocol
import Foundation

/// Conversations an agent opened (`AgentConversations`), taken in as the
/// app's own: listed in the project it was opened in — the opener's, or
/// another one the opener named, General Chat's included —, followed like
/// any other, and never selected on their own. Each is listed by `now`, the
/// time it was taken in, until the reader writes in it
/// (`ChatSummary.lastInteraction`): never by when its agent last wrote.
enum ChatAdoption {
    /// The record for a `conversationOpened` event on `parent`'s task, or
    /// nil when a record already has that session or the event names none.
    /// Its project is the one the event names, else the opener's.
    static func record(
        opened payload: JSONValue?,
        parent: ChatRecord,
        records: [ChatRecord],
        now: Date = Date(),
    ) -> ChatRecord? {
        guard let project = payload?["projectName"]?.stringValue ?? parent.summary.projectName,
              let sessionID = payload?["sessionID"]?.stringValue, UUID(uuidString: sessionID) != nil,
              let task = try? payload?["task"]?.decode(TaskHandle.self), task.kind == .agent,
              !records.contains(where: { $0.sessionID == sessionID })
        else { return nil }
        return ChatRecord(
            summary: summary(
                title: title(payload?["title"]?.stringValue, prompt: payload?["prompt"]?.stringValue),
                project: project, parent: parent.summary, now: now, isWorking: true,
            ),
            sessionID: sessionID,
            task: task,
        )
    }

    /// The record for a running session an agent opened while the app was
    /// not following its opener, or nil when it has one already, has ended,
    /// or its opener has no record. Its project is the one the host lists
    /// it in, else the opener's.
    static func record(session: AgentSessionSummary, records: [ChatRecord], now: Date = Date()) -> ChatRecord? {
        guard let parentID = session.parentSessionID, !session.state.isTerminal,
              !records.contains(where: { $0.sessionID == session.sessionID }),
              let parent = records.first(where: { $0.sessionID == parentID }),
              let project = session.projectName ?? parent.summary.projectName
        else { return nil }
        return ChatRecord(
            summary: summary(title: title(session.title, prompt: nil), project: project, parent: parent.summary, now: now),
            sessionID: session.sessionID,
            task: session.task,
        )
    }

    /// The record for a session an `apelin://conversation/` link names that
    /// has no opener to take the project from, in `projectName`, the
    /// project the host names for it; nil when a record has it already.
    /// Ended or not: the link asked for it, and its log still reads.
    static func record(
        linked session: AgentSessionSummary,
        projectName: String,
        records: [ChatRecord],
        now: Date = Date(),
    ) -> ChatRecord? {
        guard !records.contains(where: { $0.sessionID == session.sessionID }) else { return nil }
        let parent = session.parentSessionID.flatMap { parentID in records.first { $0.sessionID == parentID } }
        return ChatRecord(
            summary: summary(
                title: title(session.title, prompt: nil), project: projectName,
                parent: parent?.summary, now: now, isWorking: !session.state.isTerminal,
            ),
            sessionID: session.sessionID,
            task: session.task,
        )
    }

    /// Cross-project opens still belong to their target project, but do not
    /// make a sidebar edge across project roots. This changes no host lineage.
    private static func summary(
        title: String, project: String, parent: ChatSummary?, now: Date, isWorking: Bool = false,
    ) -> ChatSummary {
        var summary = ChatSummary(title: title, lastInteraction: now, projectName: project, isWorking: isWorking)
        if let parent, parent.projectName == project {
            summary.parentChatID = parent.id
            summary.relationship = .derived
        }
        return summary
    }

    /// Repairs only metadata on records already present. Never resurrects a
    /// deleted chat, rewrites an explicit relationship, or guesses from a title.
    /// Old forks have no reliable parent marker and remain unrelated. A fork's
    /// historical conversationOpened events are not evidence that it opened
    /// those sessions. Conflicting evidence and ambiguous session IDs are left
    /// alone. Ended sessions can still supply evidence for saved records.
    @discardableResult
    static func restoreLineage(
        in records: inout [UUID: ChatRecord], sessions: [AgentSessionSummary] = [],
    ) -> Set<UUID> {
        var sessionChats: [UUID: Set<UUID>] = [:]
        for record in records.values {
            if let session = record.sessionID.flatMap(UUID.init(uuidString:)) {
                sessionChats[session, default: []].insert(record.summary.id)
            }
        }
        func chatID(_ session: String?) -> UUID? {
            guard let session = session.flatMap(UUID.init(uuidString:)),
                  let ids = sessionChats[session], ids.count == 1 else { return nil }
            return ids.first
        }
        var candidates: [UUID: Set<UUID>] = [:]
        for parent in records.values {
            for event in parent.events where event.kind == AgentConversations.openedEventKind && !ChatFork.isHistorical(event) {
                guard let childID = chatID(event.payload?["sessionID"]?.stringValue),
                      let child = records[childID],
                      event.payload?["projectName"]?.stringValue.map({ $0 == child.summary.projectName }) ?? true
                else { continue }
                candidates[childID, default: []].insert(parent.summary.id)
            }
        }
        for session in sessions {
            guard let childID = chatID(session.sessionID), let parentID = chatID(session.parentSessionID),
                  session.projectName.map({ $0 == records[childID]?.summary.projectName }) ?? true
            else { continue }
            candidates[childID, default: []].insert(parentID)
        }
        var changed: Set<UUID> = []
        var summaries = records.mapValues(\.summary)
        for childID in candidates.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let parents = candidates[childID], parents.count == 1, let parentID = parents.first,
                  var child = summaries[childID], let parent = summaries[parentID],
                  child.parentChatID == nil, child.relationship == nil, child.branchNumber == nil,
                  ChatLineage.canAttach(child, to: parent, summaries: summaries)
            else { continue }
            child.parentChatID = parentID
            child.relationship = .derived
            summaries[childID] = child
            records[childID]?.summary = child
            changed.insert(childID)
        }
        // A child saved before its parent's counter is enough to raise the
        // high-water mark. Never lower it when a child is missing or deleted.
        for child in summaries.values where child.relationship == .branch {
            guard let parentID = child.parentChatID, let parent = records[parentID]?.summary,
                  child.projectName == parent.projectName, child.id != parentID,
                  let number = child.branchNumber, number > max(0, parent.lastBranchNumber ?? 0)
            else { continue }
            records[parentID]?.summary.lastBranchNumber = number
            changed.insert(parentID)
        }
        return changed
    }

    /// The opener's title, else the first line of the prompt, as the
    /// sidebar shows a conversation the user started; empty, untitled,
    /// when there is neither.
    static func title(_ title: String?, prompt: String?) -> String {
        for text in [title, prompt] {
            let line = text?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(80))
            }
        }
        return ""
    }
}
