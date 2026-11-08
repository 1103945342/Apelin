import ApelinProtocol

/// Helpers for a conversation created from a sealed model snapshot. The fork
/// worker replays its new session log and marks those records in the event
/// payload; the marker is deliberately not a protocol field.
enum ChatFork {
    /// Empty saved forks still need their worker's replay; a draft with no
    /// session must not open a worker just because its page was selected.
    static func needsHistoryLoad(_ record: ChatRecord, isFollowed: Bool) -> Bool {
        record.sessionID != nil && !isFollowed
    }
    static func isHistorical(_ event: TaskEvent) -> Bool {
        event.payload?["historical"]?.boolValue == true
    }
}
