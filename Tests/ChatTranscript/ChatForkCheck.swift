import ApelinProtocol
import Foundation

func checkChatForkHistory() {
    let historical = TaskEvent(
        seq: EventSeq(1),
        kind: "message",
        payload: .object(["text": .string("old"), "historical": .bool(true)])
    )
    let realtime = TaskEvent(seq: EventSeq(2), kind: "message", payload: .object(["text": .string("new")]))
    precondition(ChatFork.isHistorical(historical), "historical replay marker is recognized")
    precondition(!ChatFork.isHistorical(realtime), "ordinary events remain realtime")
    var fork = ChatRecord(summary: ChatSummary(title: "Fork", lastInteraction: Date()), sessionID: UUID().uuidString)
    precondition(
        ChatFork.needsHistoryLoad(fork, isFollowed: false, eventCount: 0),
        "empty forks load without a send"
    )
    precondition(
        !ChatFork.needsHistoryLoad(fork, isFollowed: true, eventCount: 0),
        "a replay already followed is not opened again"
    )
    // A conversation with history is shown from the events on disk: opening
    // its session to look at it starts a worker that waits for a prompt, and a
    // task the host calls running with no turn going.
    precondition(
        !ChatFork.needsHistoryLoad(fork, isFollowed: false, eventCount: 1),
        "a chat with history opens no session just for being looked at"
    )
    fork.sessionID = nil
    precondition(
        !ChatFork.needsHistoryLoad(fork, isFollowed: false, eventCount: 0),
        "a draft alone never starts a session"
    )
    print("ok: fork history is distinguished from live events and loads on selection")
}
