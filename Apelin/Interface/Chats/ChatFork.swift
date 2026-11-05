import ApelinCore
import ApelinProtocol
import Foundation

/// A forked conversation's events, cut from its source's as the source's
/// worker cuts its log (`AgentSession.forkRecords`): through the turn of
/// the message forked from, less messages queued in it that no run took, a
/// `finished` when the turn was cut off without an end, then the edits made
/// later to what it kept. The two hold the same user messages and
/// compactions in the same order, so the fork's replay, once it is opened,
/// is read past message for message (`SessionReplay`).
enum ChatFork {
    /// What the source's later events may change of what a fork keeps.
    private static let laterKinds: Set<String> = [
        "messageEdited", "replyEdited", "replyDeleted", "checkpoint",
    ]

    /// Nil when no message of `events` is `messageID`.
    static func events(_ events: [TaskEvent], through messageID: UUID) -> [TaskEvent]? {
        guard let start = events.firstIndex(where: {
            $0.kind == "prompt" && ChatTranscript.userMessageID(of: $0) == messageID
        }) else { return nil }
        let end = events[(start + 1)...].firstIndex { $0.kind == "prompt" } ?? events.count
        var taken: Set<UUID> = []
        for event in events[..<end] where event.kind == "prompt" {
            if let id = ChatTranscript.userMessageID(of: event) {
                taken.insert(id)
            }
        }
        var kept = events[..<end].filter { event in
            guard event.kind == "queued" else { return true }
            return ChatTranscript.userMessageID(of: event).map { taken.contains($0) } ?? false
        }
        let lastTurn = kept.lastIndex { $0.kind == "prompt" } ?? 0
        let ended = kept[lastTurn...].contains { $0.kind == "finished" || ChatTranscript.endsTask($0) }
        if !ended {
            kept.append(TaskEvent(
                seq: kept.last?.seq ?? .start,
                kind: "finished",
                time: kept.last?.time ?? Date(),
                payload: .object(["reason": .string("aborted")]),
            ))
        }
        for event in events[end...] where laterKinds.contains(event.kind) {
            if let id = event.payload?["id"]?.stringValue.flatMap(UUID.init(uuidString:)), taken.contains(id) {
                kept.append(event)
            }
        }
        return kept
    }
}
