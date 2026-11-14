import ApelinWeChat
import Foundation

/// The one session file: atomic, 0600, a round trip, and a broken file that is
/// reported and left as it is until it is explicitly discarded.
func checkIlinkSessionStore() throws {
    let folder = try makeTemporaryFolder("store")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("session.json")
    let store = IlinkFileSessionStore(fileURL: url)

    guard case .absent = try store.read() else {
        throw CheckFailure(message: "a store with no file must answer absent")
    }

    let session = IlinkSession(
        credentials: IlinkCredentials(
            botID: "bot-9",
            token: "secret-token",
            userID: "user-9",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        cursor: "cursor-1",
        contextTokens: ["peer-1": "peer-token"],
        baseURL: URL(string: "https://idc.weixin.qq.com"),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    try store.write(session)

    guard case .present(let readBack) = try store.read() else {
        throw CheckFailure(message: "a written session must read back")
    }
    try expectEqual(readBack, session, "the session round-trips")
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    try expectEqual(mode, 0o600, "the session file is readable by its owner alone")

    try expect(
        !String(describing: session).contains("secret-token"),
        "a session's description carries no token"
    )
    try expect(
        !String(describing: session.credentials).contains("secret-token"),
        "a credential's description carries no token"
    )

    let broken = Data("{ this is not a session".utf8)
    try broken.write(to: url)
    guard case .unreadable(let path, let reason) = try store.read() else {
        throw CheckFailure(message: "a file that does not decode must be unreadable")
    }
    try expectEqual(path, url.path, "the unreadable session names its path")
    try expect(!reason.isEmpty, "the unreadable session says why")
    let untouched = try Data(contentsOf: url)
    try expectEqual(untouched, broken, "a broken session file is never emptied or replaced")

    try store.discard()
    guard case .absent = try store.read() else {
        throw CheckFailure(message: "discard removes the file")
    }
    let leftovers = try FileManager.default
        .contentsOfDirectory(atPath: folder.path)
        .filter { $0.contains(".tmp") }
    try expect(leftovers.isEmpty, "no temporary file is left behind")
}
