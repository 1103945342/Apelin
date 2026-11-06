import ApelinCore
import CryptoKit
import Foundation

/// A to-do list the reader put away with the panel's ✕, as aimini's
/// "clear" does: the panel stays away for that chat until the agent writes
/// a list that differs, when it comes back.
///
/// Kept by the app beside its other preferences, never by deleting the
/// agent's list: the agent still reads its own list with apelin_todo_list,
/// and the store is one file every conversation writes, which the app does
/// not write to.
enum TodoListHiding {
    private static func key(_ sessionID: String) -> String {
        "TodoListHidden.\(sessionID)"
    }

    /// Whether `list` is the one put away for `sessionID`. A list that has
    /// changed since forgets the choice, so the next one shows.
    static func isHidden(_ list: TodoList, for sessionID: String) -> Bool {
        guard let hidden = UserDefaults.standard.string(forKey: key(sessionID)) else { return false }
        guard !list.items.isEmpty, hidden == digest(of: list) else {
            UserDefaults.standard.removeObject(forKey: key(sessionID))
            return false
        }
        return true
    }

    static func hide(_ list: TodoList, for sessionID: String) {
        guard !list.items.isEmpty else { return }
        UserDefaults.standard.set(digest(of: list), forKey: key(sessionID))
    }

    /// The items, their order, titles and states: what the reader saw.
    private static func digest(of list: TodoList) -> String {
        let text = list.items.map { "\($0.id)\u{1F}\($0.status.rawValue)\u{1F}\($0.title)" }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
