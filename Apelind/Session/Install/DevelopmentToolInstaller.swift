import ApelinCore
import CryptoKit
import Darwin
import Foundation

/// Installs a package and everything it depends on from the device's own APT
/// indexes: resolve the closure, download each `.deb`, check it against the
/// index's `SHA256` and `Size`, and hand them to irisind one at a time, in
/// dependency order. This is the half `irisin-cli` used to do for the agent's
/// dependency step; repositories are read as the last `apt update` left them
/// and no repository signature is verified.
actor DevelopmentToolInstaller {
    /// What one install did, package by package.
    struct Outcome: Sendable, Equatable {
        /// The package ids irisind reported as installed, in order.
        var installed: [String] = []
        /// Packages the device already had, left alone.
        var present: [String] = []
        var failure: String?
    }

    private let installRoot: String
    private let architecture: String
    private let service: InstallService
    private let session: URLSession

    /// `installRoot` is the bootstrap root (`/` when apelind runs from a
    /// roothide jbroot that redirects its own `/`, the daemon's own rule).
    init(
        installRoot: String,
        architecture: String = DevelopmentToolInstaller.deviceArchitecture,
        service: InstallService = IrisinInstallService(),
        session: URLSession = .shared
    ) {
        self.installRoot = installRoot
        self.architecture = architecture
        self.service = service
        self.session = session
    }

    /// The architecture the packages for this device are built for.
    static let deviceArchitecture = "iphoneos-arm64"

    // MARK: - Reading the device

    private var listsFolder: String { installRoot + "/var/lib/apt/lists" }
    private var statusFile: String { installRoot + "/var/lib/dpkg/status" }

    private func repositories() -> [PackageRepository] {
        var repositories: [PackageRepository] = []
        let sources = installRoot + "/etc/apt/sources.list"
        if let text = try? String(contentsOfFile: sources, encoding: .utf8) {
            repositories += PackageSources.parse(list: text, architecture: architecture)
        }
        let folder = installRoot + "/etc/apt/sources.list.d"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder))?.sorted() ?? [] {
            let path = folder + "/" + name
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if name.hasSuffix(".list") {
                repositories += PackageSources.parse(list: text, architecture: architecture)
            } else if name.hasSuffix(".sources") {
                repositories += PackageSources.parse(deb822: text, architecture: architecture)
            }
        }
        return repositories
    }

    /// Every index the device already has, in the order its sources name them.
    /// A repository whose index is missing is left out: fetching one would
    /// need a signature this installer does not check.
    private func index() -> [IndexedPackage] {
        var packages: [IndexedPackage] = []
        for repository in repositories() {
            let path = listsFolder + "/" + repository.indexName
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            packages += IndexedPackage.parse(text, architecture: architecture, source: repository.uri)
        }
        return packages
    }

    private func installed() -> InstalledPackages {
        InstalledPackages(status: (try? String(contentsOfFile: statusFile, encoding: .utf8)) ?? "")
    }

    /// What installing `name` needs, for a confirmation sheet.
    func plan(installing name: String) throws -> PackagePlan {
        try PackagePlanner(index: index(), installed: installed()).plan(installing: [name])
    }

    // MARK: - Installing

    func install(package name: String) async throws -> Outcome {
        let plan = try plan(installing: name)
        var outcome = Outcome(present: plan.alreadyInstalled)
        guard !plan.install.isEmpty else { return outcome }

        let staging = installRoot + "/var/tmp/apelin-tools-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: staging) }

        for package in plan.install {
            let repository = repositories().first { $0.uri == package.source }
                ?? PackageRepository(uri: package.source, suite: "", component: "", architecture: architecture)
            let file = try await download(package, from: repository, into: staging)
            try await submit(file, sha256: package.sha256)
            outcome.installed.append(package.name)
        }
        return outcome
    }

    /// Fetches one package and checks it against the index that named it.
    private func download(
        _ package: IndexedPackage,
        from repository: PackageRepository,
        into staging: String
    ) async throws -> String {
        let url = repository.url(for: package.filename)
        guard let address = URL(string: url) else {
            throw Failure("\(package.name): \(url) is not an address")
        }
        let (data, response) = try await session.data(from: address)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure("\(package.name): the repository answered \(http.statusCode)")
        }
        guard data.count == package.size else {
            throw Failure("\(package.name): \(data.count) bytes, and the index says \(package.size)")
        }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == package.sha256 else {
            throw Failure("\(package.name): the file does not match the index's SHA-256")
        }
        let file = staging + "/" + (package.filename as NSString).lastPathComponent
        try data.write(to: URL(fileURLWithPath: file), options: .atomic)
        return file
    }

    /// Hands one `.deb` to irisind and waits for its transaction to end.
    private func submit(_ file: String, sha256: String) async throws {
        let descriptor = open(file, O_RDONLY)
        guard descriptor >= 0 else { throw Failure("the downloaded package could not be opened") }
        defer { close(descriptor) }
        let transaction = UUID()
        var status = try await service.submitInstall(transaction: transaction, descriptor: descriptor, sha256: sha256)
        var reads = 0
        while !status.state.isFinished {
            // irisind runs the install itself; a batch of events is how its
            // progress arrives, and the status is read while there are none.
            let batch = try await service.events(of: transaction, after: status.nextSequence)
            status = batch.status
            if batch.events.isEmpty { try await Task.sleep(nanoseconds: 400_000_000) }
            reads += 1
            if reads > 1800 { throw Failure("the install did not finish") }
        }
        switch status.state {
        case .succeeded:
            return
        default:
            throw Failure(status.failureText ?? status.failure ?? "the install failed (\(status.state.rawValue))")
        }
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
