import Foundation

/// One place Luros keeps bytes, as Settings ▸ Storage lists them. The host
/// measures every one of them; only the folders nothing indexes may be
/// emptied through `storagePurge`. A project or a conversation is deleted
/// through the app's own model (so the sidebar and the chat list forget it
/// too), and an SDK or a toolchain through the page that registered it.
public enum StorageArea: String, Codable, CaseIterable, Sendable {
    /// `Builds/`: each project's build folders and `Builds/.build-cache/`.
    case builds
    /// `Temporary/`: a build's staging, the agent's scratches.
    case temporary
    /// `Exports/`: the files written for the app to share.
    case exports
    /// `Journal/` and the console's finished runs (`console/done`, `console/out`).
    case logs
    /// `backups/`: the copies taken before a protected edit replaces a file.
    case backups
    /// `Projects/`: every project with its files and its Git history.
    case projects
    /// `Chats/`: every conversation's record and event log.
    case chats
    /// `sessions/`: what an agent conversation resumes from.
    case sessions
    /// `SDKs/`: the imported iPhoneOS SDKs.
    case sdks
    /// `Environment/`: the registered toolchains and their staging.
    case toolchains

    /// Whether `storagePurge` may empty this one: the folders no model
    /// indexes. The others are the app's to delete, one item at a time.
    public var isPurgeable: Bool {
        switch self {
        case .builds, .temporary, .exports, .logs, .backups: true
        case .projects, .chats, .sessions, .sdks, .toolchains: false
        }
    }
}

/// One child of an area: a project by its folder name, a conversation by the
/// id its record is named with.
public struct StorageEntry: Codable, Sendable, Equatable {
    public var name: String
    public var bytes: Int64
    public var files: Int64

    public init(name: String, bytes: Int64, files: Int64) {
        self.name = name
        self.bytes = bytes
        self.files = files
    }
}

/// What one area costs. Asked for an area at a time, so the page shows each
/// figure the moment its own walk ends.
public struct StorageUsage: Codable, Sendable, Equatable {
    public var area: StorageArea
    public var bytes: Int64
    public var files: Int64
    /// The area's children, when the request asked for them and the area has
    /// any to tell apart; nil otherwise.
    public var entries: [StorageEntry]?
    /// Why the area could not be measured (a folder the host may not read).
    /// Nil when it was.
    public var failure: String?

    public init(
        area: StorageArea,
        bytes: Int64 = 0,
        files: Int64 = 0,
        entries: [StorageEntry]? = nil,
        failure: String? = nil,
    ) {
        self.area = area
        self.bytes = bytes
        self.files = files
        self.entries = entries
        self.failure = failure
    }
}

/// The device's disk as `statfs` on the data folder answers it.
public struct StorageDisk: Codable, Sendable, Equatable {
    public var available: Int64
    public var total: Int64

    public init(available: Int64, total: Int64) {
        self.available = available
        self.total = total
    }
}

/// Measures the areas named, one walk each. The page sends one request per
/// row so a slow folder never holds up a fast one.
public struct StorageUsageRequest: OperationRequest {
    public typealias Response = StorageUsageResponse
    public static let operation = AppOperation.storageUsage

    public var areas: [StorageArea]
    /// A project or a conversation's own size, under `entries`.
    public var children: Bool
    /// The device's free and total space, beside the areas.
    public var includeDisk: Bool

    public init(areas: [StorageArea], children: Bool = false, includeDisk: Bool = false) {
        self.areas = areas
        self.children = children
        self.includeDisk = includeDisk
    }
}

public struct StorageUsageResponse: Codable, Sendable, Equatable {
    public var usage: [StorageUsage]
    public var disk: StorageDisk?

    public init(usage: [StorageUsage], disk: StorageDisk? = nil) {
        self.usage = usage
        self.disk = disk
    }
}

/// Empties the purgeable areas named — refused for any other, and refused
/// while a build or an environment task is running, since both write there.
public struct StoragePurgeRequest: OperationRequest {
    public typealias Response = StoragePurgeResponse
    public static let operation = AppOperation.storagePurge

    public var areas: [StorageArea]

    public init(areas: [StorageArea]) {
        self.areas = areas
    }
}

public struct StoragePurgeResponse: Codable, Sendable, Equatable {
    /// The bytes the removals reclaimed, as measured before each one.
    public var reclaimed: Int64
    /// The areas actually emptied, in the order they were asked for.
    public var purged: [StorageArea]

    public init(reclaimed: Int64, purged: [StorageArea]) {
        self.reclaimed = reclaimed
        self.purged = purged
    }
}

public extension LurosService {
    func storageUsage(
        areas: [StorageArea],
        children: Bool = false,
        includeDisk: Bool = false,
    ) async throws -> StorageUsageResponse {
        try await send(StorageUsageRequest(areas: areas, children: children, includeDisk: includeDisk))
    }

    @discardableResult
    func storagePurge(_ areas: [StorageArea]) async throws -> StoragePurgeResponse {
        try await send(StoragePurgeRequest(areas: areas))
    }
}
