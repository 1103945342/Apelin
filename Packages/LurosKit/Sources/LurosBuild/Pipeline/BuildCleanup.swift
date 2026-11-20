import Foundation

/// Keeps a project's build directories from becoming the app's largest
/// tenant.
///
/// Each build leaves its own folder under `Builds/<projectID>/`: the module
/// objects, the linked slices, the `.app` and its dSYM, the package — about
/// 94 MB for a Swift app. Nothing removed them, so sixty-five builds of one
/// project came to six gigabytes. Nothing reads an old folder either: a build
/// wipes its own work directory before it starts, and the compiled code a
/// later build does read lives in `Builds/.build-cache/`, not here.
///
/// What an old folder is still good for is the package it holds — installing
/// it, publishing it — and the dSYM a crash of that installed build is read
/// with. So the newest few stay, and the rest go when the next build starts.
enum BuildCleanup {
    /// How many folders stay beside the one the build is about to make: the
    /// last two. [The newest is the package most likely installed, the one
    /// behind it keeps a single failed build from pushing that package out.]
    static let keep = 2

    /// A folder written this recently may belong to a build running in
    /// another worker: it is never removed, however old it otherwise looks.
    static let grace: TimeInterval = 3600

    /// Removes this project's build folders beyond the newest `keep`, and any
    /// that are older than the grace period. `buildID` is the build that is
    /// starting, which is never removed. One line is logged when anything
    /// went.
    static func prune(
        projectID: String,
        keeping buildID: String,
        in builds: URL,
        log: (String) -> Void,
    ) {
        let project = builds.appendingPathComponent(projectID, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: project,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [],
        ) else {
            return
        }
        var candidates: [(url: URL, modified: Date)] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != buildID, !name.hasPrefix(".") else { continue }
            var info = stat()
            guard lstat(entry.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            candidates.append((entry, modified))
        }
        candidates.sort { $0.modified > $1.modified }
        let now = Date()
        var removed = 0
        var bytes: Int64 = 0
        for (index, entry) in candidates.enumerated() where index >= Self.keep {
            guard now.timeIntervalSince(entry.modified) > Self.grace else { continue }
            let size = Self.size(of: entry.url)
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            removed += 1
            bytes += size
        }
        guard removed > 0 else { return }
        let figure = bytes >= 1_048_576
            ? "\(bytes / 1_048_576) MB"
            : "\(bytes / 1_024) KB"
        log("removed \(removed) old build\(removed == 1 ? "" : "s"), \(figure)")
    }

    /// The bytes a folder holds, for the line the removal writes. A folder
    /// that does not read counts as nothing: it is being removed anyway.
    private static func size(of directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(atPath: directory.path) else { return 0 }
        var total: Int64 = 0
        for case let relative as String in walker {
            var info = stat()
            guard lstat(directory.path + "/" + relative, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG
            else {
                continue
            }
            total += Int64(info.st_size)
        }
        return total
    }
}
