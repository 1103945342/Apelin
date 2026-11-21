import Foundation
import LurosCore
import LurosProtocol

/// Settings ▸ Storage: what each area of the data folder costs, and the
/// emptying of the folders no model indexes.
///
/// The walks run off the host's own path (`Task.detached`), so a project of
/// a few gigabytes never holds another request up; the page asks for one
/// area at a time and shows each answer as it lands.
enum StorageHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .storageUsage:
            await usage(request, host: host)
        case .storagePurge:
            await purge(request, host: host)
        default:
            request.fail(LurosError(.badRequest, "\(request.operation.rawValue) is not a storage operation"))
        }
    }

    private static func usage(_ request: HostRequest, host: SessionHost) async -> HostReply {
        do {
            let ask = try request.decode(StorageUsageRequest.self)
            let data = host.dataFolder
            let usage = await Task.detached(priority: .utility) {
                ask.areas.map { area in
                    StorageKeeper.measure(area, data: data, children: ask.children)
                }
            }.value
            let disk = ask.includeDisk
                ? await Task.detached(priority: .utility) { StorageKeeper.disk(at: data.root) }.value
                : nil
            return .success(request.requestID, StorageUsageResponse(usage: usage, disk: disk))
        } catch {
            return request.fail(error)
        }
    }

    private static func purge(_ request: HostRequest, host: SessionHost) async -> HostReply {
        do {
            let ask = try request.decode(StoragePurgeRequest.self)
            // A build or an environment task writes into the areas below.
            if let refusal = StorageKeeper.busy(await host.registry.activeByKind) {
                throw refusal
            }
            // One at a time, and never two calls at once: the walk that
            // measures a folder must not run beside the removal next to it.
            var reclaimed: Int64 = 0
            var purged: [StorageArea] = []
            for area in ask.areas {
                let data = host.dataFolder
                reclaimed += try await Task.detached(priority: .utility) {
                    try StorageKeeper.purge(area, data: data)
                }.value
                purged.append(area)
            }
            return .success(request.requestID, StoragePurgeResponse(reclaimed: reclaimed, purged: purged))
        } catch {
            return request.fail(error)
        }
    }
}
