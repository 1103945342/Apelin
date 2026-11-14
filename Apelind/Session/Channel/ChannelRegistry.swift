import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// A channel as the host saved it. Never a token: WeChat hands one to the
/// worker when the reader signs in, and it stays in the worker's own session
/// file under `<data>/WeChatChannel/<id>/`, which the host never reads.
struct ChannelRecord: Codable, Equatable {
    var id: String
    var kind: ChannelKind
    var enabled: Bool
    /// The project a message opens a conversation in; nil is General Chat.
    var projectID: String?
    /// The conversation this channel drives; nil until it has one.
    var sessionID: String?
    var allowlist: [String]
    var approvalMode: ApprovalMode
    /// `channel:<id>` once the host opened the conversation for it, so the
    /// conversation says who opened it.
    var openedBy: String?
    /// Whether the worker last reported itself signed in. A flag, never a
    /// secret; a record written before this field reads as signed out.
    var loggedIn: Bool
    var updatedAt: Date

    init(
        id: String,
        kind: ChannelKind,
        enabled: Bool,
        projectID: String?,
        sessionID: String?,
        allowlist: [String],
        approvalMode: ApprovalMode,
        openedBy: String?,
        loggedIn: Bool = false,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.projectID = projectID
        self.sessionID = sessionID
        self.allowlist = allowlist
        self.approvalMode = approvalMode
        self.openedBy = openedBy
        self.loggedIn = loggedIn
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case enabled
        case projectID
        case sessionID
        case allowlist
        case approvalMode
        case openedBy
        case loggedIn
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(ChannelKind.self, forKey: .kind)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        allowlist = try container.decode([String].self, forKey: .allowlist)
        approvalMode = try container.decode(ApprovalMode.self, forKey: .approvalMode)
        openedBy = try container.decodeIfPresent(String.self, forKey: .openedBy)
        loggedIn = try container.decodeIfPresent(Bool.self, forKey: .loggedIn) ?? false
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

enum ChannelRegistryError: Error {
    /// The file was there and could not be read. It has been set aside, and
    /// the channel must not run on a guess.
    case corrupt(String)
}

/// `<state>/channels/<id>/`, one folder per channel:
///
///     config.json    0600 root   what the app configured
///     inbox.json     0600 root   the message IDs already injected
///
/// No token is here. Every write is atomic and every file is root's alone. A
/// file that does not read is set aside (`UnreadableFile.setAside`) and
/// reported, never replaced by an empty state the next save would make
/// permanent.
struct ChannelRegistry {
    let directory: URL

    private func folder(_ id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    private func configURL(_ id: String) -> URL {
        folder(id).appendingPathComponent("config.json")
    }

    private func inboxURL(_ id: String) -> URL {
        folder(id).appendingPathComponent("inbox.json")
    }

    /// Every channel folder that names a usable ID, sorted.
    func ids() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { ChannelRules.isValidChannelID($0) }.sorted()
    }

    func load(_ id: String) throws -> ChannelRecord {
        guard ChannelRules.isValidChannelID(id) else {
            throw ApelinError(.badRequest, "a channel ID is letters, digits, '-' and '_' only")
        }
        let url = configURL(id)
        guard let data = try? Data(contentsOf: url) else {
            throw ApelinError(.notFound, "This channel was not configured.")
        }
        do {
            return try JSONCoding.decode(ChannelRecord.self, from: data)
        } catch {
            _ = UnreadableFile.setAside(url)
            throw ChannelRegistryError.corrupt(url.lastPathComponent)
        }
    }

    func save(_ record: ChannelRecord) throws {
        guard ChannelRules.isValidChannelID(record.id) else {
            throw ApelinError(.badRequest, "a channel ID is letters, digits, '-' and '_' only")
        }
        try makeFolder(record.id)
        let data = try JSONCoding.encode(record)
        try write(data, to: configURL(record.id))
    }

    func remove(_ id: String) throws {
        guard ChannelRules.isValidChannelID(id) else { return }
        let url = folder(id)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    func inbox(_ id: String) throws -> ChannelInbox {
        guard ChannelRules.isValidChannelID(id) else {
            throw ApelinError(.badRequest, "a channel ID is letters, digits, '-' and '_' only")
        }
        let url = inboxURL(id)
        guard let data = try? Data(contentsOf: url) else {
            return ChannelInbox()
        }
        do {
            return try JSONCoding.decode(ChannelInbox.self, from: data)
        } catch {
            _ = UnreadableFile.setAside(url)
            throw ChannelRegistryError.corrupt(url.lastPathComponent)
        }
    }

    func saveInbox(_ inbox: ChannelInbox, channel id: String) throws {
        try makeFolder(id)
        try write(try JSONCoding.encode(inbox), to: inboxURL(id))
    }

    private func makeFolder(_ id: String) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder(id).path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ApelinError(.conflict, "A file is in the way of this channel's folder.")
            }
            return
        }
        try FileManager.default.createDirectory(
            at: folder(id),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        _ = chmod(url.path, 0o600)
    }
}
