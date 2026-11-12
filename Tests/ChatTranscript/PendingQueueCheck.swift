import ApelinCore
import ApelinProtocol
import Foundation

/// The pending queue is not history or steering. Every snapshot replaces it,
/// including same-id edits, and does not disturb a live turn's presentation.
func checkPendingQueuePresentation() {
    let a = UUID(), b = UUID(), turn = UUID()
    let file = ComposerAttachment(name: "note.pdf", data: Data([1, 2, 3]))
    func item(_ id: UUID, _ text: String, held: Bool = false, attachment: Bool = false) -> JSONValue {
        .object(["id": .string(id.uuidString), "text": .string(text), "editing": .bool(held),
                 "attachments": .array(attachment ? [.object([
                    "name": .string(file.name), "path": .string("Attachments/note.pdf"), "mimeType": .string("application/pdf")
                 ])] : [])])
    }
    func snapshot(_ seq: UInt64, _ items: [JSONValue], paused: Bool = false) -> TaskEvent {
        TaskEvent(seq: EventSeq(seq), kind: "pendingQueue", payload: .object([
            "messages": .array(items), "paused": .bool(paused)
        ]))
    }
    let start = TaskEvent(seq: EventSeq(1), kind: "prompt", payload: .object([
        "id": .string(turn.uuidString), "text": .string("Working")
    ]))
    let count = TaskEvent(seq: EventSeq(2), kind: "received", payload: .object(["tokens": .number(123)]))
    let first = snapshot(3, [item(a, "A", attachment: true), item(b, "B")])
    var events = [start, count, first]
    var incremental = ChatTranscript(events: events) { _ in file }
    precondition(incremental.pendingMessages.map(\.id) == [a, b])
    precondition(incremental.pendingMessages.first?.attachments == [file])
    precondition(!incremental.messages.contains { $0.id == a || $0.id == b })
    let header = incremental.messages.first { if case .turn = $0.role { return true }; return false }
    precondition(header?.headerReceivedTokens == 123)
    for update in [
        snapshot(4, [item(b, "B"), item(a, "A", held: true, attachment: true)]),
        snapshot(5, [item(b, "B edited"), item(a, "A", attachment: true)], paused: true),
        snapshot(6, [item(a, "A", attachment: true)], paused: true),
        snapshot(7, [])
    ] {
        events.append(update)
        incremental.append([update]) { _ in file }
        let replay = ChatTranscript(events: events) { _ in file }
        precondition(incremental.pendingMessages == replay.pendingMessages)
        precondition(incremental.pendingPaused == replay.pendingPaused)
        precondition(incremental.pendingHeld == replay.pendingHeld)
        precondition(incremental.messages == replay.messages)
        if update.seq == EventSeq(4) {
            precondition(incremental.pendingMessages.map(\.id) == [b, a])
            precondition(incremental.pendingHeld == [a])
        }
        if update.seq == EventSeq(5) {
            precondition(incremental.pendingMessages[0].text == "B edited")
            precondition(incremental.pendingHeld.isEmpty && incremental.pendingPaused)
        }
    }
    precondition(incremental.pendingMessages.isEmpty)
    let receipts = ChatTranscript.acceptedMessages(in: first)
    precondition(receipts.compactMap(ChatTranscript.userMessageID) == [a, b])
    guard case let .array(savedFiles)? = receipts.first?.payload?["attachments"] else {
        preconditionFailure("receipt retains attachment metadata")
    }
    precondition(savedFiles.count == 1)
    let paged = ChatTranscript(events: [count], firstEvent: 8, pendingSnapshot: first) { _ in file }
    precondition(paged.pendingMessages.map(\.id) == [a, b] && paged.endEvent == 9)
    var sending = ComposerDraft(text: "A", attachments: [file])
    sending.id = a
    let accepted = ChatTranscript(events: [first], sending: [sending]) { _ in file }
    precondition(accepted.messages.isEmpty && accepted.pendingMessages.count == 2)
    var record = ChatRecord(summary: ChatSummary(title: "Queue", lastInteraction: Date()))
    record.submit(sending)
    record.events = [first]
    let echoed = record.takeEchoed(by: [first])
    precondition(echoed.count == 1 && echoed[0].draft.attachments == [file])
    precondition(record.sending == nil && record.draft.attachments.isEmpty)
    precondition(!record.takeBack(sending), "an accepted pending input is not restored on a late send failure")
    record.sending = [sending]
    record.reclaimUnsent()
    precondition(record.sending == nil && record.draft.text.isEmpty, "relaunch recognizes pending receipts")
    let unsent = ComposerDraft(text: "Not accepted", attachments: [file])
    record.submit(unsent)
    precondition(record.takeBack(unsent) && record.draft.attachments == [file])
    let taken = TaskEvent(seq: EventSeq(9), kind: "prompt", payload: .object([
        "id": .string(a.uuidString), "text": .string("A")
    ]))
    incremental.append([taken]) { _ in file }
    precondition(incremental.messages.filter { $0.id == a }.count == 1)
    let sourceSnapshot = snapshot(10, [.object([
        "id": .string(b.uuidString), "text": .string("Correct course"),
        "attachments": .array([]), "delivery": .string("steer"),
        "sender": .object(["sessionID": .string("reviewer"), "title": .string("Review")])
    ])])
    let sourceView = ChatTranscript(events: [sourceSnapshot]) { _ in nil }
    precondition(sourceView.pendingMessages.first?.sender?.contains("Review") == true)
    precondition(sourceView.pendingMessages.first?.queueDelivery == "steer")
    precondition(sourceView.messages.isEmpty)
    print("ok: pending queue order, same-id edits, deletion, hold/resume, attachments, receipts, replay and paged seed")
}
