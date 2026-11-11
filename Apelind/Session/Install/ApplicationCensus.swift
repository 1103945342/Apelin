import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// What is under the bootstrap's `Applications` right now, for Settings ▸
/// Apps: the registrations LaunchServices holds — which outlive the bundles
/// they name — together with the bundles on disk, each attributed to an
/// Apelin installation, a package, or neither.
///
/// Nothing here changes anything, and nothing outside
/// `<install root>/Applications` is looked at: an app iOS keeps in its own
/// containers is not this screen's subject.
enum ApplicationCensus {
    /// Apelin's own bundle, never removed from this screen.
    static let ownBundleID = "wiki.qaq.apelin"

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
        guard let data = FileManager.default.contents(atPath: path + "/Info.plist"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let identifier = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespaces),
              !identifier.isEmpty
        else { return nil }
        let folder = (path as NSString).lastPathComponent
        let name = [(plist["CFBundleDisplayName"] as? String), (plist["CFBundleName"] as? String)]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            ?? String(folder.dropLast(".app".count))
        let version = ((plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return (identifier, name, version)
    }

    /// Every `*.app` directly under `applications`.
    static func bundles(in applications: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: applications)) ?? []
        return names.filter { $0.hasSuffix(".app") }.sorted().map { applications + "/" + $0 }
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

    /// The rows: a registration or a bundle on disk each, attributed and
    /// sorted by name.
    ///
    /// - Parameters:
    ///   - registered: what `uicache -l` answered.
    ///   - bundles: the `.app` folders under `Applications`.
    ///   - records: Apelin's installation records.
    ///   - owners: `packageOwners`' answer.
    ///   - describe: `describe(bundleAt:)`, or a test's stand-in.
    static func rows(
        installRoot: String,
        registered: [(bundleID: String, path: String)],
        bundles: [String],
        records: [InstallationRecord],
        owners: [String: String],
        describe: (String) -> (bundleID: String, name: String, version: String)? = ApplicationCensus.describe(bundleAt:),
    ) -> [ApplicationSummary] {
        let folder = applicationsFolder(installRoot: installRoot)
        let inside = folder + "/"
        var rows: [ApplicationSummary] = []
        var claimed: Set<String> = []

        for entry in registered.sorted(by: { $0.bundleID < $1.bundleID }) {
            // An app iOS keeps in its own containers is none of this screen's.
            guard entry.path.hasPrefix(inside) else { continue }
            let info = describe(entry.path)
            let identifier = info?.bundleID ?? entry.bundleID
            guard !claimed.contains(identifier) else { continue }
            claimed.insert(identifier)
            let name = info?.name
                ?? String(((entry.path as NSString).lastPathComponent as NSString).deletingPathExtension)
            rows.append(attribute(
                bundleID: identifier,
                name: name,
                version: info?.version ?? "",
                path: info == nil ? nil : entry.path,
                registeredPath: entry.path,
                installRoot: installRoot,
                records: records,
                owners: owners,
            ))
        }

        for path in bundles.sorted() {
            guard let info = describe(path), !claimed.contains(info.bundleID) else { continue }
            claimed.insert(info.bundleID)
            rows.append(attribute(
                bundleID: info.bundleID,
                name: info.name,
                version: info.version,
                path: path,
                registeredPath: nil,
                installRoot: installRoot,
                records: records,
                owners: owners,
            ))
        }

        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One row: who the app is, and what a removal from here would do.
    private static func attribute(
        bundleID: String,
        name: String,
        version: String,
        path: String?,
        registeredPath: String?,
        installRoot: String,
        records: [InstallationRecord],
        owners: [String: String],
    ) -> ApplicationSummary {
        let applications = applicationsFolder(installRoot: installRoot)
        let held = records.last { $0.status == .installed && $0.application?.bundleID == bundleID }
        let below = path.flatMap { BootstrapRootPath.belowRoot($0) }.map { "/" + $0 }
        let owned = below.flatMap { owners[$0] }

        func summary(
            _ source: ApplicationSource,
            removable: Bool,
            installationID: String? = nil,
            packageID: String? = nil,
            reason: String? = nil,
        ) -> ApplicationSummary {
            ApplicationSummary(
                bundleID: bundleID,
                name: name,
                version: version,
                path: path,
                registeredPath: registeredPath,
                source: source,
                installationID: installationID,
                packageID: packageID,
                removable: removable,
                reason: reason,
            )
        }

        if bundleID.hasPrefix("com.apple.") {
            return summary(.other, removable: false, reason: "A system app, which is not managed here.")
        }
        if bundleID == ownBundleID {
            return summary(.apelin, removable: false, reason: "This is Apelin itself.")
        }
        if let owned {
            return summary(
                .package,
                removable: false,
                packageID: owned,
                reason: "The package \(owned) lists this app. Remove that package with your package manager.",
            )
        }
        if let held {
            let resolved = held.application?.path(under: applications)
            // The record's own copy, or a registration left after it went.
            if path == nil || resolved == path {
                return summary(.apelin, removable: true, installationID: held.installationID)
            }
        }
        return summary(.other, removable: true)
    }
}
