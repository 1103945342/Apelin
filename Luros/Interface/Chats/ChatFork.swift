import ApelinProtocol

/// Helpers for a conversation created from a sealed model snapshot. The fork
/// worker replays its new session log and marks those records in the event
/// payload; the marker is deliberately not a protocol field.
enum ChatFork {
    /// Whether its page has to ask the host to open the session before the
    /// reader has sent anything: only a fork with nothing saved needs its
    /// worker's replay, and a draft with no session must not open one just
    /// because its page was selected.
    ///
    /// A conversation with history is shown from the events on disk. Opening
    /// its session to look at it would start a worker that waits for a prompt
    /// and a task the host reports as running, so a row would claim a turn it
    /// is not in — and nothing would ever end it (`eventCount` is the head's
    /// count, so an unread history still counts as one).
    static func needsHistoryLoad(_ record: ChatRecord, isFollowed: Bool, eventCount: Int) -> Bool {
        record.sessionID != nil && !isFollowed && eventCount == 0
    }

    static func isHistorical(_ event: TaskEvent) -> Bool {
        event.payload?["historical"]?.boolValue == true
    }
}
