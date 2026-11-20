import LurosCore
import LurosProtocol
import Darwin
import Foundation

/// What Settings ▸ Apps lists: the apps Luros installed from an `.ipa`, and
/// for each one whether its bundle is still there — a registration
/// LaunchServices kept after the bundle went away is shown, so it can be
/// cleared.
///
/// Nothing else under `Applications` is this screen's subject: an app a
/// package installed belongs to its package manager, and one another tool
/// copied in was never Luros's. Nothing here changes anything.
enum ApplicationCensus {
    /// Luros's own bundle, never removed from this screen.
    static let ownBundleID = "com.fluoxetine.luros"

    /// `<install root>/Applications`.
    static func applicationsFolder(installRoot: String) -> String {
        (installRoot == "/" ? "" : installRoot) + "/Applications"
    }

    /// `uicache -l`: one `bundleID : /path/App.app` a line.
    static func parseRegistered(_ output: String) -> [(bundleID: String, path: String)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let bundleID = parts[0].trimmingCharacters(in: .whitespaces)
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            guard !bundleID.isEmpty, path.hasPrefix("/") else { return nil }
            return (bundleID, path)
        }
    }

    /// A bundle's `Info.plist`: the identifier it claims, the name to show
    /// and its version. nil for a folder that holds no readable one.
    static func describe(bundleAt path: String) -> (bundleID: String, name: String, version: String)? {
        AppBundle.describe(bundleAt: path)
    }

    /// Which package lists which bundle under `Applications`, read from the
    /// package database's own `.list` files: `/Applications/Foo.app` →
    /// `com.example.foo`. Bounded — a database bigger than this leaves its
    /// apps unattributed rather than read for minutes.
    static func packageOwners(infoDirectory: String, limitBytes: Int = 48 << 20) -> [String: String] {
        var owners: [String: String] = [:]
        var read = 0
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: infoDirectory)) ?? []).sorted()
            where name.hasSuffix(".list")
        {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: infoDirectory + "/" + name)) else { continue }
            read += data.count
            guard read <= limitBytes else { break }
            let packageID = String(name.dropLast(".list".count))
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n")
                where line.hasPrefix("/Applications/")
            {
                // `/Applications`, the bundle, then whatever it holds.
                let components = line.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
                guard components.count >= 2 else { continue }
                let bundle = "/Applications/" + String(components[1])
                guard bundle.hasSuffix(".app") else { continue }
                owners[bundle] = packageID
            }
        }
        return owners
    }

    /// One row per app Luros installed that is still worth showing: its
    /// bundle, or the registration left after the bundle went away. A record
    /// whose app is gone from both is left out — there is nothing to remove.
    ///
    /// - Parameters:
    ///   - registered: what `uicache -l` answered.
    ///   - records: Luros's installation records, oldest first.
    ///   - owners: `packageOwners`' answer.
    ///   - describe: `describe(bundleAt:)`, or a test's stand-in.
    static func rows(
        installRoot: String,
        registered: [(bundleID: String, path: String)],
        records: [InstallationRecord],
        owners: [String: String],
        describe: (String) -> (bundleID: String, name: String, version: String)? = ApplicationCensus.describe(bundleAt:),
    ) -> [ApplicationSummary] {
        let applications = applicationsFolder(installRoot: installRoot)
        var registrations: [String: String] = [:]
        for entry in registered.sorted(by: { $0.bundleID < $1.bundleID }) where registrations[entry.bundleID] == nil {
            registrations[entry.bundleID] = entry.path
        }

        // The newest record of a bundle is the one that answers for it.
        var newest: [String: InstallationRecord] = [:]
        for record in records.sorted(by: { $0.createdAt < $1.createdAt })
            where record.status == .installed
        {
            guard let application = record.application else { continue }
            newest[application.bundleID] = record
        }

        var rows: [ApplicationSummary] = []
        for record in newest.values {
            guard let application = record.application else { continue }
            let resolved = application.path(under: applications)
            let info = describe(resolved)
            let present = info?.bundleID == application.bundleID
            let registeredPath = registrations[application.bundleID]
            guard present || registeredPath != nil else { continue }

            let name = info?.name ?? application.name
            let version = info?.version ?? record.version
            let below = present ? BootstrapRootPath.belowRoot(resolved).map { "/" + $0 } : nil
            let owned = below.flatMap { owners[$0] }
            rows.append(ApplicationSummary(
                bundleID: application.bundleID,
                name: name,
                version: version,
                path: present ? resolved : nil,
                registeredPath: registeredPath,
                source: owned == nil ? .apelin : .package,
                installationID: record.installationID,
                packageID: owned,
                removable: owned == nil && application.bundleID != ownBundleID,
                reason: owned.map { "The package \($0) lists this app. Remove that package with your package manager." },
            ))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
