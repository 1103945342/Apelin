import Foundation
import LurosCore
import LurosProtocol

/// Settings ▸ Storage, behind the wire: what each area of the data folder
/// costs, and the emptying of the folders no model indexes.
///
/// Every path is resolved and checked inside the data folder before anything
/// is read or removed, the folder itself must be spelled the way the area
/// names it (so a link planted in its place is refused rather than followed),
/// and a walk never follows a symbolic link. The folders holding a model —
/// `Projects`, `Chats`, `sessions`, `SDKs`, `Environment` — are measured here
/// and deleted by the app, one item at a time.
enum StorageKeeper {
    /// A build folder or a cache entry written this recently may still be in
    /// use: `BuildCleanup` keeps the same hour.
    static let recentBuildAge: TimeInterval = 60 * 60

    /// Everything one area costs, and its children's own sizes when asked.
    static func measure(
        _ area: StorageArea,
        data: DataFolder,
        children: Bool,
    ) -> StorageUsage {
        do {
            let folders = try roots(area, data: data)
            var bytes: Int64 = 0
            var files: Int64 = 0
            var entries: [StorageEntry]?
            for folder in folders {
                let walk = try walk(folder)
                bytes += walk.bytes
                files += walk.files
                guard children else { continue }
                entries = (entries ?? []) + (area == .chats ? try chatEntries(folder) : try childEntries(folder))
            }
            return StorageUsage(
                area: area,
                bytes: bytes,
                files: files,
                entries: entries?.sorted { $0.bytes > $1.bytes },
            )
        } catch {
            return StorageUsage(
                area: area,
                failure: (error as? LurosError)?.message ?? error.localizedDescription,
            )
        }
    }

    /// Empties one purgeable area and answers what it reclaimed. `now` is
    /// passed in so a test can decide what counts as recent.
    static func purge(
        _ area: StorageArea,
        data: DataFolder,
        now: Date = Date(),
    ) throws -> Int64 {
        guard area.isPurgeable else {
            throw LurosError(.badRequest, "\(area.rawValue) is not the host's to empty")
        }
        var reclaimed: Int64 = 0
        for folder in try roots(area, data: data) {
            var metadata = stat()
            guard lstat(folder.path, &metadata) == 0 else { continue }
            for child in try children(of: folder) {
                // A build still being written stays, and so does the cache
                // entry a running build reads.
                if area == .builds, !isStale(child.path, now: now) {
                    continue
                }
                let walk = cost(child)
                reclaimed += walk.bytes
                try FileManager.default.removeItem(at: child)
            }
            // `Builds/.build-cache/` holds one folder per project, each a
            // build's reusable units; they age the same way.
            if area == .builds {
                let cache = folder.appendingPathComponent(".build-cache", isDirectory: true)
                for project in try children(of: cache) where isStale(project.path, now: now) {
                    let walk = cost(project)
                    reclaimed += walk.bytes
                    try FileManager.default.removeItem(at: project)
                }
            }
            // A level nobody writes any more goes too, so an emptied area is
            // an absent folder rather than an empty one.
            if try children(of: folder).isEmpty {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        return reclaimed
    }

    /// The device's free and total space, as `statfs` on the data folder
    /// answers it.
    static func disk(at root: URL) -> StorageDisk? {
        var info = statfs()
        guard statfs(root.path, &info) == 0 else { return nil }
        let unit = Int64(info.f_bsize)
        return StorageDisk(
            available: Int64(info.f_bavail) * unit,
            total: Int64(info.f_blocks) * unit,
        )
    }

    /// Why an emptying is refused now: a build or an environment task writes
    /// into `Builds` and `Temporary`.
    static func busy(_ active: [String: Int]) -> LurosError? {
        let working = ["build", "environment"].filter { (active[$0] ?? 0) > 0 }
        guard working.isEmpty else {
            return LurosError(.conflict, "a \(working.joined(separator: " and a ")) task is running")
        }
        return nil
    }

    // MARK: Roots

    /// The folders one area is made of, each checked to be inside the data
    /// folder and spelled as this app spells it. A data folder that is not
    /// there yet has no areas.
    private static func roots(_ area: StorageArea, data: DataFolder) throws -> [URL] {
        var rootMetadata = stat()
        guard lstat(data.root.path, &rootMetadata) == 0 else {
            if errno == ENOENT { return [] }
            throw posix("read the data folder")
        }
        guard rootMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw LurosError(.denied, "the data folder is not a folder")
        }
        var names: [String]
        switch area {
        case .builds: names = ["Builds"]
        case .temporary: names = ["Temporary"]
        case .exports: names = ["Exports"]
        case .logs: names = ["Journal", "console/done", "console/out"]
        case .backups: names = ["backups"]
        case .projects: names = ["Projects"]
        case .chats: names = ["Chats"]
        case .sessions: names = ["sessions"]
        case .sdks: names = ["SDKs"]
        case .toolchains: names = ["Environment"]
        }
        let root = try checked(data.root, inside: data.root)
        return try names.map { name in
            let url = data.root.appendingPathComponent(name, isDirectory: true)
            var metadata = stat()
            if lstat(url.path, &metadata) != 0 {
                if errno == ENOENT { return url }
                throw posix("read \(name)")
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                throw LurosError(.denied, "\(name) is not a folder")
            }
            _ = try checked(url, inside: data.root)
            guard CanonicalPath.resolve(url.path) == root + "/" + name else {
                throw LurosError(.denied, "\(name) leads somewhere else")
            }
            return url
        }
    }

    /// The path as it really is, refused unless it is `root` itself or a
    /// folder directly below it — so a link naming another place does not
    /// become one.
    private static func checked(_ url: URL, inside root: URL) throws -> String {
        guard !url.path.contains("\0") else { throw LurosError(.badRequest, "the path is not text") }
        guard let rootPath = CanonicalPath.resolve(root.path),
              let path = CanonicalPath.resolve(url.path),
              CanonicalPath.isCanonical(path, inside: rootPath)
        else {
            throw LurosError(.denied, "the path leaves the data folder")
        }
        return path
    }

    // MARK: Walking

    private struct Walk {
        var bytes: Int64 = 0
        var files: Int64 = 0
    }

    /// A folder's cost: every regular file below it, `st_size` for `st_size`.
    /// A symbolic link is neither followed nor counted, and a device, FIFO
    /// or socket is passed over — they hold no bytes of their own.
    private static func walk(_ folder: URL) throws -> (bytes: Int64, files: Int64) {
        var walk = Walk()
        var pending: [String] = [folder.path]
        while let path = pending.popLast() {
            for child in try children(ofPath: path) {
                var metadata = stat()
                guard lstat(child, &metadata) == 0 else { continue }
                switch metadata.st_mode & S_IFMT {
                case S_IFDIR: pending.append(child)
                case S_IFREG:
                    walk.bytes += Int64(metadata.st_size)
                    walk.files += 1
                default: continue
                }
            }
        }
        return (walk.bytes, walk.files)
    }

    /// What one entry costs: a regular file its own size, a folder everything
    /// below it, anything else nothing.
    private static func cost(_ url: URL) -> (bytes: Int64, files: Int64) {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return (0, 0) }
        switch metadata.st_mode & S_IFMT {
        case S_IFREG: return (Int64(metadata.st_size), 1)
        case S_IFDIR: return (try? walk(url)) ?? (0, 0)
        default: return (0, 0)
        }
    }

    /// Each folder directly below `folder`, by its own size, largest first.
    private static func childEntries(_ folder: URL) throws -> [StorageEntry] {
        try children(of: folder).compactMap { child in
            var metadata = stat()
            guard lstat(child.path, &metadata) == 0 else { return nil }
            let walk = cost(child)
            return StorageEntry(
                name: child.lastPathComponent,
                bytes: walk.bytes,
                files: walk.files,
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Conversations, one entry per id: the record and its event log are one
    /// conversation, counted together.
    private static func chatEntries(_ folder: URL) throws -> [StorageEntry] {
        var sizes: [String: (bytes: Int64, files: Int64)] = [:]
        for child in try children(of: folder) {
            var metadata = stat()
            guard lstat(child.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { continue }
            let name = child.lastPathComponent
            let id = name.hasSuffix(".events.jsonl") ? String(name.dropLast(".events.jsonl".count)) : String(name.dropLast(".json".count))
            var size = sizes[id] ?? (0, 0)
            size.bytes += Int64(metadata.st_size)
            size.files += 1
            sizes[id] = size
        }
        return sizes.map { StorageEntry(name: $0.key, bytes: $0.value.bytes, files: $0.value.files) }
            .sorted { $0.bytes > $1.bytes }
    }

    private static func isStale(_ path: String, now: Date) -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return false }
        let written = Date(
            timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000,
        )
        return now.timeIntervalSince(written) >= recentBuildAge
    }

    // MARK: Directory listing

    private static func children(of folder: URL) throws -> [URL] {
        var metadata = stat()
        guard lstat(folder.path, &metadata) == 0 else { return [] }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw LurosError(.denied, "\(folder.lastPathComponent) is not a folder")
        }
        return try children(ofPath: folder.path).map { URL(fileURLWithPath: $0) }
    }

    /// The entries of one directory, by full path. Reading one that is gone
    /// or unreadable answers nothing rather than an error: a folder may be
    /// removed by the app while this walks it.
    private static func children(ofPath path: String) throws -> [String] {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return [] }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return names.filter { $0 != "." && $0 != ".." }.map { path + "/" + $0 }
    }

    private static func posix(_ action: String) -> LurosError {
        let code = errno
        return LurosError(.internal, "could not \(action): \(String(cString: strerror(code)))")
    }
}
