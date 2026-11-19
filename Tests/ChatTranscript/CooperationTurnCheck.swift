import ApelinProtocol
import Foundation

/// A turn another conversation began — the reader's session sent a report —
/// has a key of its own, though it has no message the history's changes can
/// name. Its header is drawn, so the state under it is the session's, and the
/// turn above stops being the last word on whether the session is working.
func checkCooperationTurn() {
    let reader = UUID(), report = UUID()
    let before = [
        event(1, "prompt", ["id": .string(reader.uuidString), "text": .string("Start")]),
        event(2, "messageStarted"),
        event(3, "thinking", ["text": .string("Working")]),
        event(4, "message", ["text": .string("First answer")]),
        event(5, "finished"),
    ]
    let reported = [
        event(6, "prompt", ["id": .string(report.uuidString), "from": .string("other"), "text": .string("Report")]),
        event(7, "messageStarted"),
        event(8, "thinking", ["text": .string("Reading it")]),
    ]
    let answered = [
        event(9, "message", ["text": .string("Handled")]),
        event(10, "finished"),
    ]
    func build(_ events: [TaskEvent]) -> ChatTranscript {
        ChatTranscript(events: events) { _ in nil }
    }
    func isHeader(_ message: ChatMessage) -> Bool {
        if case .turn = message.role { return true }
        return false
    }
    func isRunning(_ message: ChatMessage) -> Bool {
        if case let .turn(running, _) = message.role { return running }
        return false
    }

    // The reader's own turn: its message is the one Edit, Delete and Rewind name.
    let readerOnly = build(before)
    let readerHeader = readerOnly.messages.first(where: isHeader)
    precondition(readerHeader?.turnMessageID == reader, "a reader's header names their message")
    precondition(readerHeader?.historyMessageID == reader, "and it is theirs to change")
    precondition(readerOnly.messages.first { $0.id == reader }?.historyMessageID == reader)

    // The report starts another turn: a header of its own, saying the session
    // works again, and the turn above saying it finished.
    let working = build(before + reported)
    precondition(working.isWorking)
    let headers = working.messages.filter(isHeader)
    precondition(headers.count == 2, "every turn has a header: \(headers.map(\.role))")
    let reportHeader = headers.first { $0.turnMessageID == report }
    precondition(reportHeader != nil, "a turn another conversation began has a header")
    precondition(reportHeader.map(isRunning) == true, "and it is the one saying the session runs")
    precondition(reportHeader?.historyMessageID == nil, "its turn names no message the history's changes could act on")
    precondition(headers.first(where: { $0.turnMessageID == reader }).map(isRunning) == false,
                 "the turn before it no longer reads as the session's state")
    let reportRow = working.messages.first { $0.id == report }
    precondition(reportRow?.turnMessageID == report, "the report's row is its turn's key")
    precondition(reportRow?.historyMessageID == nil, "and is not a message the reader typed")

    // Its reply belongs to that turn, and still offers Copy and More: More
    // opens a menu of the choices that need no message.
    let done = build(before + reported + answered)
    precondition(!done.isWorking)
    let reply = done.messages.last { $0.role == .assistant }
    precondition(reply?.text == "Handled")
    precondition(reply?.turnMessageID == report, "the reply belongs to the report's turn")
    precondition(reply?.historyMessageID == nil, "and names no message Edit or Delete could act on")
    precondition(reply?.offersActions == true, "the newest reply offers Copy and More")

    print("ok: a turn another conversation began has a header and a running state of its own")
}
