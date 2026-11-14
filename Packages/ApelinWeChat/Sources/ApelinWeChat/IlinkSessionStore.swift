import Foundation

/// What the session file holds: the bot's credential, the `getupdates` cursor,
/// and the `context_token` of every peer that wrote to the bot. One file, so a
/// send after a restart has both the token and the reply context.
public struct IlinkCredentials: Sendable, Equatable, Codable {
    public let botID: String
    public let token: String
    public let userID: String?
    public let issuedAt: Date

    public init(botID: String, token: String, userID: String?, issuedAt: Date) {
        self.botID = botID
        self.token = token
        self.userID = userID
        self.issuedAt = issuedAt
    }
}

extension IlinkCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never the token: this string may be put in a log or a diagnostic.
    public var description: String {
        "IlinkCredentials(botID: \(botID), token: <redacted>)"
    }

    public var debugDescription: String { description }
}

public struct IlinkSession: Sendable, Equatable, Codable {
    public var credentials: IlinkCredentials
    /// The `get_updates_buf` last committed. It moves only after the events of
    /// the batch were delivered and this file was written.
    public var cursor: String?
    /// Peer id → the `context_token` it last brought.
    public var contextTokens: [String: String]
    /// The host the login moved the session to, when the server sent one.
    public var baseURL: URL?
    public var updatedAt: Date

    public init(
        credentials: IlinkCredentials,
        cursor: String?,
        contextTokens: [String: String],
        baseURL: URL?,
        updatedAt: Date
    ) {
        self.credentials = credentials
        self.cursor = cursor
        self.contextTokens = contextTokens
        self.baseURL = baseURL
        self.updatedAt = updatedAt
    }
}

extension IlinkSession: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "IlinkSession(botID: \(credentials.botID), cursor: \(cursor == nil ? "none" : "set"), peers: \(contextTokens.count))"
    }

    public var debugDescription: String { description }
}

/// What a store found. A file that exists and does not read is a case of its
/// own: it is not "no session", and it is never replaced by an empty one.
public enum IlinkStoredSession: Sendable, Equatable {
    case absent
    case present(IlinkSession)
    case unreadable(path: String, reason: String)
}

public protocol IlinkSessionStore: Sendable {
    func read() throws -> IlinkStoredSession
    /// Replaces the file atomically, readable by its owner alone.
    func write(_ session: IlinkSession) throws
    /// Removes the file. Only an explicit `discardSession()` calls this.
    func discard() throws
}

/// One JSON file, mode 0600, written through a temporary file and a rename.
public struct IlinkFileSessionStore: IlinkSessionStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func read() throws -> IlinkStoredSession {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return .absent
        }
        if isDirectory.boolValue {
            return .unreadable(path: fileURL.path, reason: "not a regular file")
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .unreadable(path: fileURL.path, reason: "cannot read")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .present(try decoder.decode(IlinkSession.self, from: data))
        } catch {
            return .unreadable(path: fileURL.path, reason: "cannot decode")
        }
    }

    public func write(_ session: IlinkSession) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            do {
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw IlinkFailure.sessionUnwritable(path: fileURL.path)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(session)
        } catch {
            throw IlinkFailure.sessionUnwritable(path: fileURL.path)
        }
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard manager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw IlinkFailure.sessionUnwritable(path: fileURL.path)
        }
        do {
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(
                    fileURL,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try manager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw IlinkFailure.sessionUnwritable(path: fileURL.path)
        }
    }

    public func discard() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return }
        do {
            try manager.removeItem(at: fileURL)
        } catch {
            throw IlinkFailure.sessionUnwritable(path: fileURL.path)
        }
    }
}
