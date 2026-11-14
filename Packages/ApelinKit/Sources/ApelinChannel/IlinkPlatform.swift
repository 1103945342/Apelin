import ApelinCore
import ApelinProtocol
import ApelinWeChat
import Foundation

/// The one place the channel worker touches iLink. Everything else in
/// `ApelinChannel` speaks `ChannelPlatform`.
///
/// The session, its cursor and its `context_token`s stay in
/// `<data>/WeChatChannel/<channelID>/session.json`, written by the platform's
/// own store at mode 0600. The token the app may have configured is not used
/// to sign in — iLink signs in with a code the reader scans, and hands the
/// credential back — so an empty credential is normal.
actor IlinkPlatform: ChannelPlatform {
    private let client: IlinkClient
    private var code: IlinkLoginQRCode?

    init(channelID: String, dataFolder: DataFolder) {
        let directory = dataFolder.weChatChannel.appendingPathComponent(channelID, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        client = IlinkClient(
            configuration: IlinkConfiguration(),
            transport: URLSessionIlinkTransport(),
            store: IlinkFileSessionStore(fileURL: directory.appendingPathComponent("session.json"))
        )
    }

    func connect() async throws -> ChannelLoginPhase {
        do {
            if try await client.restoreSession() {
                try await client.startUpdates()
                return .confirmed
            }
        } catch let failure as IlinkFailure {
            // A session file that does not read is not "nobody signed in":
            // signing in again would replace a credential the reader may
            // still hold. The channel stands down and the user decides.
            if case .sessionUnreadable = failure {
                throw ChannelStoodDown(
                    .configurationUnreadable,
                    "The saved WeChat sign-in could not be read. Sign in again from Settings ▸ Plugins."
                )
            }
            throw failure
        }
        return .pending
    }

    func loginPrompt() async throws -> ChannelLoginPrompt {
        let issued = try await client.beginLogin()
        code = issued
        // The code is drawn by the app: it carries the sign-in secret and
        // stays out of every log.
        return .qrURL(issued.content, expiresAt: issued.expiresAt)
    }

    func loginStatus(verifyCode: String?) async throws -> ChannelLoginUpdate {
        guard let code else {
            return ChannelLoginUpdate(phase: .pending)
        }
        switch try await client.pollLogin(code, verifyCode: verifyCode) {
        case .pending:
            return ChannelLoginUpdate(phase: .pending)
        case .scanned:
            return ChannelLoginUpdate(phase: .scanned)
        case .needsVerification(let retry):
            // WeChat wants the number shown on the phone; the app asks the
            // reader for it and sends it back through `channelLoginCode`.
            return ChannelLoginUpdate(phase: .pending, needsVerification: true, verificationRetry: retry)
        case .redirecting:
            return ChannelLoginUpdate(phase: .redirect)
        case .confirmed:
            return ChannelLoginUpdate(phase: .confirmed)
        case .expired(let replacement):
            self.code = replacement
            return ChannelLoginUpdate(
                phase: .pending,
                prompt: .qrURL(replacement.content, expiresAt: replacement.expiresAt)
            )
        case .ended:
            return ChannelLoginUpdate(phase: .failed)
        }
    }

    func cancelLogin() async {
        await client.cancelLogin()
        code = nil
    }

    func updates() async -> AsyncThrowingStream<ChannelUpdate, any Error> {
        let source = await client.updates()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in source {
                        guard let text = message.text, !text.isEmpty else { continue }
                        continuation.yield(ChannelUpdate.inbound(
                            peer: message.peer.id,
                            messageID: message.id.raw,
                            text: text
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func send(_ text: String, to peer: String) async throws {
        _ = try await client.send(text: text, to: IlinkPeer(id: peer))
    }

    func discardSession() async {
        try? await client.discardSession()
    }

    func close() async {
        await client.cancelLogin()
        await client.stop()
        code = nil
    }
}
