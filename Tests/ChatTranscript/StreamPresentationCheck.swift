import ApelinCore
import ApelinProtocol
import Foundation

/// Exercise every intermediate snapshot, not just the final tool/text pairs.
func checkStreamPresentation() {
    let turn = UUID()
    var events: [TaskEvent] = []
    var transcript = ChatTranscript(events: []) { _ in nil }
    func take(_ kind: String, _ payload: [String: JSONValue] = [:]) -> [ChatMessage] {
        let seq = UInt64(events.count + 1)
        let event = TaskEvent(seq: EventSeq(seq), kind: kind,
                              time: Date(timeIntervalSince1970: Double(seq)), payload: .object(payload))
        events.append(event)
        transcript.append([event]) { _ in nil }
        let replay = ChatTranscript(events: events) { _ in nil }
        precondition(transcript.messages == replay.messages, "incremental and replay agree at every event")
        return ChatProcessPresentation.rows(transcript.messages) { _ in false }
    }
    func count(_ rows: [ChatMessage]) -> Int? {
        rows.first { if case .turn = $0.role { return true }; return false }?.headerReceivedTokens
    }
    func banner(_ rows: [ChatMessage]) -> String? {
        rows.first { $0.foldsProcessSteps }?.banner?.reason
    }
    _ = take("prompt", ["id": .string(turn.uuidString), "text": .string("Work")])
    _ = take("messageStarted")
    precondition(count(take("received", ["tokens": .number(120)])) == 120)
    let text = take("text", ["text": .string("Commentary")])
    precondition(count(text) == 120, "a disappearing empty thought must not hide the turn count")
    precondition(!text.contains { $0.role.isActivity }, "no empty summary beside plain text")
    _ = take("toolCallPreparing")
    _ = take("toolCall", ["id": .string("a"), "tool": .string("file_read"),
                           "arguments": .string("{\"path\":\"A\",\"reason\":\"Read A\"}")])
    precondition(banner(take("toolResult", ["id": .string("a"), "output": .string("A")])) == "Read A")
    _ = take("messageStarted")
    _ = take("text", ["text": .string("Continuing")])
    precondition(banner(take("messageStarted")) == "Read A", "empty new segment keeps last valid banner")
    precondition(banner(take("toolCallPreparing")) == "Read A")
    precondition(banner(take("received", ["tokens": .number(240)])) == "Read A")
    precondition(count(ChatProcessPresentation.rows(transcript.messages) { _ in true }) == 240,
                 "opening the process keeps the count on the stable turn header")
    _ = take("toolCall", ["id": .string("b"), "tool": .string("file_read"),
                           "arguments": .string("{\"path\":\"B\",\"reason\":\"Read B\"}")])
    precondition(banner(take("toolResult", ["id": .string("b")])) == "Read B", "new content replaces old")
    _ = take("messageStarted")
    _ = take("text", ["text": .string("Attempt")])
    _ = take("messageDiscarded")
    precondition(banner(take("reconnecting")) == "Read B")
    _ = take("messageStarted")
    _ = take("received", ["tokens": .number(200)]) // a legitimate retry correction
    let final = take("message", ["text": .string("Answer")])
    precondition(count(final) == 200, "do not replace accounting with a high-water mark")
    let ended = take("finished")
    precondition(count(ended) == nil && !ended.contains { $0.role.isActivity })
    _ = take("prompt", ["id": .string(UUID().uuidString), "text": .string("Next")])
    let next = take("messageStarted")
    precondition(banner(next) == nil && count(next) == nil, "no stale banner or count crosses turns")

    var a = ChatMessage(role: .thinking(seconds: 1, tools: 0), text: "ab cd")
    var b = a
    b.text = "ab\ncd"
    precondition(a.text.utf8.count == b.text.utf8.count)
    precondition(ChatMessageShape(a) != ChatMessageShape(b), "equal byte counts do not imply equal layout")
    b = a; b.id = UUID()
    precondition(ChatMessageShape(a) != ChatMessageShape(b), "cached heights belong to their step identities")
    a.role = .tool; a.detail = "ab cd"; b = a; b.detail = "ab\ncd"
    precondition(ChatMessageShape(a) != ChatMessageShape(b), "equal-length tool results still refresh")
    let sameLengthShapes = [ChatMessageShape(a): 1, ChatMessageShape(b): 2]
    precondition(sameLengthShapes.count == 2, "equal-length edits remain separate cache entries")
    a.text = "\u{00E9}"; b = a; b.text = "e\u{0301}"
    precondition(ChatMessageShape(a) == ChatMessageShape(b), "canonical Unicode equivalents compare equally")
    let unicodeShapes = [ChatMessageShape(a): 3]
    precondition(unicodeShapes[ChatMessageShape(b)] == 3, "equal Unicode strings must share a compatible hash")

    let prompt = ChatMessage(id: turn, role: .user, text: "Work")
    var completedHeader = ChatMessage(role: .turn(running: false, seconds: 8), text: "")
    completedHeader.turnMessageID = turn
    var emptyReply = ChatMessage(role: .assistant, text: " \n\t ")
    emptyReply.isReply = true
    emptyReply.turnMessageID = turn
    let completed = ChatProcessPresentation.rows([prompt, completedHeader, emptyReply]) { _ in false }
    precondition(!completed.contains { $0.role == .assistant }, "an empty completed reply adds no trailing blank row")
    emptyReply.turnStats = ChatTurnStats()
    let retainedStats = ChatProcessPresentation.rows([prompt, completedHeader, emptyReply]) { _ in false }
    precondition(retainedStats.last?.turnStats != nil, "metadata-bearing empty rows remain visible")
    print("ok: stream snapshots, retained banners, turn counts, retries, replay, exact cache shapes and terminal spacing")
}
