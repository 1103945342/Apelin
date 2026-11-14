import ApelinCore
import ApelinProtocol
import Foundation

/// apelin-channel: one WeChat ClawBot channel per process, spawned as mobile
/// by the session host with the channel's ID as its instance.
///
/// The worker opens every connection, and the host only routes: this process
/// asks for its binding, signs in with a code the reader scans, carries the
/// platform's messages into the conversation the host allows, and sends that
/// conversation's answers back. It never opens a conversation, never approves
/// anything and never reaches a second channel.
public enum ChannelWorker {
    public static func main() -> Never {
        let runtime = ChannelRuntime()
        WorkerMain.run(
            role: .channel,
            onCancel: { _, _ in runtime.stop() },
            onClose: { runtime.stop() },
            onReady: { context in runtime.start(context) },
            handler: { request, _ in
                await answer(request, runtime: runtime)
            }
        )
    }

    /// The only request the host sends a channel: the number WeChat showed
    /// while signing in. Everything else is the worker asking.
    static func answer(_ request: ChannelRequest, runtime: ChannelRuntime) async -> (WireReply, [OwnedDescriptor]) {
        switch request.request.operation {
        case .channelLoginCode:
            return await WorkerMain.serve(ChannelLoginCodeRequest.self, request) { code in
                await runtime.submitVerificationCode(code.code)
                return ChannelLoginCodeResponse()
            }
        default:
            return WorkerMain.unimplemented(request)
        }
    }
}
