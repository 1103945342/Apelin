import ApelinCore
import ApelinProject
import ArchiveKit
import Foundation

/// What an app project's build hands back when the description asks for an
/// `.ipa`: the `.app` the build produced, inside `Payload/`, zipped — the
/// bytes the build signed, unchanged, for a signing tool of one's own to
/// sign for a certificate of its own — and `apelin_package_install` installs
/// on this device as an app (`InstallBridge`, ApplicationInstall), never
/// through a package manager.
///
/// An app carries its extensions: each `appex` product the build made goes
/// in at `Payload/<app>.app/PlugIns/<name>.appex`, the one place iOS looks
/// for a widget, a share sheet or any other extension of the app.
///
/// The members are sorted by name and carry the build's start as their
/// time, so two builds of the same bytes write the same archive.
public struct IPAPackager: Sendable {
    public var inputs: BuildInputs
    public var products: BuildProducts

    public init(inputs: BuildInputs, products: BuildProducts) {
        self.inputs = inputs
        self.products = products
    }

    /// The one app product the payload holds.
    static func app(in products: BuildProducts) throws -> BuildProducts.Product {
        let apps = products.products.filter { $0.type == .app }
        guard apps.count == 1 else {
            throw BuildFailure("an .ipa carries exactly one app product, and the build made \(apps.count)")
        }
        return apps[0]
    }

    /// The bundle's name in `Payload/`, e.g. `My App.app`.
    static func bundleName(of app: BuildProducts.Product) throws -> String {
        let name = (app.path as NSString).lastPathComponent
        guard name.hasSuffix(".app"), name.count > 4, !CanonicalPath.containsNUL(name) else {
            throw BuildFailure("\(app.path) is not an .app bundle")
        }
        return name
    }

    /// An extension the app carries: the directory the build made it in, and
    /// where it goes inside the app, e.g. `PlugIns/MyWidgets.appex`.
    struct Embedded: Sendable {
        var directory: String
        var name: String
    }

    /// The `appex` products, each checked to be something iOS will load as
    /// this app's extension: a `<name>.appex` directory whose Info.plist
    /// names an executable it holds, an identifier under the app's own, and
    /// the extension point it plugs into.
    static func embedded(in products: BuildProducts, app: BuildProducts.Product) throws -> [Embedded] {
        let appIdentifier = identifier(ofDirectory: app.path)
        var embedded: [Embedded] = []
        var names: Set<String> = []
        for product in products.products where product.type == .appex {
            let name = (product.path as NSString).lastPathComponent
            guard name.hasSuffix(".appex"), name.count > 6, !CanonicalPath.containsNUL(name) else {
                throw BuildFailure("\(product.path) is not an .appex bundle")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: product.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw BuildFailure("\(product.path) is not a directory; the extension was not built")
            }
            guard names.insert(name).inserted else {
                throw BuildFailure("an .ipa holds one \(name), and two extension products are named it")
            }
            try checkExtension(at: product.path, name: name, appIdentifier: appIdentifier)
            embedded.append(Embedded(directory: product.path, name: "PlugIns/" + name))
        }
        return embedded
    }

    /// What makes a directory an extension of the app rather than something
    /// dropped in it: the bundle's own Info.plist and the executable it
    /// names, an identifier the app hosts, and the point it plugs into.
    private static func checkExtension(at path: String, name: String, appIdentifier: String?) throws {
        guard let info = infoPlist(ofDirectory: path) else {
            throw BuildFailure("\(name) has no Info.plist that reads as a dictionary")
        }
        guard let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              !executable.contains("/"),
              FileManager.default.fileExists(atPath: path + "/" + executable)
        else {
            throw BuildFailure("\(name)'s Info.plist names no CFBundleExecutable it holds")
        }
        guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw BuildFailure("\(name)'s Info.plist has no CFBundleIdentifier")
        }
        if let appIdentifier, identifier != appIdentifier, !identifier.hasPrefix(appIdentifier + ".") {
            throw BuildFailure("\(name) is \(identifier), which is not under the app's \(appIdentifier); iOS refuses one outside it")
        }
        guard let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
              !point.isEmpty
        else {
            throw BuildFailure("\(name)'s Info.plist has no NSExtension.NSExtensionPointIdentifier")
        }
    }

    /// A bundle's Info.plist as a dictionary, or nil when it does not read.
    private static func infoPlist(ofDirectory path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path + "/Info.plist") else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func identifier(ofDirectory path: String) -> String? {
        guard let identifier = infoPlist(ofDirectory: path)?["CFBundleIdentifier"] as? String,
              !identifier.isEmpty
        else { return nil }
        return identifier
    }

    public func write() throws -> Packager.Output {
        let app = try Self.app(in: products)
        let bundle = try Self.bundleName(of: app)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BuildFailure("\(app.path) is not a directory; the app was not built")
        }
        let embedded = try Self.embedded(in: products, app: app)

        let destination = inputs.workDirectory
            .appendingPathComponent("\(inputs.project.package.id)_\(inputs.project.package.version).ipa")
            .path
        try ZipWriter.write(
            directory: app.path,
            as: "Payload/" + bundle,
            additions: embedded.map {
                ZipWriter.Addition(directory: $0.directory, name: "Payload/" + bundle + "/" + $0.name)
            },
            to: destination,
            modificationTime: inputs.timestamp,
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: destination))
        try Self.verify(path: destination, bundle: bundle)
        return Packager.Output(
            path: destination,
            digest: CanonicalJSON.sha256Tag(data),
            byteCount: Int64(data.count),
            loadCheck: nil,
        )
    }

    /// Reads the archive back and insists it is an ipa of `bundle`: every
    /// member inside `Payload/<bundle>/`, an `Info.plist` among them, and
    /// nothing absolute or leading outside. Answers how many files it holds.
    @discardableResult
    public static func verify(path: String, bundle: String) throws -> Int {
        let entries = names(of: path)
        guard !entries.isEmpty else { throw BuildFailure("\(path) does not read as a zip") }
        return try check(entries, bundle: bundle)
    }

    /// Insists `entries` is an ipa of `bundle`: every member inside
    /// `Payload/<bundle>/`, an `Info.plist` among them, each
    /// `PlugIns/<name>.appex` with one of its own, and nothing absolute or
    /// leading outside. Answers how many files it holds.
    public static func check(_ entries: [String], bundle: String) throws -> Int {
        let root = "Payload/" + bundle
        let plugins = root + "/PlugIns/"
        var files = 0
        var infoPlist = false
        var extensions: Set<String> = []
        var extensionPlists: Set<String> = []
        // A folder the app has no file for — `PlugIns/`, and the extension
        // inside it — is written as its own member, without the trailing
        // slash the members below it carry. An entry something else sits
        // under is that folder, never a file.
        var folders: Set<String> = []
        for entry in entries {
            var parent = entry
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                folders.insert(parent)
            }
        }
        for entry in entries {
            guard !entry.isEmpty, !CanonicalPath.containsNUL(entry), !entry.hasPrefix("/") else {
                throw BuildFailure("the .ipa holds an absolute or empty path")
            }
            guard !CanonicalPath.components(entry).contains("..") else {
                throw BuildFailure("the .ipa holds \(entry), which leads outside it")
            }
            if entry == "Payload/" || entry == root || entry == root + "/" {
                continue
            }
            guard entry.hasPrefix(root + "/") else {
                throw BuildFailure("the .ipa holds \(entry), outside \(root)/")
            }
            if !entry.hasSuffix("/"), !folders.contains(entry) {
                files += 1
            }
            if entry == root + "/Info.plist" {
                infoPlist = true
            }
            if entry.hasPrefix(plugins) {
                let rest = entry.dropFirst(plugins.count)
                if let slash = rest.firstIndex(of: "/") {
                    let directory = String(rest[..<slash])
                    let below = rest[rest.index(after: slash)...]
                    if directory.hasSuffix(".appex"), directory.count > 6 {
                        extensions.insert(directory)
                        if below == "Info.plist" {
                            extensionPlists.insert(directory)
                        }
                    }
                }
            }
        }
        guard infoPlist else { throw BuildFailure("the .ipa has no \(root)/Info.plist") }
        for directory in extensions.sorted() where !extensionPlists.contains(directory) {
            throw BuildFailure("the .ipa's PlugIns/\(directory) has no Info.plist")
        }
        guard files > 0 else { throw BuildFailure("the .ipa holds no files") }
        return files
    }

    /// Every member's name, in the archive's order; empty when it does not
    /// read at all.
    public static func names(of path: String) -> [String] {
        entries(of: path).map(\.name)
    }

    /// The mode each member was written with, by name: an executable keeps the
    /// one the build signed it with, which is how iOS tells the two apart.
    public static func modes(of path: String) -> [String: UInt16] {
        var modes: [String: UInt16] = [:]
        for entry in entries(of: path) {
            modes[entry.name] = entry.mode
        }
        return modes
    }

    private static func entries(of path: String) -> [(name: String, mode: UInt16)] {
        guard let archive = archive_read_new() else { return [] }
        defer { _ = archive_read_free(archive) }
        guard archive_read_support_format_zip(archive) == ARCHIVE_OK,
              archive_read_support_filter_all(archive) == ARCHIVE_OK,
              archive_read_open_filename(archive, path, 1 << 16) == ARCHIVE_OK
        else { return [] }
        var entries: [(name: String, mode: UInt16)] = []
        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF {
                break
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else { break }
            let name = archive_entry_pathname_utf8(entry).map { String(cString: $0) }
                ?? archive_entry_pathname(entry).map { String(cString: $0) }
            if let name {
                entries.append((name: name, mode: UInt16(truncatingIfNeeded: archive_entry_perm(entry))))
            }
        }
        _ = archive_read_close(archive)
        return entries
    }
}

/// Writes a directory into a zip with libarchive.
enum ZipWriter {
    /// One more directory to write in, under a member path of its own: an
    /// app's extension, whose files belong inside the app's directory in the
    /// archive but not in the app on disk.
    struct Addition: Sendable {
        var directory: String
        /// The member path the directory takes, e.g.
        /// `Payload/Hello.app/PlugIns/HelloWidgets.appex`.
        var name: String
    }

    static func write(
        directory: String,
        as rootName: String,
        additions: [Addition] = [],
        to destination: String,
        modificationTime: Int64,
    ) throws {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        var sources: [(root: URL, name: String)] = [(root: root, name: rootName)]
        for addition in additions {
            sources.append((root: URL(fileURLWithPath: addition.directory, isDirectory: true), name: addition.name))
        }
        var directories: [String] = [rootName]
        var membersToWrite: [(name: String, path: String)] = []
        for source in sources {
            let prefix = source.root.path.hasSuffix("/") ? source.root.path : source.root.path + "/"
            for path in try members(of: source.root) {
                guard path.hasPrefix(prefix) else { throw BuildFailure("\(path) is outside \(source.root.path)") }
                membersToWrite.append((source.name + "/" + String(path.dropFirst(prefix.count)), path))
            }
            // The folders an addition lives in, which the app on disk has no
            // file for: `PlugIns/`, below the member the app itself is.
            var parent = (source.name as NSString).deletingLastPathComponent
            while parent.count > rootName.count, !directories.contains(parent) {
                directories.append(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }

        // A folder the app has on disk is written by the walk below, with
        // the trailing slash a folder carries; a folder only the additions
        // need — `PlugIns/` — is written here, before the members inside it.
        let walked = Set(membersToWrite.map(\.name))
        directories = directories.filter { !walked.contains($0) }.sorted()

        guard let archive = archive_write_new() else { throw BuildFailure("libarchive: cannot write a zip") }
        defer { _ = archive_write_free(archive) }
        try status(archive_write_set_format_zip(archive), archive, "set the zip format")
        // A warning here leaves every member stored, which is a valid zip too.
        _ = archive_write_set_options(archive, "zip:compression=deflate")
        try status(archive_write_open_filename(archive, destination), archive, "open \(destination)")

        for name in directories {
            try addRoot(at: name, to: archive, modificationTime: modificationTime)
        }
        for member in membersToWrite.sorted(by: { $0.name < $1.name }) {
            try add(member.path, as: member.name, to: archive, modificationTime: modificationTime)
        }
        try status(archive_write_close(archive), archive, "finish \(destination)")
    }

    /// Every path below `root`, sorted, folders before anything inside them.
    private static func members(of root: URL) throws -> [String] {
        var found: [String] = []
        var pending = [root]
        while let current = pending.popLast() {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: current.path).sorted()
            } catch {
                throw BuildFailure("cannot read \(current.path): \(error.localizedDescription)")
            }
            for name in names {
                let url = current.appendingPathComponent(name)
                found.append(url.path)
                var metadata = stat()
                if lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR {
                    pending.append(url)
                }
            }
        }
        return found.sorted()
    }

    private static func addRoot(at name: String, to archive: OpaquePointer, modificationTime: Int64) throws {
        guard let entry = archive_entry_new() else { throw BuildFailure("libarchive: no memory for an entry") }
        defer { _ = archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_filetype(entry, numericCast(S_IFDIR))
        archive_entry_set_perm(entry, numericCast(0o755))
        archive_entry_set_size(entry, 0)
        archive_entry_set_mtime(entry, Int(modificationTime), 0)
        try status(archive_write_header(archive, entry), archive, "add \(name)")
    }

    private static func add(_ path: String, as name: String, to archive: OpaquePointer, modificationTime: Int64) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw BuildFailure("cannot read \(path): \(String(cString: strerror(errno)))")
        }
        guard let entry = archive_entry_new() else { throw BuildFailure("libarchive: no memory for an entry") }
        defer { _ = archive_entry_free(entry) }
        archive_entry_set_mtime(entry, Int(modificationTime), 0)

        switch metadata.st_mode & S_IFMT {
        case S_IFDIR:
            archive_entry_set_pathname_utf8(entry, name + "/")
            archive_entry_set_filetype(entry, numericCast(S_IFDIR))
            archive_entry_set_perm(entry, numericCast(0o755))
            archive_entry_set_size(entry, 0)
            try status(archive_write_header(archive, entry), archive, "add \(name)")
        case S_IFLNK:
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            guard readlink(path, &target, Int(PATH_MAX)) > 0 else {
                throw BuildFailure("cannot read the link \(path): \(String(cString: strerror(errno)))")
            }
            archive_entry_set_pathname_utf8(entry, name)
            archive_entry_set_filetype(entry, numericCast(S_IFLNK))
            archive_entry_set_perm(entry, numericCast(0o755))
            archive_entry_set_size(entry, 0)
            archive_entry_set_symlink(entry, target)
            try status(archive_write_header(archive, entry), archive, "add \(name)")
        case S_IFREG:
            let executable = metadata.st_mode & 0o111 != 0
            archive_entry_set_pathname_utf8(entry, name)
            archive_entry_set_filetype(entry, numericCast(S_IFREG))
            archive_entry_set_perm(entry, numericCast(executable ? UInt16(0o755) : UInt16(0o644)))
            archive_entry_set_size(entry, Int64(metadata.st_size))
            try status(archive_write_header(archive, entry), archive, "add \(name)")
            try stream(path, into: archive, expected: Int64(metadata.st_size), name: name)
        default:
            throw BuildFailure("\(path) is a device, FIFO or socket; an .ipa holds files, folders and links")
        }
    }

    private static func stream(_ path: String, into archive: OpaquePointer, expected: Int64, name: String) throws {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw BuildFailure("cannot read \(path): \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        var written: Int64 = 0
        while true {
            let read = Darwin.read(descriptor, buffer, 1 << 20)
            if read == 0 {
                break
            }
            guard read > 0 else { throw BuildFailure("cannot read \(path): \(String(cString: strerror(errno)))") }
            var offset = 0
            while offset < read {
                let wrote = archive_write_data(archive, buffer + offset, read - offset)
                guard wrote > 0 else {
                    let message = archive_error_string(archive).map { String(cString: $0) } ?? "libarchive error"
                    throw BuildFailure("cannot write \(name): \(message)")
                }
                offset += wrote
            }
            written += Int64(read)
        }
        guard written == expected else {
            throw BuildFailure("\(path) changed size while it was packaged")
        }
    }

    private static func status(_ status: Int32, _ archive: OpaquePointer, _ what: String) throws {
        guard status == ARCHIVE_OK else {
            let message = archive_error_string(archive).map { String(cString: $0) } ?? "libarchive error"
            throw BuildFailure("cannot \(what): \(message)")
        }
    }
}
