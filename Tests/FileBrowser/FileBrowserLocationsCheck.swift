import ApelinCore
import Foundation

/// Where the Locations menu leads: the bootstrap root is read off the running
/// app's own bundle path — roothide's `.jbroot-…` piece, rootless's one fixed
/// prefix, and none at all for an app installed at the top level — so no
/// install root is ever written down and no `/var/jb` is guessed at.
func checkFileBrowserLocations() throws {
    precondition(FileBrowserLocations.bootstrapRoot(bundlePath: "/Applications/Apelin.app") == nil,
                 "an app at the top level has no bootstrap to show")
    precondition(FileBrowserLocations.bootstrapRoot(bundlePath: "/var/jb/Applications/Apelin.app") == "/var/jb",
                 "rootless keeps its one prefix, and the bundle's own path says so")
    let root = "/private/var/containers/Bundle/Application/.jbroot-0000000000000101"
    precondition(
        FileBrowserLocations.bootstrapRoot(bundlePath: root + "/Applications/Apelin.app") == root,
        "roothide's root is the piece of the bundle's own path"
    )
    // A name that is not a root — the checksum in it is wrong — is not one.
    precondition(
        FileBrowserLocations.bootstrapRoot(
            bundlePath: "/private/var/containers/Bundle/Application/.jbroot-0000000000000001/Applications/Apelin.app"
        ) == nil,
        "a name that is not a bootstrap root is not taken for one"
    )

    let work = try temporaryFolder("locations")
    defer { try? FileManager.default.removeItem(at: work) }
    let data = work.appendingPathComponent("Documents/wiki.qaq.apelin", isDirectory: true)
    let project = data.appendingPathComponent("Projects/Demo", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    let places = FileBrowserLocations.all(
        projectRoot: project,
        dataFolder: data,
        bundlePath: "/Applications/Apelin.app"
    )
    precondition(places.first?.name == .project("Demo"), "the project comes first: \(places.map(\.name))")
    precondition(places.contains { $0.name == .dataFolder })
    precondition(places.contains { $0.name == .projects })
    precondition(places.last?.name == .device, "the device is last")
    precondition(!places.contains { $0.name == .bootstrap }, "no bootstrap is offered for an app at the top level")
    precondition(
        places.allSatisfy { FileManager.default.fileExists(atPath: $0.location.path) },
        "every place offered is there: \(places.map(\.location.path))"
    )

    // A bootstrap install offers the root its own path names — the first one
    // such a path carries, which on a device whose temporary folder sits
    // inside a bootstrap is that one.
    let bootstrap = work.appendingPathComponent(".jbroot-0000000000000101", isDirectory: true)
    try FileManager.default.createDirectory(at: bootstrap, withIntermediateDirectories: true)
    let bundle = bootstrap.appendingPathComponent("Applications/Apelin.app").path
    guard let root = FileBrowserLocations.bootstrapRoot(bundlePath: bundle) else {
        preconditionFailure("a bundle inside a bootstrap names its root")
    }
    let inside = FileBrowserLocations.all(projectRoot: nil, dataFolder: data, bundlePath: bundle)
    precondition(
        inside.contains { $0.name == .bootstrap && $0.location.path == canonical(root) },
        "a bootstrap install offers its root: \(inside.map(\.location.path))"
    )
    print("ok: the bootstrap root is read from the bundle's own path, and the menu offers only places that are there")
}
