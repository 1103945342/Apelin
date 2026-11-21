import LurosCore
import Foundation

/// Every path the browser holds is canonical before anything is decided about
/// it, and the page's Up stops at the top of the file system rather than
/// climbing past it.
func checkFileBrowserLocation() throws {
    precondition(FileBrowserLocation(path: "/")?.path == "/", "the root is a location")
    precondition(FileBrowserLocation(path: "/private/../private/var")?.path == "/private/var", "a path is resolved")
    precondition(FileBrowserLocation(path: "relative/path") == nil, "a relative path is not a location")
    precondition(FileBrowserLocation(path: "/private/var/mo\0bile") == nil, "a NUL is refused before anything else")
    let missing = "/private/var/luros-none-\(UUID().uuidString)"
    precondition(FileBrowserLocation(path: missing) == nil, "a name nothing is at is not a location")
    precondition(FileBrowserListing.openReason(for: URL(fileURLWithPath: missing)) == .missing)

    // `/var` is an alias of `/private/var` on the Mac the harness also runs
    // on, and a folder of its own on iOS: two spellings of one place are one
    // location when they resolve to the same path, compared by components and
    // never by string prefix. `/var/mobile` is the home on a device and does
    // not exist on the Mac, so what the home says is checked where it is.
    guard let varFolder = CanonicalPath.resolve("/var") else { preconditionFailure("/var resolves") }
    if let home = FileBrowserLocation(path: "/var/mobile") {
        precondition(home.title == "mobile")
        precondition(home.parent?.path == varFolder, "the parent is the resolved one")
        precondition(home.ancestors.first?.path == "/" && home.ancestors.last == home, "the trail runs from the root")
        precondition(home.ancestors.count == home.path.split(separator: "/").count + 1, "one step per folder")
    }

    let root = FileBrowserLocation(path: "/")!
    precondition(root.parent == nil, "the top of the file system has nothing above it")
    precondition(root.title == "/")
    precondition(root.ancestors.map(\.path) == ["/"])

    // Somewhere with something above it, on a device and on the Mac alike.
    let place = FileBrowserLocation(path: "/var/mobile")
        ?? FileBrowserLocation(path: NSTemporaryDirectory())!
    var navigation = FileBrowserNavigation(directory: root)
    precondition(!navigation.goUp(), "Up at the root is refused")
    precondition(navigation.current == root, "and leaves the page where it is")
    navigation.go(to: place)
    precondition(navigation.canGoBack && navigation.history.map(\.path) == ["/"])
    precondition(navigation.goUp() && navigation.current == place.parent, "Up is the enclosing folder")
    precondition(navigation.goBack() && navigation.current == place, "Back returns to the place it came from")
    let trail = navigation.history.count
    navigation.go(to: place)
    precondition(navigation.history.count == trail, "the place it is already at is no move")

    // A link is browsed as what it leads to, and a link that leads nowhere is
    // said to, not opened as an empty folder.
    let work = try temporaryFolder("location")
    defer { try? FileManager.default.removeItem(at: work) }
    let real = work.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let alias = work.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: real.path)
    precondition(FileBrowserLocation(url: alias)?.path == canonical(real.path), "a link is a location at its target")
    let dangling = work.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(
        atPath: dangling.path,
        withDestinationPath: work.appendingPathComponent("gone").path
    )
    precondition(FileBrowserLocation(url: dangling) == nil, "a broken link is not a location")
    precondition(FileBrowserListing.openReason(for: dangling) == .brokenLink)
    print("ok: locations are canonical, Up stops at the root, Back returns, and a link is what it leads to")
}
