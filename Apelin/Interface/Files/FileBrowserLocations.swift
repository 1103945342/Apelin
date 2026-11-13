import Foundation

/// One place the Locations menu offers.
struct FileBrowserPlace: Equatable {
    enum Name: Equatable {
        /// The project the browser was opened from, named by its folder.
        case project(String)
        case dataFolder
        case projects
        case home
        case documents
        case bootstrap
        case device
    }

    var name: Name
    var location: FileBrowserLocation
}

/// Where the page can go besides what it is showing: the app's own folders,
/// mobile's home, the bootstrap and the device.
///
/// Every path is worked out from what the running app already knows — the data
/// folder `DataFolder.app` makes, and its own bundle's path — and never from a
/// literal install prefix. On roothide the bootstrap root is the `.jbroot-…`
/// component of that path, read at run time because roothide renames it at
/// every jailbreak; on rootless the app is installed under the bootstrap's own
/// fixed `/var/jb`, and its bundle path is what says so. An app installed at
/// the top level has no bootstrap to show, and the menu shows none rather than
/// guessing at one.
enum FileBrowserLocations {
    /// The bootstrap's root, or nil when this app is not installed inside one.
    static func bootstrapRoot(bundlePath: String) -> String? {
        if let root = RoothideRoot.containing(bundlePath) { return root }
        // rootless keeps everything under this one prefix, and an app there
        // says so with its own path; one at `/Applications` answers none.
        let prefix = "/var/jb/"
        guard bundlePath.hasPrefix(prefix) else { return nil }
        return String(prefix.dropLast())
    }

    /// The places the menu lists, in its order: the project it was opened
    /// from, the app's folders, mobile's home, the bootstrap, the device. A
    /// place that is not there is left out rather than shown and failing.
    static func all(projectRoot: URL?, dataFolder: URL?, bundlePath: String) -> [FileBrowserPlace] {
        var places: [FileBrowserPlace] = []
        if let projectRoot, let location = FileBrowserLocation(url: projectRoot) {
            places.append(FileBrowserPlace(name: .project(location.title), location: location))
        }
        if let dataFolder, let location = FileBrowserLocation(url: dataFolder) {
            places.append(FileBrowserPlace(name: .dataFolder, location: location))
            let projects = dataFolder.appendingPathComponent("Projects", isDirectory: true)
            if let location = FileBrowserLocation(url: projects) {
                places.append(FileBrowserPlace(name: .projects, location: location))
            }
        }
        let home = URL(fileURLWithPath: RoothideRoot.mobileHome(for: bundlePath), isDirectory: true)
        if let location = FileBrowserLocation(url: home) {
            places.append(FileBrowserPlace(name: .home, location: location))
            let documents = home.appendingPathComponent("Documents", isDirectory: true)
            if let location = FileBrowserLocation(url: documents) {
                places.append(FileBrowserPlace(name: .documents, location: location))
            }
        }
        if let root = bootstrapRoot(bundlePath: bundlePath), let location = FileBrowserLocation(path: root) {
            places.append(FileBrowserPlace(name: .bootstrap, location: location))
        }
        if let location = FileBrowserLocation(path: "/") {
            places.append(FileBrowserPlace(name: .device, location: location))
        }
        return places
    }
}
