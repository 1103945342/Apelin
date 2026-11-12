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

    @Test(arguments: [false, true])
    func `snapshots after reopening include old replies without waiting for a replay`(archived: Bool) async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let sourceID = UUID().uuidString.lowercased()
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sourceID)
        let first = UUID(), second = UUID()
        let user = UserMessage(text: "First")
        let later = UserMessage(text: "Second")
        let anchors = [first.uuidString.lowercased(): anchor(user), second.uuidString.lowercased(): anchor(later)]
        let initial: [Message] = [.user(user), .assistant(fauxAssistantMessage("Original answer"))]
        try await log.append(.userMessage(id: first, text: "First", attachments: []))
        try await log.append(.textDelta("Original answer"))
        try await log.append(.messageFinished(text: "Original answer"))
        try await log.append(.finished(reason: .completed))
        if archived { try await log.writeHistorySnapshot(initial, anchors: anchors, seal: true) }
        let original = try await log.records(afterSeq: 0)
        await log.close()

        let reopened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sourceID)
        let opening = await reopened.decodes
        #expect(opening == 2, "opening still reads only the user message and last line")
        // No attach/replay has filled any cache. Include a newly appended
        // turn and a pending delta, neither dropping nor duplicating either.
        try await reopened.append(.userMessage(id: second, text: "Second", attachments: []))
        try await reopened.append(.textDelta("New reply"))
        let partial = initial + [.user(later), .assistant(fauxAssistantMessage("New reply"))]
        try await reopened.writeHistorySnapshot(partial, anchors: anchors)
        let loaded = await reopened.decodes
        #expect(loaded == opening + original.count + 2)
        let snapshot = try #require(try await reopened.readForkContext(second))
        #expect(Array(snapshot.records.prefix(original.count)) == original)
        #expect(snapshot.messages == partial)
        #expect(snapshot.records.filter { $0.event == .textDelta("New reply") }.count == 1)

        try await reopened.append(.messageFinished(text: "New reply"))
        try await reopened.append(.finished(reason: .completed))
        try await reopened.writeHistorySnapshot(partial, anchors: anchors, seal: true)
        #expect(await reopened.decodes == loaded, "later snapshots reuse the full cache")
        let sealed = try #require(try await reopened.readForkContext(second))
        #expect(sealed.records == (try await reopened.records(afterSeq: 0)))
        let firstSaved = try #require(try await reopened.readForkContext(first))
        #expect(firstSaved.records == original, "legacy seeding also keeps every old reply")
        await reopened.close()
    }

    @Test
    func `a taken source message gets an anchored fork snapshot`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: UUID().uuidString)
        let id = UUID()
        let user = UserMessage(text: "reviewer-session\nReview this")
        try await log.append(.conversationMessageTaken(id: id, text: "Review this", from: "reviewer-session"))
        try await log.append(.messageFinished(text: "Reviewed."))
        try await log.append(.finished(reason: .completed))
        try await log.writeHistorySnapshot(
            [.user(user), .assistant(fauxAssistantMessage("Reviewed."))],
            anchors: [id.uuidString.lowercased(): anchor(user)],
            seal: true,
        )
        let context = try #require(try await log.readForkContext(id))
        #expect(context.messages == [.user(user), .assistant(fauxAssistantMessage("Reviewed."))])
        #expect(context.records.contains { $0.event == .conversationMessageTaken(id: id, text: "Review this", from: "reviewer-session") })
        #expect(context.anchors[id.uuidString.lowercased()]?.digest == ConversationHistory.digest(ConversationHistory.text(of: user)))
        await log.close()
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
    func `a sealed snapshot stores messages only and its records come from the log`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let sessionID = UUID().uuidString.lowercased()
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        let first = UUID()
        let second = UUID()
        let user = UserMessage(text: "First")
        let later = UserMessage(text: "Second")
        let anchors = [first.uuidString.lowercased(): anchor(user), second.uuidString.lowercased(): anchor(later)]
        try await log.append(.userMessage(id: first, text: "First", attachments: []))
        try await log.append(.messageFinished(text: "First reply"))
        try await log.append(.finished(reason: .completed))
        try await log.writeHistorySnapshot([.user(user), .assistant(fauxAssistantMessage("First reply"))], anchors: anchors, seal: true)
        try await log.append(.userMessage(id: second, text: "Second", attachments: []))
        try await log.append(.messageFinished(text: "Second reply"))
        try await log.append(.finished(reason: .completed))
        let both: [Message] = [
            .user(user), .assistant(fauxAssistantMessage("First reply")),
            .user(later), .assistant(fauxAssistantMessage("Second reply")),
        ]
        try await log.writeHistorySnapshot(both, anchors: anchors, seal: true)
        let written = try await log.records(afterSeq: 0)

        // The manifest names its messages; it no longer holds a copy of the
        // turn's UI records, which the append-only log still has.
        let manifest = try Data(contentsOf: log.directory.appendingPathComponent("forks/\(second.uuidString.lowercased()).json"))
        let json = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        #expect(json["version"] as? Int == 2)
        #expect(json["records"] == nil)
        #expect((json["messages"] as? [String])?.isEmpty == false)
        await log.close()

        // Reopening reads the log's opening summary alone; the fork of the
        // turn must still be the whole history, not what the summary saw.
        let reopened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        defer { Task { await reopened.close() } }
        let context = try #require(try await reopened.readForkContext(second))
        #expect(context.records == written)
        #expect(context.messages == both)
    }

    @Test(arguments: [false, true])
    func `fork owns selected and ancestor snapshots after source deletion`(preload: Bool) async throws {
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
            historySource: log.directory, history: try await log.records(afterSeq: 0), through: second,
            savedObjects: preload ? selected.savedObjects : [:],
        )
        if preload {
            let objects = home.dataRoot.sessions.appendingPathComponent(forkID).appendingPathComponent("forks/objects")
            #expect(try FileManager.default.contentsOfDirectory(atPath: objects.path) == [HistoryObjectStore.archiveName])
        }
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
        await session.waitForIdle()
        // Cancellation during an executing tool can still produce its real
        // denied/cancelled result. A complete batch must not be rolled back.
        let stoppedMessages = try await session.log.readTranscript()
        #expect(ForkContext.hasCompleteToolResults(stoppedMessages))
        #expect(stoppedMessages.contains { if case .toolResult = $0 { return true }; return false })
        let stoppedRecords = try await session.log.records(afterSeq: 0)
        #expect(!stoppedRecords.contains { if case .error = $0.event { return true }; return false })
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

    private func pendingBatch() -> [Message] {
        [.assistant(fauxAssistantMessage(blocks: [
            fauxToolCall(name: "file_read", arguments: ["path": "one"], id: "one"),
            fauxToolCall(name: "file_read", arguments: ["path": "two"], id: "two"),
        ], stopReason: .toolUse)), .toolResult(ToolResultMessage(
            toolCallId: "one", toolName: "file_read", content: [.text(TextContent(text: "A real result"))],
        ))]
    }

    @Test
    func `stopping preserves the last whole batch and never invents a result`() throws {
        let complete: [Message] = [.user(UserMessage(text: "Read"))] + pendingBatch() + [
            .toolResult(ToolResultMessage(toolCallId: "two", toolName: "file_read", content: [.text(TextContent(text: "Second real result"))])),
        ]
        #expect(try ForkContext.completePrefix(of: complete) == complete)
        #expect(try ForkContext.completePrefix(of: complete + pendingBatch()) == complete)
        #expect(try ForkContext.completePrefix(of: complete + pendingBatch() + [
            .assistant(fauxAssistantMessage("", stopReason: .aborted)),
        ]) == complete)
        #expect(throws: (any Error).self) {
            try ForkContext.completePrefix(of: pendingBatch() + [.user(UserMessage(text: "Later"))])
        }
        #expect(throws: (any Error).self) {
            try ForkContext.completePrefix(of: pendingBatch() + [.assistant(fauxAssistantMessage("Not cancellation"))])
        }
        #expect(throws: (any Error).self) {
            try ForkContext.completePrefix(of: [.toolResult(ToolResultMessage(toolCallId: "orphan", toolName: "file_read", content: []))])
        }
    }

    @Test
    func `reopening a stopped incomplete transcript seals its saved model and UI boundary`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let sessionID = UUID().uuidString
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        let id = UUID()
        let user = UserMessage(text: "Read")
        let anchors = [id.uuidString.lowercased(): anchor(user)]
        let complete: [Message] = [.user(user), .assistant(fauxAssistantMessage("Already read one batch"))]
        try await log.append(.userMessage(id: id, text: "Read", attachments: []))
        try await log.append(.messageFinished(text: "Already read one batch"))
        try await log.writeHistorySnapshot(complete, anchors: anchors)
        let before = try #require(try await log.readForkContext(id))
        try await log.append(.toolCallStarted(ToolCallRecord(id: "two", name: "file_read", arguments: "{}")))
        try await log.append(.finished(reason: .aborted))
        try await log.writeTranscript(complete + pendingBatch())
        await log.close()

        let reopened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        #expect(try await reopened.readResumableTranscript() == complete)
        #expect(try await reopened.readTranscript() == complete)
        // A later seal or edit must not replace the stopped turn's boundary
        // with partial UI events or with the later run's content.
        try await reopened.writeHistorySnapshot(complete + [.assistant(fauxAssistantMessage("Later"))], anchors: anchors, seal: true)
        let after = try #require(try await reopened.readForkContext(id))
        #expect(after.messages == before.messages)
        #expect(after.records == before.records)
        #expect(after.anchors == before.anchors)
        #expect(try await reopened.readResumableTranscript() == complete)
        await reopened.close()
    }

    @Test(arguments: [FinishReason.completed, .failed])
    func `incomplete history without a recorded stop is not silently repaired`(_ reason: FinishReason) async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: UUID().uuidString)
        let messages: [Message] = [.user(UserMessage(text: "Read"))] + pendingBatch()
        try await log.writeTranscript(messages)
        try await log.append(.finished(reason: reason))
        await #expect(throws: (any Error).self) { try await log.readResumableTranscript() }
        #expect(try await log.readTranscript() == messages)
        await log.close()
    }

    @Test(arguments: ["manifest", "object", "transcript-write"])
    func `stopped recovery surfaces real damage and IO failures`(_ failure: String) async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: UUID().uuidString)
        let id = UUID()
        let user = UserMessage(text: "Read")
        let messages: [Message] = [.user(user)]
        try await log.append(.userMessage(id: id, text: "Read", attachments: []))
        try await log.writeHistorySnapshot(messages, anchors: [id.uuidString.lowercased(): anchor(user)])
        let incomplete = messages + pendingBatch()
        try await log.writeTranscript(incomplete)
        let transcriptURL = log.directory.appendingPathComponent("transcript.json")
        let bytes = try Data(contentsOf: transcriptURL)
        let manifest = log.directory.appendingPathComponent("forks/\(id.uuidString.lowercased()).json")
        if failure == "manifest" {
            try Data("damaged".utf8).write(to: manifest)
        } else if failure == "object" {
            let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            let names = try #require(json["messages"] as? [String])
            let name = try #require(names.first)
            try Data("damaged".utf8).write(to: log.directory.appendingPathComponent("forks/objects/\(name)"))
        } else {
            try FileManager.default.removeItem(at: transcriptURL)
            try FileManager.default.createDirectory(at: transcriptURL, withIntermediateDirectories: false)
        }
        await #expect(throws: (any Error).self) { try await log.recoverInterruptedHistory(incomplete) }
        if failure != "transcript-write" {
            #expect(try Data(contentsOf: transcriptURL) == bytes)
        }
        await log.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `stopping a tool batch allows another prompt editing forking and reopening`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        // Providers can finish a cancelled stream with tool-call blocks
        // already buffered. kwwk retains that assistant message but (correctly)
        // executes none of its calls when its stop reason is aborted.
        faux.setResponses([.message(fauxAssistantMessage(blocks: [
            fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove first", "installation_id": "first"], id: "first"),
            fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove second", "installation_id": "second"], id: "second"),
        ], stopReason: .aborted))])
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let agent = await session.agent
        // Deterministic stop at the retained partial message, before the loop
        // returns. Do not race a timer against a fast faux provider.
        let unsubscribe = agent.subscribe { event, _ in
            if case .messageEnd(.assistant) = event { await session.abort() }
        }
        let id = UUID()
        try await session.prompt("Remove both", messageID: id)
        await session.waitForIdle()
        unsubscribe()
        let boundary = try #require(try await session.log.readForkContext(id))
        #expect(try await session.log.readTranscript() == boundary.messages)
        #expect(!boundary.messages.contains { if case .assistant = $0 { return true }; return false })
        #expect(!boundary.messages.contains { if case .toolResult = $0 { return true }; return false })
        let events = try await session.log.records(afterSeq: 0)
        #expect(!events.contains { if case .error = $0.event { return true }; return false })
        #expect(await session.pendingApprovals.isEmpty)
        // Edits preserve the original stopped snapshot; the provider must
        // receive a valid model conversation on the very next prompt too.
        try await session.edit(id, reply: false, text: "Keep both", expected: nil)
        faux.setResponses([.factory { context, _, _, _ in
            #expect(ForkContext.hasCompleteToolResults(context.messages))
            return fauxAssistantMessage("Continuing safely")
        }])
        try await session.manageQueue(.init(sessionID: session.id, action: .resume))
        try await session.prompt("Continue", messageID: UUID())
        await session.waitForIdle()
        let forkID = UUID().uuidString.lowercased()
        try await session.fork(through: id, as: forkID)
        let fork = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: forkID)
        #expect(try await fork.readTranscript() == boundary.messages)
        await fork.close()
        let transcript = try await session.log.readTranscript()
        #expect(ForkContext.hasCompleteToolResults(transcript))
        await session.close()
        let reopened = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        #expect(try await reopened.log.readTranscript() == transcript)
        await reopened.close()
    }

    @Test
    func `content addressed objects reject damage and links without overwriting them`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = try HistoryObjectStore(directory: home.projectURL.appendingPathComponent("objects"))
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
