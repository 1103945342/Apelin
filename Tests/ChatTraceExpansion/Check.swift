import Foundation

/// Build with ChatTraceExpansion.swift; no UI or app dependencies are needed.
@main
struct ChatTraceExpansionCheck {
    @MainActor
    static func main() {
        let turn = UUID()
        let thought = UUID()
        let call = UUID()
        let other = UUID()
        ChatTraceExpansion.setExpanded(turn: turn, true)
        ChatTraceExpansion.setExpanded(thought: thought, true)
        ChatTraceExpansion.setExpanded(call: call, true)
        ChatTraceExpansion.setExpanded(turn: other, true)
        ChatTraceExpansion.setExpanded(thought: other, true)
        ChatTraceExpansion.setExpanded(call: other, true)

        ChatTraceExpansion.collapse(ids: [turn, thought, call, UUID()])
        precondition(!ChatTraceExpansion.isExpanded(turn: turn))
        precondition(!ChatTraceExpansion.isExpanded(thought: thought))
        precondition(!ChatTraceExpansion.isExpanded(call: call))
        precondition(ChatTraceExpansion.isExpanded(turn: other))
        precondition(ChatTraceExpansion.isExpanded(thought: other))
        precondition(ChatTraceExpansion.isExpanded(call: other))

        ChatTraceExpansion.collapse(ids: [])
        ChatTraceExpansion.collapse(ids: [turn, thought, call])
        precondition(ChatTraceExpansion.isExpanded(turn: other))
        ChatTraceExpansion.setExpanded(turn: turn, true)
        ChatTraceExpansion.setExpanded(thought: thought, true)
        ChatTraceExpansion.setExpanded(call: call, true)
        precondition(ChatTraceExpansion.isExpanded(turn: turn))
        precondition(ChatTraceExpansion.isExpanded(thought: thought))
        precondition(ChatTraceExpansion.isExpanded(call: call))
        print("ok: scoped collapse, all three levels, empty/repeated collapse and reopening")
    }
}
