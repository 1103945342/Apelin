import Foundation

/// Sidebar ancestry only; never the host's authorization lineage.
enum ChatRelationship: String, Hashable, Codable, Sendable {
    case branch
    case derived
}

/// One conversation as the sidebar lists it.
struct ChatSummary: Hashable, Codable, Sendable {
    var id = UUID()
    /// The name the reader, the agent or the first message gave it; empty
    /// while it has none. What is shown is `displayTitle`.
    var title: String
    /// When the reader last started it or sent it a message, a queued one
    /// included; for one an agent opened, until then, when the app took it
    /// in (`ChatAdoption`). The sidebar lists it by this, newest first, under
    /// its day (`SidebarOrder`). Nothing an agent or another conversation
    /// does moves it — output, a title, an approval asked, a message sent
    /// from another conversation, a compaction, a reopened session's
    /// replay —, nor does picking, pinning, renaming, Approve, Deny or Stop,
    /// so the list holds still while conversations work. Saved as `updated`,
    /// its name when every event moved it; a file from then keeps its time.
    var lastInteraction: Date
    /// The project it belongs to; nil for a temporary conversation.
    var projectName: String?
    /// Listed above the days, until it is unpinned.
    var isPinned = false
    /// Whether this conversation has a running turn.
    var isWorking = false
    /// A reply came while the reader was not looking at it, and they have
    /// not looked since (`ChatUnread`). Kept apart from `isWorking`: the
    /// sidebar shows it once the conversation is at rest (`showsUnread`).
    /// Absent from older files, which read as read.
    var isUnread = false
    /// The reader named it (`rename(to:)`), and a title the agent suggests
    /// no longer replaces that name. Absent from older files.
    var isNamedByReader: Bool?
    /// The direct parent chat, not its host session. Absent in old records.
    var parentChatID: UUID?
    var relationship: ChatRelationship?
    /// A branch's stable number among its direct parent's branches.
    var branchNumber: Int?
    /// The highest number reserved by this parent, including deleted branches.
    var lastBranchNumber: Int?
}

extension ChatSummary {
    /// A new conversation, with no name yet.
    static func untitled(lastInteraction: Date, projectName: String?) -> ChatSummary {
        ChatSummary(title: "", lastInteraction: lastInteraction, projectName: projectName)
    }

    /// Nothing has named it yet: shown as New Chat, in the language the
    /// app runs in now, and named after its first message.
    var isUntitled: Bool {
        title.isEmpty
    }

    /// A reply waits unread while the conversation is at rest.
    var showsUnread: Bool { isUnread && !isWorking }

    /// The name to show: its title, or New Chat while it has none.
    var displayTitle: String {
        isUntitled ? String(localized: "New Chat") : title
    }

    /// Names the conversation as the reader typed it, for good. A name
    /// with nothing but spaces in it changes nothing; returns whether the
    /// name was taken.
    @discardableResult
    mutating func rename(to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        title = trimmed
        isNamedByReader = true
        return true
    }

    /// A title someone other than the reader suggests — the agent's `title`
    /// event, the first message's opening — taken unless the reader named
    /// the conversation.
    mutating func suggestTitle(_ suggestion: String) {
        guard relationship != .branch, isNamedByReader != true, !suggestion.isEmpty else { return }
        title = suggestion
    }

    /// Names a conversation that has no name yet after the message it was
    /// just sent: the opening of its text, or else its first attachment's
    /// name. The agent's title replaces it later.
    mutating func nameAfterFirstMessage(text: String, attachmentName: String?) {
        guard isUntitled else { return }
        suggestTitle(String((text.isEmpty ? attachmentName ?? "" : text).prefix(80)))
    }
}

extension ChatSummary {
    private enum CodingKeys: String, CodingKey {
        case id, title, projectName, isPinned, isWorking, isUnread, isNamedByReader
        case parentChatID, relationship, branchNumber, lastBranchNumber
        case lastInteraction = "updated"
    }

    /// Reads a saved conversation. Before untitled was kept as no title,
    /// it was saved as the words New Chat in whichever language the app
    /// ran in then; any of those, unless the reader typed it, reads as
    /// untitled, so it shows in today's language and is still named after
    /// its first message.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        lastInteraction = try container.decode(Date.self, forKey: .lastInteraction)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        isWorking = try container.decode(Bool.self, forKey: .isWorking)
        isUnread = try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
        isNamedByReader = try container.decodeIfPresent(Bool.self, forKey: .isNamedByReader)
        parentChatID = try container.decodeIfPresent(UUID.self, forKey: .parentChatID)
        relationship = try container.decodeIfPresent(ChatRelationship.self, forKey: .relationship)
        branchNumber = try container.decodeIfPresent(Int.self, forKey: .branchNumber)
        lastBranchNumber = try container.decodeIfPresent(Int.self, forKey: .lastBranchNumber)
        if isNamedByReader != true, Self.savedPlaceholders.contains(title) {
            title = ""
        }
    }

    /// New Chat in each language this app has.
    private static let savedPlaceholders = placeholderTitles(in: .main)

    /// The key New Chat and its translation in each of `bundle`'s
    /// localizations.
    static func placeholderTitles(in bundle: Bundle) -> Set<String> {
        let key = "New Chat"
        var titles: Set<String> = [key]
        for localization in bundle.localizations {
            guard let path = bundle.path(forResource: localization, ofType: "lproj"),
                  let localized = Bundle(path: path)
            else { continue }
            titles.insert(localized.localizedString(forKey: key, value: key, table: nil))
        }
        return titles
    }
}

/// Pure presentation rules, shared by the runtime and its standalone checks.
/// Missing parents and malformed cycles keep the stored title as a fallback.
enum ChatLineage {
    static func projected(_ summaries: [ChatSummary]) -> [ChatSummary] {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return summaries.map { summary in
            var result = summary
            var ancestor = summary
            var visited: Set<UUID> = [summary.id]
            while ancestor.relationship == .branch,
                  let parentID = ancestor.parentChatID,
                  let parent = byID[parentID],
                  parent.projectName == summary.projectName
            {
                guard visited.insert(parentID).inserted else { return summary }
                ancestor = parent
            }
            result.title = ancestor.title
            return result
        }
    }

    /// Reserves before a branch is made; a failed fork may leave a gap, but
    /// deleting a branch never releases its number. Existing children also
    /// repair a counter missing from an older or partially saved parent.
    static func reserveBranchNumber(in parent: inout ChatSummary, summaries: [ChatSummary]) -> Int? {
        let parentID = parent.id
        let project = parent.projectName
        let existing = summaries.lazy.filter {
            $0.parentChatID == parentID && $0.relationship == .branch && $0.projectName == project
        }.compactMap(\.branchNumber).max() ?? 0
        let highest = max(0, parent.lastBranchNumber ?? 0, existing)
        guard highest < Int.max else { return nil }
        parent.lastBranchNumber = highest + 1
        return highest + 1
    }

    /// A new edge must remain within one project and must not close a cycle.
    static func canAttach(_ child: ChatSummary, to parent: ChatSummary, summaries: [UUID: ChatSummary]) -> Bool {
        guard child.id != parent.id, let project = child.projectName, project == parent.projectName else { return false }
        var current = parent
        var visited: Set<UUID> = [child.id]
        while true {
            guard visited.insert(current.id).inserted else { return false }
            guard let parentID = current.parentChatID, let next = summaries[parentID] else { return true }
            current = next
        }
    }
}
