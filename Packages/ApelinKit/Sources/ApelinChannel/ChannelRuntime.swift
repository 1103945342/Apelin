import ApelinCore
import ApelinProtocol
import Foundation

/// The channel's own loop, run inside `apelin-channel` as mobile: get the
/// binding, get the token, sign in if needed, then carry the platform's
/// messages into the one conversation the host allows and the conversation's
/// answers back out.
///
/// Everything the loop decides is a request to the host; nothing here reads
/// another conversation, opens one, approves anything or changes a mode. A
/// host that refuses is answered with one short line to the reader and the
/// loop carries on.
public actor ChannelRuntime {
    private var task: Task<Void, Never>?
    private var platform: (any ChannelPlatform)?
    private var stopping = false
    private var verificationCode: String?

    public init() {}

    /// Called once, right after the host accepted the assignment.
    public nonisolated func start(_ context: WorkerContext) {
        Task { await self.begin(context) }
    }

    /// Called when the host closes the channel, or a task is cancelled.
    public nonisolated func stop() {
        Task { await self.halt() }
    }

    /// From the app, while WeChat waits for the number it showed on the
    /// phone. Kept until the next sign-in poll takes it.
    public func submitVerificationCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16 else { return }
        verificationCode = trimmed
    }

    private func takeVerificationCode() -> String? {
        defer { verificationCode = nil }
        return verificationCode
    }

    private func begin(_ context: WorkerContext) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.loop(context)
        }
    }

    private func halt() {
        stopping = true
        task?.cancel()
        task = nil
        if let platform {
            Task { await platform.close() }
        }
        platform = nil
    }

    private func loop(_ context: WorkerContext) async {
        var failures = 0
        while !stopping, !Task.isCancelled {
            do {
                try await once(context)
                failures = 0
            } catch is ChannelStoodDown {
                // Said on the task as `paused`; the host has stood the
                // channel down, so nothing is retried here.
                return
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                // Never the failure's own description: it can carry the
                // address the client was talking to.
                NSLog("apelin-channel: connection failed (%d)", failures)
            }
            guard !stopping, !Task.isCancelled else { return }
            let step = min(60, 1 << min(failures, 6))
            try? await Task.sleep(nanoseconds: UInt64(step) * 1_000_000_000)
        }
    }

    /// One connection: binding, token, login, then the update stream until it
    /// ends. Throwing restarts the whole thing with a delay, except a
    /// `ChannelStoodDown`, which is reported once and ends the loop.
    private func once(_ context: WorkerContext) async throws {
        let binding = try await context.host.channelBinding()
        do {
            try await serve(context, binding: binding)
        } catch let standdown as ChannelStoodDown {
            emit(context, binding.taskID, [
                "state": .string(ChannelState.paused.rawValue),
                "error": .object([
                    "code": .string(standdown.code.rawValue),
                    "message": .string(standdown.message),
                ]),
            ])
            throw standdown
        }
    }

    private func serve(_ context: WorkerContext, binding: ChannelWorkerBinding) async throws {
        let taskID = binding.taskID
        emit(context, taskID, ChannelStatePayload.starting)

        // iLink signs in with a code the reader scans; there is no token to
        // configure, and none passes through the host.
        let platform = IlinkPlatform(channelID: binding.channelID, dataFolder: context.dataFolder)
        self.platform = platform

        var phase = try await platform.connect()
        if phase != .confirmed {
            let prompt = try await platform.loginPrompt()
            emit(context, taskID, prompt.payload, kind: "channelLogin")
            emit(context, taskID, ChannelStatePayload.awaitingLogin)
            while phase != .confirmed {
                if stopping || Task.isCancelled { return }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let update = try await platform.loginStatus(verifyCode: takeVerificationCode())
                if let prompt = update.prompt {
                    emit(context, taskID, prompt.payload, kind: "channelLogin")
                }
                if update.needsVerification {
                    // The app asks the reader for the number WeChat showed;
                    // the chat itself never carries it.
                    emit(context, taskID, [
                        "kind": .string("code"),
                        "value": .string(""),
                        "retry": .bool(update.verificationRetry),
                    ], kind: "channelLogin")
                }
                phase = update.phase
                if phase == .failed {
                    throw ChannelFailure("The sign-in did not finish.")
                }
            }
        }
        emit(context, taskID, ChannelStatePayload.online)

        var sessionID = binding.sessionID
        let stream = await platform.updates()
        for try await update in stream {
            if stopping || Task.isCancelled { return }
            switch update {
            case let .inbound(peer, messageID, text):
                sessionID = await deliver(
                    text,
                    peer: peer,
                    messageID: messageID,
                    context: context,
                    binding: binding,
                    sessionID: sessionID,
                    platform: platform
                )
            }
        }
        throw ChannelFailure("The connection closed.")
    }

    /// One message in: the host checks the allowlist, the size and the
    /// binding, takes the ID once, and delivers it to the conversation —
    /// opening one for the channel when it has none.
    private func deliver(
        _ text: String,
        peer: String,
        messageID: String,
        context: WorkerContext,
        binding: ChannelWorkerBinding,
        sessionID: String?,
        platform: any ChannelPlatform
    ) async -> String? {
        let say = ChannelSayRequest(
            channelID: binding.channelID,
            from: peer,
            clientMessageID: messageID,
            sessionID: sessionID,
            text: text
        )
        do {
            let response = try await context.host.channelSay(say)
            guard !response.duplicate, let target = response.sessionID else {
                return response.sessionID ?? sessionID
            }
            await relay(context: context, binding: binding, sessionID: target, peer: peer, platform: platform)
            return target
        } catch let error as ApelinError {
            let line = error.code == .notFound ? ChannelText.conversationGone : ChannelText.channelDown
            try? await platform.send(line, to: peer)
            return sessionID
        } catch {
            try? await platform.send(ChannelText.channelDown, to: peer)
            return sessionID
        }
    }

    /// What the conversation answered, until it is idle, ended or waiting for
    /// the reader's approval. The cursor is the worker's own, on disk, so a
    /// reconnect does not send the same answers twice.
    private func relay(
        context: WorkerContext,
        binding: ChannelWorkerBinding,
        sessionID: String,
        peer: String,
        platform: any ChannelPlatform
    ) async {
        var cursor = ChannelCursor.load(channelID: binding.channelID, dataFolder: context.dataFolder)
        var after = cursor.seq(for: sessionID)
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline, !stopping, !Task.isCancelled {
            let read: ChannelReadResponse
            do {
                read = try await context.host.channelRead(ChannelReadRequest(
                    channelID: binding.channelID,
                    sessionID: sessionID,
                    afterSeq: after,
                    waitMilliseconds: 15_000,
                    maxBytes: 8 * 1024
                ))
            } catch let error as ApelinError {
                let line = error.code == .notFound ? ChannelText.conversationGone : ChannelText.channelDown
                try? await platform.send(line, to: peer)
                return
            } catch {
                return
            }
            after = read.nextSeq
            cursor.set(after, for: sessionID)
            cursor.save(channelID: binding.channelID, dataFolder: context.dataFolder)
            for message in read.messages {
                try? await platform.send(message.text, to: peer)
            }
            if read.pendingApproval || read.state == .waitingForApproval {
                try? await platform.send(ChannelText.approvalWaiting, to: peer)
                return
            }
            switch read.state {
            case .idle, .ended, .unavailable:
                return
            case .running, .waitingForApproval:
                continue
            }
        }
    }

    private func emit(_ context: WorkerContext, _ taskID: TaskID, _ payload: [String: JSONValue], kind: String = "channelState") {
        context.emit(taskID, kind, .object(payload))
    }
}

enum ChannelStatePayload {
    static let starting: [String: JSONValue] = ["state": .string(ChannelState.starting.rawValue)]
    static let awaitingLogin: [String: JSONValue] = ["state": .string(ChannelState.awaitingLogin.rawValue)]
    static let online: [String: JSONValue] = ["state": .string(ChannelState.online.rawValue)]
}

/// Where the channel got to in each conversation it read, so a restart does
/// not replay answers it already sent.
struct ChannelCursor: Codable {
    var sessions: [String: UInt64] = [:]

    static func url(channelID: String, dataFolder: DataFolder) -> URL {
        dataFolder.weChatChannel
            .appendingPathComponent(channelID, isDirectory: true)
            .appendingPathComponent("cursor.json")
    }

    static func load(channelID: String, dataFolder: DataFolder) -> ChannelCursor {
        let url = url(channelID: channelID, dataFolder: dataFolder)
        guard let data = try? Data(contentsOf: url),
              let cursor = try? JSONCoding.decode(ChannelCursor.self, from: data)
        else { return ChannelCursor() }
        return cursor
    }

    func seq(for sessionID: String) -> EventSeq {
        EventSeq(sessions[sessionID] ?? 0)
    }

    mutating func set(_ seq: EventSeq, for sessionID: String) {
        sessions[sessionID] = seq.rawValue
    }

    func save(channelID: String, dataFolder: DataFolder) {
        let url = Self.url(channelID: channelID, dataFolder: dataFolder)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONCoding.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
