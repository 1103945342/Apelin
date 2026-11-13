import ApelinCore
import Foundation

/// Where the browser stands: one canonical directory.
///
/// A location is always `realpath(3)`-resolved, its NUL checked first, so a
/// symbolic link is browsed as what it leads to and the path the page shows is
/// the path the file system will act on. A path that does not resolve is not a
/// location at all: the page says why, rather than opening an empty folder.
struct FileBrowserLocation: Hashable, Sendable {
    /// Canonical and absolute: no `.`, no `..`, no trailing slash but at `/`.
    let path: String

    /// nil for a NUL in the path, a relative path, or one that does not
    /// resolve — a name nothing exists at, or a link that leads nowhere.
    init?(path: String) {
        guard !CanonicalPath.containsNUL(path), path.hasPrefix("/"),
              let resolved = CanonicalPath.resolve(path)
        else { return nil }
        self.path = resolved
    }

    init?(url: URL) {
        self.init(path: url.path)
    }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// What the page calls it: the last component, or the root's own path.
    var title: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The folder above, nil at the top of the file system — which is where
    /// the page's Up stops.
    var parent: FileBrowserLocation? {
        guard path != "/" else { return nil }
        return FileBrowserLocation(path: (path as NSString).deletingLastPathComponent)
    }

    /// From the root down to itself: what the path menu lists.
    var ancestors: [FileBrowserLocation] {
        var trail: [FileBrowserLocation] = []
        var step: FileBrowserLocation? = self
        while let location = step {
            trail.append(location)
            step = location.parent
        }
        return trail.reversed()
    }
}

/// How the page got where it is: the place it shows, and the places it left.
struct FileBrowserNavigation: Equatable {
    private(set) var current: FileBrowserLocation
    /// Newest last: Back walks down it.
    private(set) var history: [FileBrowserLocation] = []
    /// Back keeps a run of places, not the whole session.
    private static let historyLimit = 50

    init(directory: FileBrowserLocation) {
        current = directory
    }

    var parent: FileBrowserLocation? { current.parent }

    var canGoBack: Bool { !history.isEmpty }

    /// Goes to `location`, remembering where it was. The place it is already
    /// at is no move, and leaves the trail alone.
    mutating func go(to location: FileBrowserLocation) {
        guard location != current else { return }
        history.append(current)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        current = location
    }

    /// The enclosing folder. False at the root, which is the answer that
    /// there is nothing above.
    @discardableResult
    mutating func goUp() -> Bool {
        guard let parent else { return false }
        go(to: parent)
        return true
    }

    /// Back where it came from — not `go`, which would build a trail of its
    /// own and turn Back into a toggle.
    @discardableResult
    mutating func goBack() -> Bool {
        guard let previous = history.popLast() else { return false }
        current = previous
        return true
    }
}
