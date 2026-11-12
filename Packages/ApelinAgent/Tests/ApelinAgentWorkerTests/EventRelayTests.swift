import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import Foundation
import Testing

@Suite("The relay coalesces what streams")
struct EventRelayTests {
    @Test
    func `pending snapshot is distinct from model queued events`() async throws {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        let id = UUID()
        let message = PendingMessage(id: id, text: "Later", attachments: [], editing: true)
        await relay.relay(.pendingQueue(messages: [message], paused: true))
        #expect(emitted.kinds == ["pendingQueue"])
        let value = try #require(emitted.payloads(of: "pendingQueue").first ?? nil)
        #expect(value["paused"]?.boolValue == true)
        #expect(value["messages"] == .array([.object([
            "id": .string(id.uuidString), "text": .string("Later"),
            "attachments": .array([]), "editing": .bool(true),
        ])]))
    }

    /// What a relay emitted, in order.
    final class Emitted: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(String, ApelinCore.JSONValue?)] = []

        func append(_ kind: String, _ payload: ApelinCore.JSONValue?) {
            lock.withLock { events.append((kind, payload)) }
        }

        var kinds: [String] {
            lock.withLock { events.map(\.0) }
        }

        var tokens: [Double] {
            lock.withLock { events.filter { $0.0 == "received" }.compactMap { $0.1?["tokens"]?.doubleValue } }
        }

        func payloads(of kind: String) -> [ApelinCore.JSONValue?] {
            lock.withLock { events.filter { $0.0 == kind }.map(\.1) }
        }
    }

    /// kwwk asks again for a message it had begun: the app takes back what
    /// it showed, then hears the request is being made again.
    @Test
    func `a message given up follows its text out, and the request made again follows it`() async {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        await relay.relay(.messageStarted)
        await relay.relay(.textDelta("Partial"))
        await relay.relay(.messageDiscarded)
        await relay.relay(.reconnecting)
        await relay.relay(.messageStarted)
        #expect(emitted.kinds == ["messageStarted", "text", "messageDiscarded", "reconnecting", "messageStarted"])
        #expect(emitted.payloads(of: "messageDiscarded") == [nil] && emitted.payloads(of: "reconnecting") == [nil])
    }

    @Test
    func `historical and realtime streaming never share a coalesced event`() async throws {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        await relay.relay(.textDelta("from snapshot"), historical: true)
        await relay.relay(.textDelta("from live"), historical: false)
        await relay.flush()

        let payloads = emitted.payloads(of: "text")
        let texts = payloads.compactMap { $0?["text"]?.stringValue }
        #expect(texts == ["from snapshot", "from live"])
        try #require(payloads.count == 2)
        #expect(payloads[0]?["historical"]?.boolValue == true)
        #expect(payloads[1]?["historical"] == nil)
    }

    @Test
    func `conversation queue and acceptance keep the same source and identity`() async {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        let id = UUID()
        await relay.relay(.conversationMessageQueued(id: id, text: "Review", from: "reviewer"), historical: true)
        await relay.relay(.conversationMessageTaken(id: id, text: "Review", from: "reviewer"), historical: true)
        await relay.relay(.conversationMessagesDropped(ids: [id]), historical: false)
        #expect(emitted.kinds == ["queued", "prompt", "queueDropped"])
        for kind in ["queued", "prompt"] {
            let payload = emitted.payloads(of: kind).compactMap { $0 }.first
            #expect(payload?["id"]?.stringValue == id.uuidString)
            #expect(payload?["from"]?.stringValue == "reviewer")
            #expect(payload?["text"]?.stringValue == "Review")
            #expect(payload?["historical"]?.boolValue == true)
        }
        let dropped = emitted.payloads(of: "queueDropped").compactMap { $0 }.first
        #expect(dropped?["ids"] == .array([.string(id.uuidString)]))
        #expect(dropped?["historical"] == nil)
    }

    @Test
    func `historical events with no payload still carry the marker`() async {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        await relay.relay(.messageStarted, historical: true)
        #expect(emitted.payloads(of: "messageStarted").compactMap { $0 }.first?["historical"]?.boolValue == true)
    }

    /// The host stamps an event with the moment it relayed it, so a
    /// conversation read back — a fork's whole history — says `at` beside
    /// `historical`, and the turns in it keep the time they took.
    @Test
    func `a replayed record says when it happened, and a live one says nothing`() async {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        let wrote = Date(timeIntervalSince1970: 1_700_000_000)
        await relay.relay(.messageStarted, historical: true, at: wrote)
        await relay.relay(.thinkingDelta("from snapshot"), historical: true, at: wrote.addingTimeInterval(2))
        await relay.relay(.reconnecting)
        await relay.flush()

        let started = emitted.payloads(of: "messageStarted").compactMap { $0 }.first
        #expect(started?["at"]?.doubleValue == wrote.timeIntervalSince1970)
        // Coalesced streaming says when its last record was written.
        let thinking = emitted.payloads(of: "thinking").compactMap { $0 }.first
        #expect(thinking?["at"]?.doubleValue == wrote.addingTimeInterval(2).timeIntervalSince1970)
        #expect(emitted.payloads(of: "reconnecting") == [nil])
    }

    @Test
    func `the received count goes out with the streamed text, only its latest and only when new`() async {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        await relay.relay(.messageStarted)
        await relay.relay(.textDelta("Reading"))
        await relay.relay(.received(tokens: 2))
        await relay.relay(.textDelta(" it."))
        await relay.relay(.received(tokens: 3))
        await relay.relay(.toolCallPreparing)
        // within a quarter second this is one flush; a slow machine may
        // flush between the two, never sending a count twice
        #expect(emitted.kinds.suffix(2) == ["received", "toolCallPreparing"])
        #expect(emitted.tokens.last == 3 && emitted.tokens.count <= 2)
        let sent = emitted.tokens.count
        // a flush with no new count sends none
        await relay.relay(.messageFinished(text: "Reading it."))
        #expect(emitted.tokens.count == sent)
        await relay.relay(.received(tokens: 40))
        await relay.relay(.finished(reason: .completed))
        #expect(emitted.kinds.suffix(2) == ["received", "finished"], "the last count goes before the run's end")
        #expect(emitted.tokens.last == 40 && emitted.tokens.count == sent + 1)
    }
}
