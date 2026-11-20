import ApelinCore

// The device tools Apelin's own work needs and its package does not carry:
// `ldid` signs, `git` fetches a repository, `dpkg-deb` reads a package, and
// `uicache` registers a built app. Settings ▸ Environment reads their state
// and installs a missing one, dependencies included, from the repositories
// the device already has (no repository signature is checked).

/// One tool, as the device has it or not.
public struct DevelopmentToolRow: Codable, Sendable, Equatable, Hashable {
    /// The program's name, which is also what the row is called.
    public var id: String
    /// The package that carries it.
    public var packageID: String
    /// Where the program is, when the device has it.
    public var path: String?
    /// The installed package's version, when the device has it.
    public var version: String?

    public var present: Bool { path != nil }

    public init(id: String, packageID: String, path: String? = nil, version: String? = nil) {
        self.id = id
        self.packageID = packageID
        self.path = path
        self.version = version
    }
}

/// Reads the four tools, or installs one of them.
///
/// `install` names a tool id (`ldid`, `git`, `dpkg-deb`, `uicache`). With
/// `dryRun`, nothing is fetched: the reply lists the packages installing it
/// would add, for the confirmation the app shows first. Without it, each
/// package is downloaded, checked against the index that named it, and handed
/// to irisind, dependencies first.
public struct DevelopmentToolsRequest: OperationRequest {
    public typealias Response = DevelopmentToolsResponse
    public static let operation = AppOperation.developmentTools

    public var install: String?
    public var dryRun: Bool

    public init(install: String? = nil, dryRun: Bool = false) {
        self.install = install
        self.dryRun = dryRun
    }
}

public struct DevelopmentToolsResponse: Codable, Sendable, Equatable {
    public var tools: [DevelopmentToolRow]
    /// The packages an install would add, or did, dependencies first.
    public var packages: [String]
    /// Packages the device already had that the install needed.
    public var present: [String]
    /// Why it failed, when it did; the tools above are the state afterwards.
    public var failure: String?

    public init(
        tools: [DevelopmentToolRow] = [],
        packages: [String] = [],
        present: [String] = [],
        failure: String? = nil
    ) {
        self.tools = tools
        self.packages = packages
        self.present = present
        self.failure = failure
    }
}

public extension ApelinService {
    func developmentTools(_ request: DevelopmentToolsRequest) async throws -> DevelopmentToolsResponse {
        try await send(request)
    }
}
