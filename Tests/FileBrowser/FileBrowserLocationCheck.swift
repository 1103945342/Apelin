import ApelinCore
import Foundation

/// Every path the browser holds is canonical before anything is decided about
/// it, and the page's Up stops at the top of the file system rather than
/// climbing past it.
func checkFileBrowserLocation() throws {
    precondition(FileBrowserLocation(path: "/")?.path == "/", "the root is a location")
    precondition(FileBrowserLocation(path: "/private/../private/var")?.path == "/private/var", "a path is resolved")
    precondition(FileBrowserLocation(path: "relative/path") == nil, "a relative path is not a location")
    precondition(FileBrowserLocation(path: "/private/var/mo\0bile") == nil, "a NUL is refused before anything else")
    let missing = "/private/var/apelin-none-\(UUID().uuidString)"
    precondition(FileBrowserLocation(path: missing) == nil, "a name nothing is at is not a location")
    precondition(FileBrowserListing.openReason(for: URL(fileURLWithPath: missing)) == .missing)

    // `/var` is an alias of `/private/var`: two spellings of one place are one
    // location, compared by components and never by string prefix.
    let home = FileBrowserLocation(path: "/var/mobile")
    precondition(home?.title == "mobile")
    precondition(home?.parent?.path == "/private/var", "the parent is the resolved one")
    precondition(home?.ancestors.map(\.path) == ["/", "/private", "/private/var", "/private/var/mobile"])

    let root = FileBrowserLocation(path: "/")!
    precondition(root.parent == nil, "the top of the file system has nothing above it")
    precondition(root.title == "/")
    precondition(root.ancestors.map(\.path) == ["/"])

    var navigation = FileBrowserNavigation(directory: root)
    precondition(!navigation.goUp(), "Up at the root is refused")
    precondition(navigation.current == root, "and leaves the page where it is")
    guard let home else { preconditionFailure("the home exists") }
    navigation.go(to: home)
    precondition(navigation.canGoBack && navigation.history.map(\.path) == ["/"])
    precondition(navigation.goUp() && navigation.current.path == "/private/var", "Up is the enclosing folder")
    precondition(navigation.goBack() && navigation.current == home, "Back returns to the place it came from")
    let trail = navigation.history.count
    navigation.go(to: home)
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
