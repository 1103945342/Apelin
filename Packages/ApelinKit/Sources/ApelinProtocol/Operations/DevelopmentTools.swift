import Foundation

// The device tools Apelin's own work needs and its package does not carry:
// `ldid` signs, `git` fetches a repository, `dpkg-deb` reads a package, and
// `uikittools` carries `uicache`, which registers a built app. Settings ▸
// Environment reads their state; a missing one is installed from the user's
// package manager, which the app opens at the package's page.

/// One tool, as the device has it or not.
public struct DevelopmentToolRow: Codable, Sendable, Equatable, Hashable {
    /// The package the tool comes from, which is also what the row is called.
    public var packageID: String
    /// The program inside `usr/bin` whose presence means the package is here.
    public var program: String
    /// Where that program is, when the device has it.
    public var path: String?
    /// The installed package's version, when the device has it.
    public var version: String?

    public var present: Bool { path != nil }

    public init(packageID: String, program: String, path: String? = nil, version: String? = nil) {
        self.packageID = packageID
        self.program = program
        self.path = path
        self.version = version
    }
}

/// Reads the four tools, and nothing else: installing one is the user's
/// package manager's, which the app opens at that package's page.
public struct DevelopmentToolsRequest: OperationRequest {
    public typealias Response = DevelopmentToolsResponse
    public static let operation = AppOperation.developmentTools

    public init() {}
}

public struct DevelopmentToolsResponse: Codable, Sendable, Equatable {
    public var tools: [DevelopmentToolRow]

    public init(tools: [DevelopmentToolRow] = []) {
        self.tools = tools
    }
}

public extension ApelinService {
    func developmentTools() async throws -> DevelopmentToolsResponse {
        try await send(DevelopmentToolsRequest())
    }
}
