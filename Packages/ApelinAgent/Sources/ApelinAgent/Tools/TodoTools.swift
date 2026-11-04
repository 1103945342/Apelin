import struct ApelinCore.TodoList
import struct ApelinCore.TodoRecord
import enum ApelinCore.TodoStatus
import struct ApelinCore.TodoStore
import Foundation
import KWWKAI

/// The conversation's todo list, as `apelin_todo_list` and
/// `apelin_todo_write` reach it.
///
/// The write replaces the whole list rather than patching one item: the model
/// thinks in steps, and a call that says what the list is now cannot drift out
/// of step with a status it forgot to change.
struct TodoTools {
    let store: TodoStore
    let sessionID: String

    func list() throws -> TodoList {
        store.list(for: sessionID)
    }

    func write(_ arguments: JSONValue) throws -> TodoList {
        guard case let .object(object) = arguments,
              case let .array(entries)? = object["items"]
        else {
            throw ToolArgumentError("items is the whole list, in order.")
        }
        // Only an id the list already holds is kept: one the model invented
        // would make an item nothing can ever mark done.
        let known = Set(store.list(for: sessionID).items.map(\.id))

        var items: [TodoRecord] = []
        for entry in entries {
            let title = (entry.argString("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw ToolArgumentError("Every item needs a title.")
            }
            guard let status = Self.status(entry.argString("status") ?? "") else {
                throw ToolArgumentError("status must be pending, inProgress, completed or blocked.")
            }
            let id = entry.argString("id").flatMap { known.contains($0) ? $0 : nil }
            items.append(TodoRecord(
                id: id ?? UUID().uuidString.lowercased(),
                title: title,
                status: status,
                sessionID: sessionID
            ))
        }
        try store.replace(items, for: sessionID)
        return TodoList(items: items)
    }

    private static func status(_ raw: String) -> TodoStatus? {
        switch raw {
        case "pending": .pending
        case "inProgress", "in_progress": .inProgress
        case "completed", "done": .completed
        case "blocked": .blocked
        default: TodoStatus(rawValue: raw)
        }
    }
}
