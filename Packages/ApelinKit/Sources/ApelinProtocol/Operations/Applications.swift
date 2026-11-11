import ApelinCore
import Foundation

// Apps: what the bootstrap's `Applications` folder holds and what
// LaunchServices registers, listed for Settings ▸ Apps and removed from
// there. Served by the session host (Apelind/Dispatch/InstallHandler.swift,
// Session/Install/ApplicationCensus.swift).
//
// Only apps under `<install root>/Applications` are the subject: an app the
// bootstrap put there, one Apelin installed from an `.ipa`, or a registration
// left behind by one whose bundle is gone. An app iOS keeps in its own
// containers is listed nowhere and never removed from here, and a bundle a
// package owns is shown as that package's — a removal would break it.

/// Who put an app under `Applications`.
public enum ApplicationSource: String, Codable, Sendable {
    /// Apelin installed it from an `.ipa`; `installationID` names the record.
    case apelin
    /// An installed package lists the bundle: the package manager's to remove.
    case package
    /// Neither: copied in by another tool, or a registration whose bundle is
    /// no longer there.
    case other
}

/// One app the census found.
public struct ApplicationSummary: Codable, Sendable, Equatable {
    public var bundleID: String
    /// The name its `Info.plist` gives, or the bundle's folder name for one
    /// that is gone.
    public var name: String
    public var version: String
    /// The bundle as it is on the device; nil when the registration names a
    /// bundle that is no longer there.
    public var path: String?
    /// The path LaunchServices names, which a stale registration keeps after
    /// the bundle under it went away.
    public var registeredPath: String?
    public var source: ApplicationSource
    /// Apelin's installation record for this app, when it has one.
    public var installationID: String?
    /// The package that lists this bundle, when one does.
    public var packageID: String?
    /// Whether `applicationRemove` would act on it, and why not when not.
    public var removable: Bool
    public var reason: String?

    public init(
        bundleID: String,
        name: String,
        version: String = "",
        path: String? = nil,
        registeredPath: String? = nil,
        source: ApplicationSource,
        installationID: String? = nil,
        packageID: String? = nil,
        removable: Bool,
        reason: String? = nil,
    ) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.path = path
        self.registeredPath = registeredPath
        self.source = source
        self.installationID = installationID
        self.packageID = packageID
        self.removable = removable
        self.reason = reason
    }
}

public struct ApplicationListRequest: OperationRequest {
    public typealias Response = ApplicationListResponse
    public static let operation = AppOperation.applicationList
    public init() {}
}

public struct ApplicationListResponse: Codable, Sendable, Equatable {
    /// Sorted by name, the way the screen shows them.
    public var applications: [ApplicationSummary]

    public init(applications: [ApplicationSummary]) {
        self.applications = applications
    }
}

public struct ApplicationRemoveRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.applicationRemove
    /// The bundle ID the list showed, and the path it showed for it: the host
    /// acts only on that pair, never on a path a caller made up.
    public var bundleID: String
    /// nil for a registration whose bundle is gone, which is all a ghost
    /// has.
    public var path: String?

    public init(bundleID: String, path: String? = nil) {
        self.bundleID = bundleID
        self.path = path
    }
}

public extension ApelinService {
    /// The apps under the bootstrap's `Applications`, sorted by name.
    func applicationList() async throws -> ApplicationListResponse {
        try await send(ApplicationListRequest())
    }

    /// Removes an app the list showed: its registration, and its bundle when
    /// one is there. A SpringBoard restart is what takes the icon away.
    func applicationRemove(bundleID: String, path: String?) async throws {
        _ = try await send(ApplicationRemoveRequest(bundleID: bundleID, path: path))
    }
}
