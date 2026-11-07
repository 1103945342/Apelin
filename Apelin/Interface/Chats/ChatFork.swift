import ApelinProtocol

/// Helpers for a conversation created from a sealed model snapshot. The fork
/// worker replays its new session log and marks those records in the event
/// payload; the marker is deliberately not a protocol field.
enum ChatFork {
    static func isHistorical(_ event: TaskEvent) -> Bool {
        event.payload?["historical"]?.boolValue == true
    }
}
