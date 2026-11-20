import LurosCore
import LurosProtocol
import Foundation

/// One request as the session host sees it.
struct HostRequest: Sendable {
    var request: WireRequest
    var descriptors: [OwnedDescriptor]
    var caller: Caller

    var operation: AppOperation {
        request.operation
    }

    var requestID: String {
        request.requestID
    }

    /// A request that does not decode comes from an app of another version.
    /// The log names only the operation, never what the request held.
    func decode<R: OperationRequest>(_ type: R.Type) throws -> R {
        do {
            return try request.decode(type)
        } catch {
            NSLog("lurosd-session: could not read %@", operation.rawValue)
            throw LurosError(
                .badRequest,
                """
                Luros could not read this request. Reinstall Luros with your preferred package manager, \
                then try again.
                """,
            )
        }
    }
}

typealias HostReply = (WireReply, [OwnedDescriptor])

extension HostRequest {
    /// An `LurosError` goes out as it is; anything else becomes `.internal`.
    func fail(_ error: any Error) -> HostReply {
        if let error = error as? LurosError {
            return (.failure(requestID, error), [])
        }
        NSLog("lurosd-session: %@ failed: %@", operation.rawValue, String(describing: error))
        return (.failure(requestID, LurosError(.internal)), [])
    }

    /// Decodes the request as `R`, runs `body`, encodes its answer; thrown
    /// errors become the reply's error.
    func serve<R: OperationRequest>(_: R.Type, _ body: (R) async throws -> R.Response) async -> HostReply {
        do {
            return try await (.success(requestID, body(decode(R.self))), [])
        } catch {
            return fail(error)
        }
    }
}

/// Each `Lurosd/Dispatch/<Domain>Handler.swift` is one of these.
protocol DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply
}

/// Routes a request to its domain's handler, after the caller policy and
/// the host's own approval check (Session/Approval/SessionHost+Approval.swift).
enum Dispatcher {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        guard CallerPolicy.allows(request.caller, request.operation) else {
            return request.fail(LurosError(.denied, "\(request.operation.rawValue) is not available to this caller"))
        }
        if let refusal = await AgentDelegationAdmission.refusal(request, host: host) {
            return refusal
        }
        var request = request
        if let refusal = await host.precheck(&request) {
            return refusal
        }
        let reply = await route(request, host: host)
        await host.observe(request, reply)
        return reply
    }

    private static func route(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation.domain {
        // lurosd answers hello itself; one that reaches the host is a bug.
        case .hello: request.fail(LurosError(.badRequest, "hello is answered by lurosd"))
        case .toolchain: await ToolchainHandler.handle(request, host: host)
        case .sdk: await SDKHandler.handle(request, host: host)
        case .environment: await EnvironmentHandler.handle(request, host: host)
        case .project: await ProjectHandler.handle(request, host: host)
        case .build: await BuildHandler.handle(request, host: host)
        case .install: await InstallHandler.handle(request, host: host)
        case .files: await FilesHandler.handle(request, host: host)
        case .terminal: await TerminalHandler.handle(request, host: host)
        case .logs: await LogsHandler.handle(request, host: host)
        case .diagnostics: await DiagnosticsHandler.handle(request, host: host)
        case .agent: await AgentHandler.handle(request, host: host)
        case .toolHost: await ToolHostHandler.handle(request, host: host)
        case .transfer: await TransferHandler.handle(request, host: host)
        case .git: await GitHandler.handle(request, host: host)
        case .distribution: await DistributionHandler.handle(request, host: host)
        case .channel: await ChannelHandler.handle(request, host: host)
        }
    }
}
