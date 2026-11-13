import Foundation

/// One in-flight read shared by the composer's automatic selection check and
/// its picker. Cancelling a waiter never cancels another reader's work. The
/// last answer is only a preview; each new read still validates the accounts.
@MainActor
final class SharedModelLoad<Key: Equatable & Sendable, Value: Sendable> {
    private var pending: (key: Key, id: UUID, task: Task<Value, Error>)?
    private var last: (key: Key, value: Value)?

    func preview(for key: Key) -> Value? {
        last?.key == key ? last?.value : nil
    }

    func value(for key: Key, fetch: @escaping @Sendable (Key) async throws -> Value) async throws -> Value {
        let work: (key: Key, id: UUID, task: Task<Value, Error>)
        if let pending, pending.key == key {
            work = pending
        } else {
            work = (key, UUID(), Task { try await fetch(key) })
            pending = work
        }
        do {
            let value = try await work.task.value
            // A different selection may have started a newer read meanwhile.
            // Its cache and in-flight task belong to it, even if this finishes last.
            if pending?.id == work.id {
                last = (key, value)
                pending = nil
            }
            try Task.checkCancellation()
            return value
        } catch {
            if pending?.id == work.id { pending = nil }
            throw error
        }
    }
}
