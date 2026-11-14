import ApelinCore
import ApelinProtocol
import Foundation

/// The channel domain. The app configures a channel and reads its state; the
/// channel's own worker gets four calls — its binding, its token, one message
/// in and the conversation's reply out — and nothing else on the wire.
///
/// The host decides everything a channel may not do for itself: which
/// conversation it reaches (its own binding, or one the host opens for it as
/// the app), which peers it answers (its allowlist, and an empty one admits
/// nobody), how long a message may be, and which approval mode its
/// conversation opens with. Approving stays the app's: a message that says
/// "1" is a message like any other, and a conversation waiting for an
/// approval only tells the channel that one is waiting.
enum ChannelHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .channelList:
            return await list(request, host: host)
        case .channelConfigure:
            return await configure(request, host: host)
        case .channelStart:
            return await start(request, host: host)
        case .channelStop:
            return await stop(request, host: host)
        case .channelLogout:
            return await logout(request, host: host)
        case .channelLoginCode:
            return await loginCode(request, host: host)
        case .channelAttach:
            return await attach(request, host: host)
        case .channelBinding:
            return await binding(request, host: host)
        case .channelSay:
            return await say(request, host: host)
        case .channelRead:
            return await read(request, host: host)
        default:
            return request.fail(ApelinError.unimplemented(request.operation))
        }
    }

    // MARK: - The app's calls

    private static func list(_ request: HostRequest, host: SessionHost) async -> HostReply {
        await request.serve(ChannelListRequest.self) { list in
            if let id = list.channelID {
                guard let summary = await host.channels.summary(id) else {
                    throw ApelinError(.notFound, "This channel was not configured.")
                }
                return ChannelListResponse(channels: [summary])
            }
            return ChannelListResponse(channels: await host.channels.summaries())
        }
    }

    private static func configure(_ request: HostRequest, host: SessionHost) async -> HostReply {
        await request.serve(ChannelConfigureRequest.self) { configure in
            try await host.channels.configure(configure, app: host.appApprovalMode, host: host)
        }
    }

    private static func start(_ request: HostRequest, host: SessionHost) async -> HostReply {
        await request.serve(ChannelStartRequest.self) { start in
            try await host.channels.start(start.channelID, host: host)
        }
    }

    private static func stop(_ request: HostRequest, host: SessionHost) async -> HostReply {
        await request.serve(ChannelStopRequest.self) { stop in
            guard let summary = await host.channels.stop(
                stop.channelID,
                reason: "The channel was turned off.",
                host: host
            ) else {
                throw ApelinError(.notFound, "This channel was not configured.")
            }
            return summary
        }
    }

    private static func logout(_ request: HostRequest, host: SessionHost) async -> HostReply {
        await request.serve(ChannelLogoutRequest.self) { logout in
            try await host.channels.logout(logout.channelID, host: host)
        }
    }

    /// A channel's task, and only a channel's: the app reads login codes and
    /// state from it, never another task through this operation.
    private static func attach(_ request: HostRequest, host: SessionHost) async -> HostReply {
        do {
            let attach = try request.decode(ChannelAttachRequest.self)
            guard let record = await host.registry.record(attach.taskID), record.kind == .channel else {
                throw ApelinError(.notFound, "This is not a channel's task.")
            }
        } catch {
            return request.fail(error)
        }
        return await host.attach(request, ChannelAttachRequest.self)
    }

    // MARK: - The worker's calls

    private static func binding(_ request: HostRequest, host: SessionHost) async -> HostReply {
        await request.serve(ChannelBindingRequest.self) { _ in
            try await host.channels.binding(instance: try instance(request), host: host)
        }
    }

    /// The number WeChat showed while signing in goes to the worker that is
    /// waiting for it. Nothing else does: the chat itself never carries it.
    private static func loginCode(_ request: HostRequest, host: SessionHost) async -> HostReply {
        let decoded: ChannelLoginCodeRequest
        do {
            decoded = try request.decode(ChannelLoginCodeRequest.self)
            guard ChannelRules.isValidChannelID(decoded.channelID) else {
                throw ApelinError(.badRequest, "a channel ID is letters, digits, '-' and '_' only")
            }
            let trimmed = decoded.code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 16 else {
                throw ApelinError(.badRequest, "That does not look like the number WeChat showed.")
            }
            guard let worker = await host.workers.existing(.channel, instance: decoded.channelID),
                  !worker.channel.isClosed
            else {
                throw ApelinError(.notFound, "This channel is not signing in right now.")
            }
        } catch {
            return request.fail(error)
        }
        return await host.forward(request, to: .channel, instance: decoded.channelID)
    }

    /// One inbound message: checked against the allowlist and the size, taken
    /// once by its ID, then delivered to the channel's conversation — which
    /// the host opens, as the app, when there is none yet.
    private static func say(_ request: HostRequest, host: SessionHost) async -> HostReply {
        do {
            let id = try instance(request)
            let say = try request.decode(ChannelSayRequest.self)
            guard say.channelID == id else {
                throw ApelinError(.denied, "a channel process reaches only its own channel")
            }
            guard let record = await host.channels.record(id), record.enabled else {
                throw ApelinError(.denied, "This channel is not running.")
            }
            if let problem = ChannelRules.messageProblem(say.text, allowlist: record.allowlist, peer: say.from) {
                switch problem {
                case .peerNotAllowed:
                    throw ApelinError(.denied, "This person is not on the channel's allowlist.")
                case .messageEmpty:
                    throw ApelinError(.badRequest, "An empty message is not sent.")
                case .messageTooLong:
                    throw ApelinError(.badRequest, "This message is longer than a channel message may be.")
                default:
                    throw ApelinError(.denied, "This channel is not configured to answer anyone.")
                }
            }

            let sessionID = try await conversation(for: id, record: record, host: host, asked: say.sessionID)
            if !(try await host.channels.acceptInbox(channel: id, messageID: say.clientMessageID)) {
                return ChannelSayResponse(accepted: true, duplicate: true, taskID: nil, sessionID: sessionID)
            }
            guard await AgentSessionTable.shared.entry(sessionID) != nil,
                  let worker = await host.workers.existing(.agent, instance: sessionID),
                  !worker.channel.isClosed
            else {
                await host.channels.sessionGone(id, host: host)
                throw ApelinError(.notFound, "The conversation this channel drove is gone.")
            }
            // Only these three fields: a channel never sets a mode, a run
            // mode, a provider or a model, and never speaks as an agent.
            let prompt = AgentPromptRequest(sessionID: sessionID, text: say.text, delivery: .queue)
            var wire = try WireRequest(prompt)
            wire.requestID = request.requestID
            let (reply, _) = try await worker.call(wire, descriptors: [])
            if case let .failure(error) = reply.result {
                throw error
            }
            return ChannelSayResponse(accepted: true, duplicate: false, taskID: nil, sessionID: sessionID)
        } catch {
            return request.fail(error)
        }
    }

    private static func read(_ request: HostRequest, host: SessionHost) async -> HostReply {
        await request.serve(ChannelReadRequest.self) { read in
            let id = try instance(request)
            guard read.channelID == id else {
                throw ApelinError(.denied, "a channel process reaches only its own channel")
            }
            guard let record = await host.channels.record(id), record.enabled else {
                throw ApelinError(.denied, "This channel is not running.")
            }
            guard let bound = record.sessionID, bound == read.sessionID else {
                throw ApelinError(.denied, "This channel reads only the conversation it drives.")
            }
            guard let entry = await AgentSessionTable.shared.entry(bound) else {
                await host.channels.sessionGone(id, host: host)
                throw ApelinError(.notFound, "The conversation this channel drove is gone.")
            }
            let wait = max(0, min(read.waitMilliseconds, 20_000))
            let batch: TaskEventBatch
            do {
                batch = try await host.registry.attach(
                    entry.task.taskID,
                    as: .agentAttach,
                    afterSeq: read.afterSeq,
                    waitMilliseconds: wait
                )
            } catch let error as ApelinError where error.code == .notFound {
                throw ApelinError(.notFound, "The conversation this channel drove is gone.")
            }
            return ChannelReadMapping.map(
                batch,
                afterSeq: read.afterSeq,
                budget: ChannelRules.readBudget(read.maxBytes)
            )
        }
    }

    // MARK: - Private

    private static func instance(_ request: HostRequest) throws -> String {
        guard case let .worker(.channel, key) = request.caller, let key else {
            throw ApelinError(.denied, "only a channel's own worker may call this")
        }
        return key
    }

    /// The conversation this channel drives. The one it was bound to when
    /// there is one, else one the host opens for it as the app — with the
    /// channel's approval mode, never looser than the app's own.
    private static func conversation(
        for id: String,
        record: ChannelRecord,
        host: SessionHost,
        asked: String?
    ) async throws -> String {
        if let bound = record.sessionID {
            if let asked, asked != bound {
                throw ApelinError(.denied, "This channel reads only the conversation it drives.")
            }
            guard await AgentSessionTable.shared.entry(bound) != nil else {
                await host.channels.sessionGone(id, host: host)
                throw ApelinError(.notFound, "The conversation this channel drove is gone.")
            }
            return bound
        }
        let mode: ApprovalMode
        do {
            let binding = try await host.channels.binding(instance: id, host: host)
            mode = binding.approvalMode
        }
        let open = AgentOpenRequest(projectID: record.projectID, approvalMode: mode)
        let request = HostRequest(
            request: try WireRequest(open),
            descriptors: [],
            caller: .app
        )
        let (reply, _) = await AgentHandler.openForChannel(request, host: host)
        guard case let .success(body) = reply.result,
              let response = try? JSONCoding.decode(AgentOpenResponse.self, from: body)
        else {
            if case let .failure(error) = reply.result { throw error }
            throw ApelinError(.unavailable, "The conversation could not be opened.")
        }
        await host.channels.recordSession(response.sessionID, channel: id, taskID: response.task.taskID)
        return response.sessionID
    }
}

/// What a channel is told about the conversation: the assistant's messages,
/// an error, and whether an approval is waiting. Tool calls, paths, command
/// lines, attachments and the approval's own detail stay in the app.
enum ChannelReadMapping {
    static func map(_ batch: TaskEventBatch, afterSeq: EventSeq, budget: Int) -> ChannelReadResponse {
        var messages: [ChannelMessage] = []
        var pending = false
        var bytes = 0
        var consumed = afterSeq
        var cut = false

        for event in batch.events where event.seq > afterSeq {
            switch event.kind {
            case "message":
                let text = event.payload?["text"]?.stringValue ?? ""
                guard !text.isEmpty else {
                    consumed = event.seq
                    continue
                }
                if bytes + text.utf8.count > budget {
                    cut = true
                    break
                }
                bytes += text.utf8.count
                messages.append(ChannelMessage(seq: event.seq, role: .assistant, text: text))
                consumed = event.seq
            case "error":
                let text = event.payload?["message"]?.stringValue ?? ""
                guard !text.isEmpty else {
                    consumed = event.seq
                    continue
                }
                if bytes + text.utf8.count > budget {
                    cut = true
                    break
                }
                bytes += text.utf8.count
                messages.append(ChannelMessage(seq: event.seq, role: .error, text: text))
                consumed = event.seq
            case "approvalRequested":
                pending = true
                consumed = event.seq
            case TaskEvent.stateKind:
                consumed = event.seq
            default:
                consumed = event.seq
            }
            if cut { break }
        }

        let state: ChannelConversationState
        if batch.state == .waitingForApproval || pending {
            state = .waitingForApproval
        } else if batch.state.isTerminal {
            state = .ended
        } else {
            state = .running
        }
        return ChannelReadResponse(
            messages: messages,
            state: state,
            pendingApproval: pending || batch.state == .waitingForApproval,
            nextSeq: consumed
        )
    }
}
