import ApelinProtocol
import Foundation

/// A turn another conversation began — the reader's session sent a report —
/// has a key of its own, though it has no message the history's changes name.
/// Its header is drawn while it runs, so the state under it is the session's,
/// and once it ends only where the reader's agent actually worked: a report
/// answered after a moment's thought is its reply, not one more "Completed".
func checkCooperationTurn() {
    let reader = UUID(), report = UUID()
    let before = [
        event(1, "prompt", ["id": .string(reader.uuidString), "text": .string("Start")]),
        event(2, "messageStarted"),
        event(3, "thinking", ["text": .string("Working")]),
        event(4, "toolCall", ["id": .string("t1"), "tool": .string("file_read"), "arguments": .string("{}")]),
        event(5, "toolResult", ["id": .string("t1"), "output": .string("x")]),
        event(6, "message", ["text": .string("First answer")]),
        event(7, "finished"),
    ]
    let reported = [
        event(8, "prompt", ["id": .string(report.uuidString), "from": .string("other"), "text": .string("Report")]),
        event(9, "messageStarted"),
        event(10, "thinking", ["text": .string("Reading it")]),
    ]
    // Answered after a moment's thought, with nothing called.
    let quietlyAnswered = [
        event(11, "message", ["text": .string("Noted")]),
        event(12, "finished"),
    ]
    // Answered after the agent changed a file.
    let workedAnswered = [
        event(11, "toolCall", ["id": .string("t2"), "tool": .string("file_edit"), "arguments": .string("{}")]),
        event(12, "toolResult", ["id": .string("t2"), "output": .string("patched")]),
        event(13, "message", ["text": .string("Handled")]),
        event(14, "finished"),
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
    func isThought(_ message: ChatMessage) -> Bool {
        if case .thinking = message.role { return true }
        return false
    }
    func header(_ transcript: ChatTranscript, _ turn: UUID) -> ChatMessage? {
        transcript.messages.first { isHeader($0) && $0.turnMessageID == turn }
    }

    // The reader's own turn, one that called a tool: a header to open its work.
    let readerOnly = build(before)
    let readerHeader = header(readerOnly, reader)
    precondition(readerHeader != nil, "a turn with a call draws its header")
    precondition(readerHeader.map(isRunning) == false, "and it finished")
    precondition(readerHeader?.historyMessageID == reader, "and names the reader's message")
    precondition(readerOnly.messages.first { $0.id == reader }?.historyMessageID == reader)

    // The report starts another turn: a header of its own, saying the session
    // works again, and the turn above saying it finished.
    let working = build(before + reported)
    precondition(working.isWorking)
    precondition(header(working, report) != nil, "a turn another conversation began has a header while it runs")
    precondition(header(working, report).map(isRunning) == true, "and it is the one saying the session runs")
    precondition(header(working, report)?.historyMessageID == nil,
                 "its turn names no message the history's changes could act on")
    precondition(header(working, reader).map(isRunning) == false,
                 "the turn before it no longer reads as the session's state")
    let reportRow = working.messages.first { $0.id == report }
    precondition(reportRow?.turnMessageID == report, "the report's row is its turn's key")
    precondition(reportRow?.historyMessageID == nil, "and is not a message the reader typed")

    // Answered after a thought and nothing else: no header, no line for the
    // thought — the reply is what the session said.
    let quiet = build(before + reported + quietlyAnswered)
    precondition(!quiet.isWorking)
    precondition(header(quiet, report) == nil, "a report answered without a call leaves no header")
    precondition(quiet.messages.filter(isThought).count == 1,
                 "and no line for its thought either: \(quiet.messages.map(\.role))")
    let quietReply = quiet.messages.last { $0.role == .assistant }
    precondition(quietReply?.text == "Noted")
    precondition(quietReply?.turnMessageID == report, "the reply still belongs to the report's turn")
    precondition(quietReply?.historyMessageID == nil, "and names no message the reader typed")
    precondition(quietReply?.offersActions == true, "the newest reply offers Copy and More")

    // Answered after the agent changed a file: the header stays, with that
    // work to open.
    let worked = build(before + reported + workedAnswered)
    precondition(header(worked, report) != nil, "a report the agent worked on keeps its header")
    precondition(header(worked, report).map(isRunning) == false, "which says it finished")
    let workedReply = worked.messages.last { $0.role == .assistant }
    precondition(workedReply?.text == "Handled" && workedReply?.turnMessageID == report)
    precondition(worked.messages.contains { isThought($0) && $0.trace.isEmpty == false },
                 "and the call it made is still there to open")

    print("ok: a report's turn has a header while it runs, and only its reply once it did nothing")
}
