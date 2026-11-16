import ApelinCore
import ApelinProtocol
import Foundation

/// Settings ▸ Plugins: the WeChat ClawBot channel. The host holds it
/// (`Session/Channel/WeChatChannel`), so this handler is only the wire's way
/// in: read its state, start a sign-in, hand it the number WeChat showed,
/// change where its conversations run, or sign out.
///
/// The project a request names is checked here, before the channel keeps it:
/// a name nothing is stored under would open a conversation nowhere.
enum ChannelHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .channelStatus:
            return await request.serve(ChannelStatusRequest.self) { _ in
                await host.channels.state()
            }
        case .channelSignIn:
            return await request.serve(ChannelSignInRequest.self) { _ in
                await host.channels.signIn()
            }
        case .channelVerifyCode:
            return await request.serve(ChannelVerifyCodeRequest.self) { code in
                await host.channels.verify(code.code)
            }
        case .channelConfigure:
            return await request.serve(ChannelConfigureRequest.self) { change in
                let project = try ChannelProjects.resolve(home: host.home, name: change.projectName)
                return await host.channels.configure(
                    enabled: change.enabled,
                    projectName: project,
                    approvalMode: change.approvalMode,
                    enabledModels: change.enabledModels,
                    language: change.language,
                    clearsProject: change.clearsProject == true
                )
            }
        case .channelSignOut:
            return await request.serve(ChannelSignOutRequest.self) { _ in
                await host.channels.signOut()
            }
        default:
            return request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a channel operation"))
        }
    }
}

/// Which project a channel's conversations live in.
enum ChannelProjects {
    /// The project's folder name, checked against `Projects/`; nil stays nil
    /// (a temporary chat).
    static func resolve(home: String, name: String?) throws -> String? {
        guard let name else { return nil }
        guard ProjectName.validate(name) == nil, let url = DataFolder(home: home).project(named: name) else {
            throw ApelinError(.badRequest, "“\(name)” is not a project name.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ApelinError(.notFound, "There is no project named “\(name)”.")
        }
        return name
    }
}
