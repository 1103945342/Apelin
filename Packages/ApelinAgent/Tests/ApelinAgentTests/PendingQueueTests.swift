@testable import ApelinAgent
import ApelinProtocol
import Foundation
import Testing

@Suite("Persistent pending queue")
struct PendingQueueTests {
    @Test
    func `hold edit reorder and delete commit atomically and survive reopen`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        var queue = try PendingQueue(directory: home.projectURL, taken: [])
        let a = PendingMessage(id: UUID(), text: "a", attachments: [.init(path: "Attachments/image", name: "image", mimeType: "image/png")])
        let b = PendingMessage(id: UUID(), text: "b", attachments: [])
        try queue.enqueue(a)
        try queue.enqueue(b)
        try queue.enqueue(a)
        #expect(queue.state.messages == [a, b])
        try queue.change(.init(sessionID: "s", action: .hold, messageID: a.id))
        #expect(queue.state.messages.first?.editing == true)
        let before = queue.state
        #expect(throws: (any Error).self) {
            try queue.change(.init(sessionID: "s", action: .reorder, order: [a.id, a.id]))
        }
        #expect(queue.state == before)
        #expect(throws: (any Error).self) {
            try queue.change(.init(sessionID: "s", action: .reorder, order: [b.id]))
        }
        try queue.change(.init(sessionID: "s", action: .edit, messageID: a.id, text: "edited"))
        #expect(queue.state.messages.first?.editing == false)
        #expect(queue.state.messages.first?.attachments == a.attachments)
        try queue.change(.init(sessionID: "s", action: .reorder, order: [b.id, a.id]))
        queue = try PendingQueue(directory: home.projectURL, taken: [])
        #expect(queue.state.paused)
        #expect(queue.state.messages.map(\.id) == [b.id, a.id])
        try queue.change(.init(sessionID: "s", action: .delete, messageID: b.id))
        try queue.enqueue(b)
        #expect(queue.state.messages.map(\.id) == [a.id], "deleted ids remain deduplicated")
        try queue.change(.init(sessionID: "s", action: .resume))
        #expect(!queue.state.paused)
    }

    @Test
    func `a take interrupted before prompt publication recovers exactly once`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        var queue = try PendingQueue(directory: home.projectURL, taken: [])
        let a = PendingMessage(id: UUID(), text: "a", attachments: [])
        let b = PendingMessage(id: UUID(), text: "b", attachments: [])
        try queue.enqueue(a)
        try queue.enqueue(b)
        _ = try queue.take(a.id)
        queue = try PendingQueue(directory: home.projectURL, taken: [])
        #expect(queue.state.messages == [a, b])
        #expect(queue.state.paused)
        _ = try queue.take(a.id)
        queue = try PendingQueue(directory: home.projectURL, taken: [a.id])
        #expect(queue.state.messages == [b])
        try queue.enqueue(a)
        #expect(queue.state.messages == [b])
    }

    @Test
    func `reopen clears stale editing holds and an empty queue accepts fresh input`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        var queue = try PendingQueue(directory: home.projectURL, taken: [])
        let message = PendingMessage(id: UUID(), text: "kept", attachments: [])
        try queue.enqueue(message)
        try queue.change(.init(sessionID: "s", action: .hold, messageID: message.id))
        queue = try PendingQueue(directory: home.projectURL, taken: [])
        #expect(queue.state.paused && queue.state.messages.first?.editing == false)
        try queue.change(.init(sessionID: "s", action: .delete, messageID: message.id))
        queue = try PendingQueue(directory: home.projectURL, taken: [])
        #expect(queue.state.messages.isEmpty && !queue.state.paused)
    }

    @Test
    func `blank edits require attachments and failed edits preserve a hold`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        var queue = try PendingQueue(directory: home.projectURL, taken: [])
        let plain = PendingMessage(id: UUID(), text: "keep", attachments: [])
        let file = PendingMessage(id: UUID(), text: "caption", attachments: [.init(path: "Attachments/note", name: "note", mimeType: "text/plain")])
        try queue.enqueue(plain)
        try queue.enqueue(file)
        try queue.change(.init(sessionID: "s", action: .hold, messageID: plain.id))
        let before = queue.state
        #expect(throws: (any Error).self) {
            try queue.change(.init(sessionID: "s", action: .edit, messageID: plain.id, text: " \n "))
        }
        #expect(queue.state == before)
        try queue.change(.init(sessionID: "s", action: .edit, messageID: file.id, text: ""))
        #expect(queue.state.messages.last?.text == "" && queue.state.messages.last?.attachments == file.attachments)
    }

    @Test
    func `bad persisted data is never overwritten by an empty queue`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let path = home.projectURL.appendingPathComponent("pending.json")
        let bytes = Data("{broken".utf8)
        try bytes.write(to: path)
        #expect(throws: (any Error).self) { _ = try PendingQueue(directory: home.projectURL, taken: []) }
        #expect(try Data(contentsOf: path) == bytes)
    }

    @Test
    func `source delivery and per-message model choice survive edits and recovery`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        var parameters = AgentModelParameters()
        parameters.contextWindow = 32768
        let choice = PendingModelChoice(provider: .openAICompatible(model: "queued-model"),
            wireProvider: .openAICompatible, model: "queued-model", reasoningEffort: .max,
            serviceTier: .ultrafast, parameters: parameters)
        let original = PendingMessage(id: UUID(), text: "same", attachments: [],
            sender: ConversationSender(sessionID: "reviewer", title: "Review"),
            delivery: .steer, modelChoice: choice)
        var queue = try PendingQueue(directory: home.projectURL, taken: [])
        try queue.enqueue(original)
        try queue.change(.init(sessionID: "s", action: .edit, messageID: original.id, text: "edited"))
        _ = try queue.take(original.id)
        queue = try PendingQueue(directory: home.projectURL, taken: [])
        var expected = original
        expected.text = "edited"
        #expect(queue.state.messages == [expected])
        #expect(queue.state.paused)
        #expect(queue.state.handoffs.isEmpty)
        let legacy = Data("{\"id\":\"\(UUID().uuidString)\",\"text\":\"old\",\"attachments\":[],\"editing\":false}".utf8)
        let decoded = try JSONDecoder().decode(PendingMessage.self, from: legacy)
        #expect(decoded.modelChoice == nil && decoded.sender == nil && decoded.delivery == nil)
    }

    @Test
    func `failed commit leaves the live queue unchanged`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        var queue = try PendingQueue(directory: home.projectURL, taken: [])
        let path = home.projectURL.appendingPathComponent("pending.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let before = queue.state
        #expect(throws: (any Error).self) {
            try queue.enqueue(PendingMessage(id: UUID(), text: "keep", attachments: []))
        }
        #expect(queue.state == before)
    }
}
