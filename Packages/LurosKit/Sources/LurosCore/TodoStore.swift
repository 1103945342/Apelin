import Foundation

/// One thing the agent means to do, as the composer's todo panel lists it.
public struct TodoRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// What is to be done, in the agent's words.
    public var title: String
    /// Where it stands. A list is worked through in order, so this is what the
    /// panel draws a row by.
    public var status: TodoStatus
    /// The conversation the item belongs to: a list is per chat, since two
    /// conversations working at once are doing different things.
    public var sessionID: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        status: TodoStatus,
        sessionID: String,
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.sessionID = sessionID
    }
}

public enum TodoStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case inProgress
    case completed
    /// Tried and abandoned, kept so the reader can see what was ruled out.
    case blocked

    public var isOpen: Bool {
        self == .pending || self == .inProgress
    }
}

/// One conversation's list, as it stands.
public struct TodoList: Codable, Equatable, Sendable {
    public var items: [TodoRecord]

    public init(items: [TodoRecord] = []) {
        self.items = items
    }

    public var open: [TodoRecord] { items.filter { $0.status.isOpen } }
    public var completed: [TodoRecord] { items.filter { $0.status == .completed } }

    /// How far along the list is, 0 ... 1. Nil when nothing can be counted —
    /// everything blocked — which the panel draws as no bar at all.
    public var fraction: Double? {
        let counted = items.filter { $0.status != .blocked }
        guard !counted.isEmpty else { return nil }
        return Double(counted.filter { $0.status == .completed }.count) / Double(counted.count)
    }
}

public enum TodoStoreError: Error, Equatable, LocalizedError {
    case tooManyItems
    case titleTooLong
    case unknownItem(String)

    public var errorDescription: String? {
        switch self {
        case .tooManyItems: "A list holds at most \(TodoStore.maximumItems) items."
        case .titleTooLong: "An item's title is at most \(TodoStore.maximumTitleLength) characters."
        case let .unknownItem(id): "No item has the id \(id)."
        }
    }
}

/// Every conversation's list, in one file under the app's data root.
///
/// A file beside the conversations rather than a field on one: the agent writes
/// it through a tool and the app reads it to draw the panel, and both already
/// share this folder. One file for all lists keeps a conversation's list from
/// being written over by a second one running at the same time — the read and
/// the write of a single list both happen inside one load-and-save.
public struct TodoStore: Sendable {
    public static let maximumItems = 100
    public static let maximumTitleLength = 240

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    private var file: URL {
        root.appendingPathComponent("Todos.json")
    }

    private struct Contents: Codable {
        var lists: [String: TodoList]
    }

    /// `sessionID`'s list; empty when it has none yet or the file will not
    /// read. A panel with no list and a panel that cannot read one draw the
    /// same way, and the next write makes the file right again.
    public func list(for sessionID: String) -> TodoList {
        (try? read().lists[sessionID]) ?? TodoList()
    }

    /// Replaces `sessionID`'s list.
    public func write(_ list: TodoList, for sessionID: String) throws {
        guard list.items.count <= Self.maximumItems else { throw TodoStoreError.tooManyItems }
        for item in list.items where item.title.count > Self.maximumTitleLength {
            throw TodoStoreError.titleTooLong
        }
        var contents = (try? read()) ?? Contents(lists: [:])
        contents.lists[sessionID] = list
        try save(contents)
    }

    /// Puts `items` in place of what `sessionID` had: the whole list, as the
    /// agent thinks of it now. Ids it did not name are gone.
    public func replace(_ items: [TodoRecord], for sessionID: String) throws {
        try write(TodoList(items: items), for: sessionID)
    }

    /// The list with one item's status changed, read and written as one step.
    public func setStatus(_ status: TodoStatus, of id: String, for sessionID: String) throws {
        var contents = (try? read()) ?? Contents(lists: [:])
        var list = contents.lists[sessionID] ?? TodoList()
        guard let index = list.items.firstIndex(where: { $0.id == id }) else {
            throw TodoStoreError.unknownItem(id)
        }
        list.items[index].status = status
        contents.lists[sessionID] = list
        try save(contents)
    }

    /// Takes `sessionID`'s list away, for a conversation that is going.
    public func remove(for sessionID: String) throws {
        var contents = (try? read()) ?? Contents(lists: [:])
        guard contents.lists.removeValue(forKey: sessionID) != nil else { return }
        try save(contents)
    }

    private func read() throws -> Contents {
        guard FileManager.default.fileExists(atPath: file.path) else { return Contents(lists: [:]) }
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode(Contents.self, from: data)
    }

    private func save(_ contents: Contents) throws {
        let data = try JSONEncoder().encode(contents)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Written whole, in one call: the file is small, and a half-written one
        // would drop every item the agent had already put there.
        try data.write(to: file, options: .atomic)
    }
}
