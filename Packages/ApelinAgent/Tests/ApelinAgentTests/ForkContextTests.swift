@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Historical fork contexts")
struct ForkContextTests {
    private func anchor(_ message: UserMessage) -> HistoryAnchor {
        let text = ConversationHistory.text(of: message)
        return HistoryAnchor(digest: ConversationHistory.digest(text), typed: text, suffixBytes: 0, timestamp: message.timestamp)
    }

    @Test
    func `sealed turns survive compaction edits rewind and reopening`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let sessionID = UUID().uuidString
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        let first = UUID()
        let second = UUID()
        let user = UserMessage(text: "First")
        let later = UserMessage(text: "Second")
        let initial: [Message] = [.user(user), .assistant(fauxAssistantMessage("Original answer"))]
        let anchors = [first.uuidString.lowercased(): anchor(user), second.uuidString.lowercased(): anchor(later)]
        try await log.append(.userMessage(id: first, text: "First", attachments: []))
        try await log.append(.messageFinished(text: "Original answer"))
        try await log.append(.finished(reason: .completed))
        try await log.writeHistorySnapshot(initial, anchors: anchors, seal: true)
        let original = try #require(try await log.readForkContext(first))

        try await log.append(.replyEdited(id: first, text: "Edited later"))
        try await log.append(.userMessage(id: second, text: "Second", attachments: []))
        try await log.append(.messageFinished(text: "Second answer"))
        try await log.append(.finished(reason: .completed))
        let secondContext: [Message] = [.user(user), .assistant(fauxAssistantMessage("Edited later")), .user(later), .assistant(fauxAssistantMessage("Second answer"))]
        try await log.writeHistorySnapshot(secondContext, anchors: anchors, seal: true)
        try await log.writeTranscript([.user(UserMessage(text: "A compacted summary"))])
        try await log.append(.historyRewound(id: second))
        try await log.writeTranscript([])
        await log.close()

        let reopened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        let firstAgain = try #require(try await reopened.readForkContext(first))
        let secondAgain = try #require(try await reopened.readForkContext(second))
        #expect(firstAgain.messages == initial)
        #expect(firstAgain.records == original.records)
        #expect(secondAgain.messages == secondContext)
        #expect(firstAgain.anchors[first.uuidString.lowercased()]?.timestamp == user.timestamp)
        #expect(firstAgain.anchors[second.uuidString.lowercased()] == nil)
        #expect(secondAgain.anchors[second.uuidString.lowercased()]?.timestamp == later.timestamp)
        await reopened.close()
    }

    @Test
    func `images and untruncated tool results are model objects not UI reconstructions`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: UUID().uuidString)
        let id = UUID()
        let user = UserMessage(content: [
            .text(TextContent(text: "Read the image")),
            .image(ImageContent(data: "aW1hZ2UtYnl0ZXM=", mimeType: "image/png")),
        ])
        let fullResult = String(repeating: "untruncated result ", count: 10000)
        let messages: [Message] = [
            .user(user),
            .assistant(fauxAssistantMessage(blocks: [fauxToolCall(name: "file_read", arguments: ["path": "large.txt"], id: "call-1")], stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: "call-1", toolName: "file_read", content: [.text(TextContent(text: fullResult))])),
            .assistant(fauxAssistantMessage("Read it")),
        ]
        try await log.append(.userMessage(id: id, text: "Read the image", attachments: []))
        try await log.append(.messageFinished(text: "Read it"))
        try await log.append(.finished(reason: .completed))
        try await log.writeHistorySnapshot(messages, anchors: [id.uuidString.lowercased(): anchor(user)], seal: true)
        let saved = try #require(try await log.readForkContext(id))
        #expect(saved.messages == messages)
        await log.close()
    }

    @Test
    func `fork owns selected and ancestor snapshots after source deletion`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let sourceID = UUID().uuidString.lowercased()
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sourceID)
        let first = UUID()
        let second = UUID()
        let user = UserMessage(text: "First")
        let later = UserMessage(text: "Second")
        let anchors = [first.uuidString.lowercased(): anchor(user), second.uuidString.lowercased(): anchor(later)]
        let initial: [Message] = [.user(user), .assistant(fauxAssistantMessage("First reply"))]
        try await log.append(.userMessage(id: first, text: "First", attachments: []))
        try await log.append(.messageFinished(text: "First reply"))
        try await log.append(.finished(reason: .completed))
        try await log.writeHistorySnapshot(initial, anchors: anchors, seal: true)
        try await log.append(.userMessage(id: second, text: "Second", attachments: []))
        let partial = initial + [.user(later)]
        try await log.writeHistorySnapshot(partial, anchors: anchors)
        let selected = try #require(try await log.readForkContext(second))

        // The source advances after selection, before copy; the selected
        // version, not the newly written manifest, is what the fork owns.
        try await log.append(.messageFinished(text: "Later response"))
        try await log.append(.finished(reason: .completed))
        try await log.writeHistorySnapshot(partial + [.assistant(fauxAssistantMessage("Later response"))], anchors: anchors, seal: true)
        let forkID = UUID().uuidString.lowercased()
        let metadata = SessionMetadata(id: forkID, project: home.project, provider: .registered(faux.getModel()), mode: .confirm, created: Date())
        try SessionEventLog.writeFork(
            sessionsRoot: home.dataRoot.sessions, metadata: metadata,
            records: selected.records, transcript: selected.messages, anchors: selected.anchors,
            historySource: log.directory, through: second,
        )
        await log.close()
        try FileManager.default.removeItem(at: log.directory)
        let fork = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: forkID)
        #expect(try await fork.readTranscript() == partial)
        let firstFork = try #require(try await fork.readForkContext(first))
        let secondFork = try #require(try await fork.readForkContext(second))
        #expect(firstFork.messages == initial)
        #expect(secondFork.messages == partial)
        #expect(secondFork.records == selected.records)
        #expect(try await fork.records(afterSeq: 0).map(\.seq) == Array(1 ... UInt64(selected.records.count)))
        await fork.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `session forks original context after editing and rewinding the live conversation`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("Original reply"))])
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let messageID = UUID()
        try await session.prompt("Keep this context", messageID: messageID)
        await session.waitForIdle()
        let before = try await session.log.readTranscript()
        try await session.edit(messageID, reply: true, text: "Changed reply", expected: "Original reply")
        try await session.rewind(to: messageID, truncate: true)
        let forkID = UUID().uuidString.lowercased()
        try await session.fork(through: messageID, as: forkID)
        let fork = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: forkID)
        #expect(try await fork.readTranscript() == before)
        let events = try await fork.records(afterSeq: 0)
        #expect(!events.contains { record in
            if case .replyEdited = record.event { return true }
            if case .historyRewound = record.event { return true }
            return false
        })
        await fork.close()
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a running tool turn forks its last complete boundary without stopping the source`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(
                name: "apelin_package_remove",
                arguments: ["reason": "Remove it", "installation_id": "inst-1"],
            )], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Not reached")),
        ])
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let stream = try await session.events(afterSeq: 0)
        let id = UUID()
        try await session.prompt("Remove it", messageID: id)
        for await record in stream {
            guard case .approvalRequested = record.event else { continue }
            let forkID = UUID().uuidString.lowercased()
            try await session.fork(through: id, as: forkID)
            let fork = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: forkID)
            let messages = try await fork.readTranscript()
            #expect(messages.filter(ConversationHistory.isReaderMessage).count == 1)
            #expect(ForkContext.hasCompleteToolResults(messages))
            #expect(!(await session.pendingApprovals).isEmpty)
            let records = try await fork.records(afterSeq: 0)
            #expect(!records.contains { if case .approvalRequested = $0.event { return true }; return false })
            await fork.close()
            await session.abort()
            break
        }
        await session.close()
    }

    @Test
    func `lost legacy context is refused instead of invented from visible text`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let id = UUID()
        try await session.log.append(.userMessage(id: id, text: "Only UI text survives", attachments: []))
        await #expect(throws: (any Error).self) {
            try await session.fork(through: id, as: UUID().uuidString.lowercased())
        }
        await session.close()
    }

    @Test
    func `a removed repeated prompt cannot steal a later prompts context`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: UUID().uuidString)
        let removed = UUID()
        let retained = UUID()
        let user = UserMessage(text: "Repeat")
        var oldAnchor = anchor(user)
        oldAnchor.timestamp -= 1000
        let anchors = [removed.uuidString.lowercased(): oldAnchor, retained.uuidString.lowercased(): anchor(user)]
        try await log.append(.userMessage(id: removed, text: "Repeat", attachments: []))
        try await log.append(.finished(reason: .completed))
        try await log.append(.userMessage(id: retained, text: "Repeat", attachments: []))
        try await log.writeHistorySnapshot([.user(user)], anchors: anchors, seal: true)
        #expect(try await log.readForkContext(removed) == nil)
        #expect(try await log.readForkContext(retained) != nil)
        await log.close()
    }

    @Test
    func `a retained legacy tail is not its original precompaction context`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: UUID().uuidString)
        let id = UUID()
        let user = UserMessage(text: "This survived")
        let recap = UserMessage(text: "An earlier prefix has been summarized", source: .compaction)
        try await log.append(.userMessage(id: id, text: "This survived", attachments: []))
        try await log.append(.finished(reason: .completed))
        try await log.writeHistorySnapshot([.user(recap), .user(user)], anchors: [id.uuidString.lowercased(): anchor(user)], seal: true)
        #expect(try await log.readForkContext(id) == nil)
        await log.close()
    }

    @Test
    func `unfinished tool calls cannot replace the last resumable boundary`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: UUID().uuidString)
        let id = UUID()
        let user = UserMessage(text: "Read it")
        let messages: [Message] = [.user(user)]
        let anchors = [id.uuidString.lowercased(): anchor(user)]
        try await log.append(.userMessage(id: id, text: "Read it", attachments: []))
        try await log.writeHistorySnapshot(messages, anchors: anchors)
        let before = try #require(try await log.readForkContext(id))
        let incomplete = messages + [.assistant(fauxAssistantMessage(
            blocks: [fauxToolCall(name: "file_read", arguments: ["path": "README.md"], id: "pending")],
            stopReason: .toolUse,
        ))]
        await #expect(throws: (any Error).self) {
            try await log.writeHistorySnapshot(incomplete, anchors: anchors, seal: true)
        }
        let after = try #require(try await log.readForkContext(id))
        #expect(after.messages == before.messages)
        #expect(after.records == before.records)
        await log.close()
    }

    @Test
    func `content addressed objects reject damage and links without overwriting them`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = HistoryObjectStore(directory: home.projectURL.appendingPathComponent("objects"))
        let bytes = Data("original".utf8)
        let name = try store.put(bytes)
        #expect(try store.put(bytes) == name)
        #expect(try store.get(name) == bytes)
        let object = store.directory.appendingPathComponent(name)
        try Data("damaged".utf8).write(to: object)
        #expect(throws: (any Error).self) { try store.get(name) }
        #expect(throws: (any Error).self) { try store.put(bytes) }
        #expect(try Data(contentsOf: object) == Data("damaged".utf8))
        #expect(throws: (any Error).self) { try store.get("../outside") }
        try FileManager.default.removeItem(at: object)
        try FileManager.default.createSymbolicLink(at: object, withDestinationURL: home.projectURL)
        #expect(throws: (any Error).self) { try store.get(name) }
    }
}
