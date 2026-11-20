import ApelinProtocol

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
                    return request.fail(ApelinError(.denied, "an agent reads only the environment tasks it started"))
                }
            }
            return await host.attach(request, EnvironmentAttachRequest.self)
        case .environmentCancel:
            return await host.cancel(request, EnvironmentCancelRequest.self)
        case .developmentTools:
            return await developmentTools(request, host: host)
        default:
            return request.fail(ApelinError(
                .badRequest,
                "\(request.operation.rawValue) is not an environment operation",
            ))
        }
    }

    /// The four device tools Apelin's own work needs: read them, or install one
    /// from the repositories the device already has. The work is the session
    /// host's own — no worker, no task — because the reply is the answer.
    static func developmentTools(_ request: HostRequest, host: SessionHost) async -> HostReply {
        let decoded: DevelopmentToolsRequest
        do {
            decoded = try request.decode(DevelopmentToolsRequest.self)
        } catch {
            return request.fail(error)
        }
        let installer = DevelopmentToolInstaller(installRoot: host.installRoot)
        let rows = await installer.rows()
        guard let install = decoded.install else {
            return (.success(request.requestID, DevelopmentToolsResponse(tools: rows)), [])
        }
        guard let package = DevelopmentToolInstaller.package(for: install) else {
            return request.fail(ApelinError(.badRequest, "\(install) is not one of the tools Apelin offers"))
        }
        do {
            let plan = try await installer.plan(installing: package)
            guard !decoded.dryRun else {
                return (.success(request.requestID, DevelopmentToolsResponse(
                    tools: rows,
                    packages: plan.install.map(\.name),
                    present: plan.alreadyInstalled,
                )), [])
            }
            let outcome = try await installer.install(package: package)
            return (.success(request.requestID, DevelopmentToolsResponse(
                tools: await installer.rows(),
                packages: outcome.installed,
                present: outcome.present,
            )), [])
        } catch {
            // The rows are read again: a failure part-way through leaves the
            // packages it did install on the device.
            return (.success(request.requestID, DevelopmentToolsResponse(
                tools: await installer.rows(),
                failure: "\(error)",
            )), [])
        }
    }
}
