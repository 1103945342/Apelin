import ApelinCore
import Foundation
import os

/// models.dev's catalog as this device holds it.
///
/// The app ships a copy of the trimmed catalog (`.github/workflows/model-catalog.yml`
/// writes `Apelin/Resources/models.dev.json` every day), and the first launch
/// writes it into the data folder the agent reads, so a device that has never
/// reached the network still reads models the catalog kwwk ships does not name.
/// A copy older than a week is replaced in the background — models.dev first,
/// then this repository's copy through jsDelivr, which is reachable where
/// models.dev is not — and a copy that cannot be fetched is kept as it is: no
/// conversation ever waits for this.
enum ModelDataRefresh {
    private static let logger = Logger(subsystem: "wiki.qaq.apelin", category: "ModelData")
    /// The last attempt, so a device with no network tries once a day rather
    /// than at every launch.
    private static let attemptKey = "ModelData.lastAttempt"
    /// The shortest gap between two attempts that failed or found nothing to do.
    private static let retryInterval: TimeInterval = 24 * 60 * 60

    /// Starts the work of the launch: the copy in place, then maybe a newer one.
    static func start() {
        Task.detached(priority: .utility) { await run() }
    }

    /// Writes the shipped copy where the agent reads it when nothing is there,
    /// then replaces an old copy when the network answers.
    static func run(
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        fetch: (URL) async throws -> ModelDataSnapshot = { try await download($0) },
    ) async {
        let folder = DataFolder.app
        let url = folder.modelDataFile
        var current = ModelDataSnapshot.read(url)
        if current == nil, let bundled = ModelDataSnapshot.bundled() {
            do {
                try bundled.write(to: url, makeLevels: folder.makeLevels)
                current = bundled
                logger.notice("wrote the shipped model data, \(bundled.count, privacy: .public) models")
            } catch {
                logger.error("could not write the shipped model data: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard current?.isStale(now: now) ?? true else { return }
        if let last = defaults.object(forKey: attemptKey) as? Date, now.timeIntervalSince(last) < retryInterval {
            return
        }
        defaults.set(now, forKey: attemptKey)
        for source in [ModelDataSnapshot.remoteURL, ModelDataSnapshot.mirrorURL] {
            do {
                let fresh = try await fetch(source)
                // A copy with nothing in it is no copy: keep what is there.
                guard fresh.count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                try fresh.write(to: url, makeLevels: folder.makeLevels)
                logger.notice("model data updated from \(source.host() ?? "?", privacy: .public): \(fresh.count, privacy: .public) models")
                return
            } catch {
                logger.notice("model data not read from \(source.host() ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// models.dev answers with its whole catalog, which is trimmed here; this
    /// repository's copy is already trimmed and is read as it is.
    static func download(_ url: URL) async throws -> ModelDataSnapshot {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CocoaError(.fileReadUnknown) }
        if let snapshot = ModelDataSnapshot.decode(data) { return snapshot }
        return try ModelDataSnapshot.parse(modelsDev: data, source: url.absoluteString)
    }
}
