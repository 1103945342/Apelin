import Combine
import Foundation

/// What a conversation's project offers the composer's two menus: the file
/// paths behind an `@`, and the skills behind a `/`.
///
/// Read from disk on demand rather than kept current: a project changes
/// underneath the app when a build writes into it, and a list kept in step
/// would be wrong more often than it was right.
///
/// The file walk is bounded. A project with a `node_modules` or a build tree in
/// it holds more paths than a menu can mean anything with, and a reader typing
/// `@` wants the file they are thinking of, not a count.
enum ComposerProjectIndex {
    /// Paths a mention never offers: what no one refers to by hand, and what
    /// would bury everything else.
    private static let skippedDirectories: Set<String> = [
        ".git", ".build", "build", "Build", "node_modules", "Pods", "DerivedData",
        ".swiftpm", ".index-build", "vendor", "dist", "target", ".next"
    ]

    private static let fileLimit = 4000

    /// Every file under `root`, relative to it, in a stable order.
    static func files(in root: URL) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [String] = []
        let rootPath = root.standardizedFileURL.path
        for case let entry as URL in enumerator {
            if files.count >= fileLimit { break }
            let name = entry.lastPathComponent
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = entry.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard path.hasPrefix(prefix) else { continue }
            files.append(String(path.dropFirst(prefix.count)))
        }
        // Sorted here rather than by the walk, which follows the file system's
        // own order and would move rows around as files are written.
        return files.sorted()
    }
}
