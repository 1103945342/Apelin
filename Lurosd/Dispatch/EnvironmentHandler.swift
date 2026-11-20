import LurosProtocol

/// Environment tasks, read and cancelled in the registry. An agent reads
/// only the ones its own session started (its setups, imports, self-tests
/// and git tasks).
enum EnvironmentHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .environmentAttach:
            if case let .worker(.agent, instance) = request.caller {
                guard let instance, let attach = try? request.decode(EnvironmentAttachRequest.self),
                      await AgentSessionTable.shared.started(attach.taskID, session: instance)
                else {
                    return request.fail(LurosError(.denied, "an agent reads only the environment tasks it started"))
                }
            }
            return await host.attach(request, EnvironmentAttachRequest.self)
        case .environmentCancel:
            return await host.cancel(request, EnvironmentCancelRequest.self)
        case .developmentTools:
            return await developmentTools(request, host: host)
        default:
            return request.fail(LurosError(
                .badRequest,
                "\(request.operation.rawValue) is not an environment operation",
            ))
        }
    }

    /// The four device tools Luros's own work needs, as this device has them.
    /// Reading only: installing one is the user's package manager's.
    static func developmentTools(_ request: HostRequest, host: SessionHost) async -> HostReply {
        guard (try? request.decode(DevelopmentToolsRequest.self)) != nil else {
            return request.fail(LurosError(.badRequest, "the development tools request does not read"))
        }
        let rows = DevelopmentToolStatus.rows(installRoot: host.installRoot)
        return (.success(request.requestID, DevelopmentToolsResponse(tools: rows)), [])
    }
}
