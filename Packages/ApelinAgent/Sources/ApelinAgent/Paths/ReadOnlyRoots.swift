import enum ApelinCore.CanonicalPath
import struct ApelinCore.DataFolder
import struct ApelinProject.ExtensionCatalog
import enum ApelinProtocol.AgentToolName
import Foundation

/// The folders outside the project the read tools reach too, and the write
/// tools never: Luros's development extensions, whose support folders hold
/// the headers and link stubs a template builds with (the Preferences
/// framework's among them), and the registered SDKs. Both are mobile's to
/// read: the extensions are the package's, the SDKs apelin-environment's.
///
/// Only an absolute path reaches one, and only when its realpath lies inside
/// the folder's; a relative path is always the project's, so a link in the
/// project that leads here is still outside it. Each folder is resolved
/// when a path is, since the SDKs folder appears with the first import.
struct ReadOnlyRoots: Sendable {
    /// The tools that read these folders as well as the project.
    static let tools: Set<AgentToolName> = [.fileRead, .fileList, .fileGrep, .fileFind]

    /// `<install root>/usr/share/luros/development`; nil without an
    /// install root.
    let developmentExtensions: String?
    /// The copy Luros's own package carries inside its app bundle, when it is
    /// there; nil without an install root or with the IDE installed without it.
    let bundledExtensions: String?
    /// The data folder's `SDKs`.
    let sdks: String?

    static let none = ReadOnlyRoots(developmentExtensions: nil, bundledExtensions: nil, sdks: nil)

    private init(developmentExtensions: String?, bundledExtensions: String?, sdks: String?) {
        self.developmentExtensions = developmentExtensions
        self.bundledExtensions = bundledExtensions
        self.sdks = sdks
    }

    /// The extensions under `installRoot`, when the session has one, the copy
    /// the package carries, and the data folder's SDKs.
    init(installRoot: String?, dataRoot: ApelinDataRoot) {
        developmentExtensions = installRoot.map { ExtensionCatalog.directory(installRoot: $0).path }
        bundledExtensions = installRoot
            .map { ExtensionCatalog.bundledDirectory(installRoot: $0).path }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        sdks = DataFolder(root: dataRoot.url).sdks.path
    }

    /// The folder an absolute `path` lies in, and the path it is shown
    /// under; nil for a relative path, one with a NUL, one that does not
    /// resolve, or one in neither folder.
    func root(containing path: String) -> (root: ScopedRoot, shownAs: String)? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), let real = CanonicalPath.resolve(trimmed) else { return nil }
        for folder in [developmentExtensions, bundledExtensions, sdks].compactMap(\.self) {
            guard let root = try? ScopedRoot(URL(fileURLWithPath: folder, isDirectory: true)) else { continue }
            if root.contains(real) {
                return (root, folder)
            }
        }
        return nil
    }

    /// Both folders, each named by what it holds, as one phrase; nil with
    /// neither.
    var described: String? {
        let named = [
            developmentExtensions.map { "Luros's development extensions (\($0))" },
            bundledExtensions.map { "the copy in Luros's app bundle (\($0))" },
            sdks.map { "the registered SDKs (\($0))" },
        ].compactMap(\.self)
        return named.isEmpty ? nil : named.joined(separator: " or ")
    }

    /// What a read tool's refusal adds: where else it reads. nil with
    /// neither folder.
    var refusalNote: String? {
        described.map { "the file tools also read, never write, an absolute path inside \($0)" }
    }
}
