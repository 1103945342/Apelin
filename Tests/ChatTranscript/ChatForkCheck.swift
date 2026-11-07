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
    print("ok: fork history is distinguished from live events")
}
