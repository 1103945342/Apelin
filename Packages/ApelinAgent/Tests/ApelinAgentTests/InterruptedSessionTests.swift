@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

@Suite("Reopening a turn whose worker disappeared")
struct InterruptedSessionTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `reopen ends an abandoned turn before replay and does not end it twice`(compacting: Bool) async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let id = UUID().uuidString
        let messageID = UUID()
        let queuedID = UUID()
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: id)
        // The device's failing history: a prompt and reconnects, then a
        // queued message, but no messageStarted and no finished event.
        try await log.append(.userMessage(id: messageID, text: "Try", attachments: []))
        try await log.append(.reconnecting)
        try await log.append(.reconnecting)
        try await log.append(.userMessageQueued(id: queuedID, text: "Waiting", attachments: []))
        if compacting { try await log.append(.compactionStarted) }
        let original = try await log.records(afterSeq: 0)
        await log.close() // close the file only, as a dead worker leaves it

        let configuration = AgentSessionConfiguration(
            id: id, project: home.project, provider: .registered(faux.getModel()),
            approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot,
        )
        func open() async throws -> AgentSession {
            try await AgentSession(
                configuration: configuration, backend: MockBackend(),
                digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
            )
        }
        let session = try await open()
        let expected: [AgentSessionEvent] = compacting
            ? [.compactionFinished(.init(outcome: .cancelled)), .finished(reason: .aborted)]
            : [.finished(reason: .aborted)]
        let records = try await session.log.records(afterSeq: 0)
        #expect(Array(records.prefix(original.count)) == original, "never rewrite or delete the interrupted history")
        #expect(records.dropFirst(original.count).map(\.event) == expected)
        #expect(try await session.replayBoundary() == records.last?.seq, "recovery belongs to history, not a fresh live completion")
        await session.abort()
        await session.waitForIdle()
        await session.close()

        let reopened = try await open()
        #expect(try await reopened.log.records(afterSeq: 0) == records, "opening and Stop must not duplicate the end")
        #expect(await reopened.log.opened.interruptionEvents.isEmpty)
        // Wait for an actual event, not waitForIdle before prompt's queued
        // acceptance has established runTask.
        let events = try await reopened.events(afterSeq: records.last?.seq ?? 0)
        faux.setResponses([.message(fauxAssistantMessage("Next reply"))])
        try await reopened.prompt("Continue")
        var completed = false
        for await record in events {
            if case .finished = record.event {
                completed = record.event == .finished(reason: .completed)
                break
            }
        }
        await reopened.waitForIdle()
        #expect(completed)
        #expect(try await reopened.log.records(afterSeq: 0).contains { $0.event == .messageFinished(text: "Next reply") })
        await reopened.close()
    }

    @Test
    func `summary matches the readers turn boundaries and preserves completed idle sessions`() {
        let starts: [AgentSessionEvent] = [
            .userMessage(id: UUID(), text: "x", attachments: []),
            .conversationMessageTaken(id: UUID(), text: "x", from: "source"),
            .promptSubmitted(text: "legacy"), .steered(text: "legacy"), .messageStarted,
        ]
        for start in starts {
            var summary = SessionEventLog.Summary()
            func record(_ event: AgentSessionEvent) -> SessionEventRecord {
                SessionEventRecord(seq: 1, date: Date(), event: event)
            }
            summary.add(record(start))
            summary.add(record(.reconnecting))
            #expect(summary.interruptionEvents == [.finished(reason: .aborted)])
            summary.add(record(.messageFinished(text: "a tool step is not the end of a run")))
            #expect(summary.unfinishedTurn)
            summary.add(record(.finished(reason: .completed)))
            summary.add(record(.titleUpdated("Title")))
            #expect(summary.interruptionEvents.isEmpty)
        }
        let events: [AgentSessionEvent] = [.compactionStarted, .compactionFinished(.init(outcome: .cancelled))]
        let records = events.enumerated().map { SessionEventRecord(seq: UInt64($0.offset + 1), date: Date(), event: $0.element) }
        #expect(SessionEventLog.Summary(records).interruptionEvents.isEmpty)
        #expect(SessionEventLog.Summary().interruptionEvents.isEmpty)
    }
}
