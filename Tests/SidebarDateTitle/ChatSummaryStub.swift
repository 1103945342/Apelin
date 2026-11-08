import Foundation

struct ChatSummary {
    var id: UUID = UUID()
    var lastInteraction: Date
    var isPinned = false
}
