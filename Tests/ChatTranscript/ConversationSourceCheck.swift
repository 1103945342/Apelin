import ApelinProtocol
import Foundation

func checkConversationSource() {
    let reader = UUID(), first = UUID(), second = UUID()
    let fromPhone = UUID(), stranger = UUID()
    let events = [
        event(1, "prompt", ["id": .string(reader.uuidString), "text": .string("My task")]),
        event(2, "messageStarted"),
        event(3, "queued", ["id": .string(first.uuidString), "from": .string("a"), "text": .string("Review")]),
        event(4, "message", ["text": .string("My answer")]),
        event(5, "prompt", ["id": .string(first.uuidString), "from": .string("a"), "text": .string("Review")]),
        event(6, "messageStarted"),
        event(7, "queued", ["id": .string(second.uuidString), "from": .string("b"), "text": .string("Next")]),
        event(8, "toolCall", ["id": .string("tool"), "tool": .string("file_read")]),
        event(9, "toolResult", ["id": .string("tool"), "output": .string("result")]),
        event(10, "prompt", ["id": .string(second.uuidString), "from": .string("b"), "text": .string("Next")]),
        event(11, "messageStarted"),
        event(12, "finished"),
        event(13, "prompt", ["id": .string(UUID().uuidString), "text": .string("Reader again")]),
        // A message the reader sent from WeChat: marked over its bubble as any
        // other conversation's is, with the channel's name.
        event(14, "queued", [
            "id": .string(fromPhone.uuidString), "text": .string("From the phone"),
            "source": .string(ChatChannel.weChat),
        ]),
        event(15, "prompt", [
            "id": .string(fromPhone.uuidString), "text": .string("From the phone"),
            "source": .string(ChatChannel.weChat),
        ]),
        // A channel this build does not know names nothing over the bubble.
        event(16, "prompt", [
            "id": .string(stranger.uuidString), "text": .string("Elsewhere"),
            "source": .string("matrix"),
        ]),
    ]
    let title: (String) -> String? = { $0 == "a" ? "Review chat" : nil }
    func build(_ end: Int) -> ChatTranscript {
        ChatTranscript(events: Array(events.prefix(end)), conversationTitle: title) { _ in nil }
    }
    let waiting = build(3)
    precondition(waiting.messages.first { $0.id == first }?.sender == ChatTranscript.senderLine("Review chat"))
    precondition(waiting.messages.first { $0.id == first }?.isQueued == true)
    precondition(waiting.messages.filter { $0.role.isThinking }.allSatisfy { $0.processingSource == nil },
                 "arrival does not claim the model has taken a follow-up")
    let taken = build(5)
    precondition(taken.messages.last?.processingSource == ChatTranscript.processingLine("Review chat"))
    precondition(taken.messages.filter { $0.id == first }.count == 1 && !taken.messages.first { $0.id == first }!.isQueued)
    let nextQueued = build(8)
    precondition(nextQueued.messages.first { $0.role.isThinking }?.processingSource == ChatTranscript.processingLine("Review chat"),
                 "tools and a second queued sender do not replace the active source")
    precondition(nextQueued.messages.last?.sender == ChatTranscript.senderLine(nil))
    precondition(build(11).messages.last?.processingSource == ChatTranscript.processingLine(nil))
    precondition(build(12).messages.allSatisfy { $0.processingSource == nil }, "finished summaries have no active source")
    precondition(build(13).messages.last?.processingSource == nil, "reader prompts clear the prior source")
    var incremental = ChatTranscript(events: []) { _ in nil }
    for end in 1...events.count {
        incremental.append([events[end - 1]], conversationTitle: title) { _ in nil }
        precondition(incremental.messages == build(end).messages, "batching preserves source and queue state")
    }
    let dropped = ChatTranscript(events: Array(events.prefix(3)) + [
        event(4, "queueDropped", ["ids": .array([.string(first.uuidString)])]), event(5, "finished"),
    ], conversationTitle: title) { _ in nil }
    precondition(!dropped.messages.contains { $0.id == first }, "unconsumed follow-ups disappear on stop")
    let weChat = ChatTranscript.sourceLine(ChatChannel.weChat)
    precondition(weChat == ChatTranscript.senderLine(String(localized: "WeChat")), "the channel is named as Settings names it")
    let waitingPhone = build(14).messages.first { $0.id == fromPhone }
    precondition(waitingPhone?.sender == weChat && waitingPhone?.isQueued == true, "a queued message from the phone is marked")
    let answeredPhone = build(15).messages.first { $0.id == fromPhone }
    precondition(answeredPhone?.sender == weChat && answeredPhone?.isQueued == false, "and keeps the mark once its turn runs")
    precondition(build(16).messages.first { $0.id == stranger }?.sender == nil, "an unknown channel names nothing")
    print("ok: queued and active conversation sources, a chat channel's messages, unknown sender, tool loop, completion and incremental replay")
}
