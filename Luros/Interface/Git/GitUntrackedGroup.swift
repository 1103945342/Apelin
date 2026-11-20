import ApelinProtocol
import Foundation

/// The untracked part of the status page, as the page groups it: a file at
/// the top of the tree stands on its own, and everything below one is listed
/// under the folder it first hangs in — the folder opens where it stands and
/// its files are read under it, one row each.
enum GitUntrackedGroup {
    /// A folder the group shows and the files it holds, by full path.
    struct Folder: Equatable {
        let path: String
        let children: [GitStatusEntry]
    }

    /// The files shown on their own, then the folders, each in path order
    /// with its children in path order too. A folder Git reports as one entry
    /// of its own is not among its children.
    static func split(_ entries: [GitStatusEntry]) -> (files: [GitStatusEntry], folders: [Folder]) {
        var files: [GitStatusEntry] = []
        var grouped: [String: [GitStatusEntry]] = [:]
        for entry in entries {
            let path = entry.path
            if path.hasSuffix("/") {
                grouped[path, default: []].append(entry)
                continue
            }
            if let slash = path.firstIndex(of: "/") {
                grouped[String(path[..<slash]) + "/", default: []].append(entry)
            } else {
                files.append(entry)
            }
        }
        let folders = grouped.keys.sorted().map { path in
            Folder(
                path: path,
                children: (grouped[path] ?? []).filter { $0.path != path }.sorted { $0.path < $1.path },
            )
        }
        return (files, folders)
    }

    /// What the group header counts: the files, not the folders holding them,
    /// so a folder of three new files is three things to commit. A folder Git
    /// named as one entry counts once, since that is all it told us.
    static func fileCount(_ entries: [GitStatusEntry]) -> Int {
        let (files, folders) = split(entries)
        return files.count + folders.reduce(0) { $0 + max(1, $1.children.count) }
    }

    /// The part of a file's folder that is left once the folder it is listed
    /// under is dropped: "Sources/Sub" under "Sources/" reads as "Sub".
    static func shownFolder(of path: String, under base: String?) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        guard let base, !base.isEmpty else { return folder }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        if folder == root { return "" }
        guard folder.hasPrefix(root + "/") else { return folder }
        return String(folder.dropFirst(root.count + 1))
    }
}
