import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI

/// The reader's changes to the conversation (`AgentHistory`): a message
/// taken back, a message's or a reply's text edited, a reply deleted, a
/// fork written. Each one changes the conversation the model reads, writes
/// it to `transcript.json`, and records an event the app shows it by.
/// Edits require an idle session; forks read an immutable saved boundary.
extension AgentSession {
    // MARK: Anchors

    /// Where message `id` is: the text the model reads for it, what the
    /// reader typed in it and what follows that.
    func saveAnchor(_ id: UUID, modelText: String, typed: String, suffix: String, timestamp: Int64) {
        anchors[id.uuidString.lowercased()] = HistoryAnchor(
            digest: ConversationHistory.digest(modelText),
            typed: typed,
            suffixBytes: suffix.utf8.count,
            timestamp: timestamp,
        )
    }

    /// Writes the anchors. One that fails is written with the next change;
    /// until then a message it named is found as an older one is.
    func persistAnchors() async {
        let anchors = anchors
        try? await log.writeAnchors(anchors)
    }

    // MARK: Changes

    /// Stops the run and waits for it, then with `truncate` takes message
    /// `id` and everything after it out of the conversation.
    public func rewind(to id: UUID, truncate: Bool) async throws {
        if runTask != nil || compaction != nil {
            await abort()
            await waitForIdle()
        }
        guard truncate else { return }
        try requireIdle()
        let messages = agent.state.messages
        guard let index = try await located(id, in: messages)?.index else {
            throw Self.notInHistory
        }
        try requireIdle()
        try await replaceHistory(Array(messages[..<index]))
        anchors[id.uuidString.lowercased()] = nil
        if index == 0 {
            // the next message is the conversation's first again
            projectContextGiven = false
        }
        // The messages taken back carried what the model was told since the
        // system prompt; the next run takes the prompt afresh instead.
        snapshotStale = true
        await persistAnchors()
        await record(.historyRewound(id: id))
        await recordContextUsage()
    }

    /// Gives message `id`, or with `reply` the reply that ends its turn,
    /// the text `text`. `expected` is the reply's text as the app shows it.
    public func edit(_ id: UUID, reply: Bool, text: String, expected: String?) async throws {
        guard text.count <= AgentHistoryRules.maximumEditLength else {
            throw ApelinError(.badRequest, "The text is longer than \(AgentHistoryRules.maximumEditLength) characters.")
        }
        try requireIdle()
        var messages = agent.state.messages
        guard let found = try await located(id, in: messages) else { throw Self.notInHistory }
        let index = found.index
        let anchor = found.anchor
        if reply {
            let end = ConversationHistory.nextReaderMessage(after: index, in: messages)
            guard let replyIndex = ConversationHistory.lastReply(in: messages, range: (index + 1) ..< end),
                  case let .assistant(assistant) = messages[replyIndex],
                  expected == nil || ConversationHistory.text(of: assistant) == expected
            else { throw Self.replyNotFound }
            messages[replyIndex] = .assistant(ConversationHistory.replacingText(of: assistant, with: text))
            ConversationHistory.forgettingResponses(from: replyIndex, in: &messages)
            try requireIdle()
            try await replaceHistory(messages)
            await record(.replyEdited(id: id, text: text))
        } else {
            guard case let .user(user) = messages[index],
                  let edited = ConversationHistory.replacingTyped(
                      in: user,
                      typed: anchor.typed,
                      suffixBytes: anchor.suffixBytes,
                      with: text,
                  )
            else { throw Self.notInHistory }
            messages[index] = .user(edited)
            ConversationHistory.forgettingResponses(from: index, in: &messages)
            try requireIdle()
            try await replaceHistory(messages)
            anchors[id.uuidString.lowercased()] = HistoryAnchor(
                digest: ConversationHistory.digest(ConversationHistory.text(of: edited)),
                typed: text,
                suffixBytes: anchor.suffixBytes,
                timestamp: anchor.timestamp,
            )
            await persistAnchors()
            await record(.messageEdited(id: id, text: text))
        }
    }

    /// Deletes the reply that ends message `id`'s turn: its text, and the
    /// whole message unless it also made a call.
    public func deleteReply(_ id: UUID, expected: String?) async throws {
        try requireIdle()
        var messages = agent.state.messages
        guard let index = try await located(id, in: messages)?.index else { throw Self.notInHistory }
        let end = ConversationHistory.nextReaderMessage(after: index, in: messages)
        guard let replyIndex = ConversationHistory.lastReply(in: messages, range: (index + 1) ..< end),
              case let .assistant(assistant) = messages[replyIndex],
              expected == nil || ConversationHistory.text(of: assistant) == expected
        else { throw Self.replyNotFound }
        if let kept = ConversationHistory.removingText(from: assistant) {
            messages[replyIndex] = .assistant(kept)
        } else {
            messages.remove(at: replyIndex)
        }
        ConversationHistory.forgettingResponses(from: replyIndex, in: &messages)
        try requireIdle()
        try await replaceHistory(messages)
        await record(.replyDeleted(id: id))
        await recordContextUsage()
    }

    /// Writes the historical model/UI snapshot, not today's edited prefix.
    /// Sealed snapshots can be read while the source is running or compacting.
    public func fork(through id: UUID, as newSessionID: String) async throws {
        guard SessionEventLog.isValidSessionID(newSessionID), newSessionID.lowercased() != self.id.lowercased() else {
            throw ApelinError(.badRequest, "a fork's session ID must be a new UUID")
        }
        var context = try await log.readForkContext(id)
        if context == nil {
            // Seed legacy sessions only from their surviving model messages;
            // a UI log is not a lossless substitute for a lost transcript.
            try requireIdle()
            try await log.writeHistorySnapshot(agent.state.messages, anchors: anchors, seal: true)
            context = try await log.readForkContext(id)
        }
        guard let context else {
            throw ApelinError(.conflict, "No saved model context exists for this message. Older versions did not preserve context removed by compaction or rewind; queued messages have no model context until taken.")
        }
        guard var metadata = try await log.readMetadata() else {
            throw ApelinError(.notFound, "This chat's record could not be read.")
        }
        metadata.id = newSessionID.lowercased()
        metadata.created = Date()
        do {
            try SessionEventLog.writeFork(
                sessionsRoot: configuration.dataRoot.sessions,
                metadata: metadata,
                records: context.records,
                transcript: context.messages,
                anchors: context.anchors,
                historySource: log.directory,
                through: id,
                savedObjects: context.savedObjects,
            )
        } catch let error as SessionStoreError {
            throw ApelinError(.conflict, error.localizedDescription)
        }
    }

    /// Save only a complete model-message boundary. A call without its
    /// result is not a resumable context; the last good snapshot stays.
    func captureForkBoundary() async {
        // kwwk's processEvent appends messageEnd to state before awaiting
        // listeners. Read that exact state; never synthesize a message here.
        let messages = agent.state.messages
        guard ForkContext.hasCompleteToolResults(messages) else { return }
        do {
            try await log.writeHistorySnapshot(messages, anchors: anchors)
        } catch {
            await record(.error(message: "Unable to preserve this conversation boundary for future forks: \(error.localizedDescription)"))
        }
    }

    // MARK: Helpers

    private static var notInHistory: ApelinError {
        ApelinError(
            .conflict,
            "This message is no longer in the conversation the model reads: the chat was compacted since, or it was taken back.",
        )
    }

    private static var replyNotFound: ApelinError {
        ApelinError(.conflict, "This reply changed since it was shown. Try again.")
    }

    /// Refuses while a run or a compaction goes.
    private func requireIdle() throws {
        guard runTask == nil, compaction == nil else {
            throw ApelinError(.conflict, "Wait for the current reply to finish, then try again.")
        }
    }

    /// The conversation becomes `messages`, written first; one that cannot
    /// be written leaves it as it was.
    private func replaceHistory(_ messages: [Message]) async throws {
        let before = agent.state.messages
        // Refuse a destructive edit when the original context cannot be
        // preserved. A later fork reads this version, not the edited one.
        try await log.writeHistorySnapshot(before, anchors: anchors, seal: true)
        try requireIdle()
        agent.state.messages = messages
        do {
            try await log.writeTranscript(messages)
        } catch {
            agent.state.messages = before
            throw ApelinError(.unavailable, "Unable to save the conversation history: \(error.localizedDescription)")
        }
    }

    /// Where message `id` is in `messages`, with its anchor: from the anchor
    /// kept, or for a message sent before anchors were, from its event,
    /// counting the same text sent after it. Nil once it is not there.
    private func located(_ id: UUID, in messages: [Message]) async throws -> (index: Int, anchor: HistoryAnchor)? {
        let key = id.uuidString.lowercased()
        if let anchor = anchors[key] {
            return ConversationHistory.index(of: anchor, in: messages).map { (index: $0, anchor: anchor) }
        }
        let records = try await log.records(afterSeq: 0)
        var found: (text: String, attachments: [AgentAttachment], position: Int)?
        for (position, record) in records.enumerated() {
            switch record.event {
            case let .userMessage(messageID, text, attachments) where messageID == id:
                found = (text, attachments, position)
            case let .conversationMessageTaken(messageID, text, _) where messageID == id:
                found = (text, [], position)
            default:
                break
            }
        }
        guard let found else { return nil }
        let later = records[(found.position + 1)...].count {
            switch $0.event {
            case let .userMessage(_, text, attachments):
                return text == found.text && attachments == found.attachments
            case let .conversationMessageTaken(_, text, _):
                return text == found.text && found.attachments.isEmpty
            default:
                return false
            }
        }
        let suffix = ConversationHistory.attachmentSuffix(found.attachments.map { (name: $0.name, path: $0.path) })
        guard let index = ConversationHistory.index(typed: found.text, suffix: suffix, later: later, in: messages),
              case let .user(user) = messages[index]
        else { return nil }
        let anchor = HistoryAnchor(
            digest: ConversationHistory.digest(ConversationHistory.text(of: user)),
            typed: found.text,
            suffixBytes: suffix.utf8.count,
            timestamp: user.timestamp,
        )
        anchors[key] = anchor
        return (index, anchor)
    }

    /// Historical UI events through this turn's first finish or the next
    /// prompt, without untaken queued messages or later maintenance. A
    /// partial boundary gets an aborted finish. Numbered from 1; the app
    /// replays this new log rather than cutting its current UI a second time.
    static func forkRecords(_ records: [SessionEventRecord], through id: UUID) -> [SessionEventRecord]? {
        guard let start = records.firstIndex(where: {
            switch $0.event {
            case let .userMessage(messageID, _, _), let .conversationMessageTaken(messageID, _, _):
                return messageID == id
            default:
                return false
            }
        }) else { return nil }
        let startsTurn: (SessionEventRecord) -> Bool = { record in
            switch record.event {
            case .userMessage, .promptSubmitted, .conversationMessageTaken:
                return true
            default:
                return false
            }
        }
        let next = records[(start + 1)...].firstIndex(where: startsTurn) ?? records.count
        // Compaction, edits and other later maintenance are not part of
        // the historical turn, even when no new prompt followed it yet.
        let finished = records[(start + 1) ..< next].firstIndex {
            if case .finished = $0.event { return true }
            return false
        }
        let end = finished.map { $0 + 1 } ?? next
        var taken: Set<UUID> = []
        for record in records[..<end] {
            switch record.event {
            case let .userMessage(messageID, _, _), let .conversationMessageTaken(messageID, _, _):
                taken.insert(messageID)
            default:
                break
            }
        }
        var kept = records[..<end].filter {
            switch $0.event {
            case let .userMessageQueued(messageID, _, _), let .conversationMessageQueued(messageID, _, _):
                return taken.contains(messageID)
            case .conversationMessagesDropped:
                return false // their untaken queue entries are excluded too
            default:
                return true
            }
        }
        let lastTurn = kept.lastIndex(where: startsTurn) ?? 0
        let ended = kept[lastTurn...].contains {
            if case .finished = $0.event { return true }
            return false
        }
        if !ended {
            kept.append(SessionEventRecord(seq: 0, date: kept.last?.date ?? Date(), event: .finished(reason: .aborted)))
        }
        return kept.enumerated().map { offset, record in
            SessionEventRecord(seq: UInt64(offset + 1), date: record.date, event: record.event)
        }
    }
}
