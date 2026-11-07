import ApelinProtocol
import Darwin
import Foundation

/// The `.app` an `.ipa` carries, read before any of it goes on the device:
/// the bundle ID the installation records, the folder name it gets under
/// `Applications`, the executable that has to be there, and the version the
/// installation list shows.
struct AppBundle: Sendable, Equatable {
    var bundleID: String
    /// The folder name, without `.app`: the bundle's own, made safe for a path.
    var name: String
    var executableName: String
    var version: String
    /// `…/Payload/<name>.app`, inside the folder the `.ipa` was unpacked into.
    var root: URL

    enum Failure: Error, Equatable, CustomStringConvertible {
        case noPayload
        case severalApps(Int)
        case unreadableInfoPlist(String)
        case missing(String)
        case invalidBundleID(String)
        case invalidName(String)

        var description: String {
            switch self {
            case .noPayload: "the .ipa holds no Payload folder"
            case let .severalApps(count): "the .ipa holds \(count) apps; it must hold one"
            case let .unreadableInfoPlist(app): "\(app)/Info.plist could not be read"
            case let .missing(what): "the app has no \(what)"
            case let .invalidBundleID(id): "\(id) is not a bundle ID"
            case let .invalidName(name): "\(name) cannot be a folder name for an app"
            }
        }
    }

    /// The one `Payload/*.app` in `directory`, as its `Info.plist` describes it.
    static func find(in directory: URL) throws -> AppBundle {
        let payload = directory.appendingPathComponent("Payload")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: payload.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.noPayload
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let apps = contents.filter { $0.pathExtension == "app" }
        guard !apps.isEmpty else { throw Failure.noPayload }
        guard apps.count == 1 else { throw Failure.severalApps(apps.count) }
        let root = apps[0]

        let info = root.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else {
            throw Failure.unreadableInfoPlist(root.deletingPathExtension().lastPathComponent)
        }
        guard let identifier = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespaces),
              isValidBundleID(identifier)
        else {
            throw Failure.invalidBundleID(plist["CFBundleIdentifier"] as? String ?? "")
        }
        guard let executable = (plist["CFBundleExecutable"] as? String)?.trimmingCharacters(in: .whitespaces),
              !executable.isEmpty, !executable.contains("/"), !executable.contains("\0")
        else {
            throw Failure.missing("CFBundleExecutable")
        }
        let binary = root.appendingPathComponent(executable)
        var metadata = stat()
        guard stat(binary.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw Failure.missing("executable \(executable)")
        }
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? ""
        let display = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
        let name = try folderName(display: display, root: root, identifier: identifier)
        return AppBundle(
            bundleID: identifier,
            name: name,
            executableName: executable,
            version: version.trimmingCharacters(in: .whitespaces),
            root: root
        )
    }

    /// What an app of this bundle is called on disk: its display name when
    /// that survives a path, the folder's own name when it does not.
    private static func folderName(display: String?, root: URL, identifier: String) throws -> String {
        let candidates = [display, root.deletingPathExtension().lastPathComponent, identifier.split(separator: ".").last.map(String.init)]
        for candidate in candidates.compactMap({ $0 }) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = String(trimmed.map { character in
                character.isLetter || character.isNumber || " ._-+".contains(character) ? character : "-"
            })
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            guard !safe.isEmpty, safe.count <= 64, !safe.hasPrefix(".") else { continue }
            return safe
        }
        throw Failure.invalidName(display ?? identifier)
    }

    private static func isValidBundleID(_ id: String) -> Bool {
        guard (2 ... 255).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
