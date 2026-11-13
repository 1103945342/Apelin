import ApelinCore
import Darwin
import Foundation

/// What the browser may do with one place, decided from where the path really
/// leads — a symbolic link is judged by its target, never by the name it sits
/// under.
enum FileBrowserAccess: Equatable {
    /// Ordinary file management: make, rename, copy, paste, delete, edit.
    case writable
    /// Readable, and nothing more.
    case readOnly(FileBrowserReadOnly)
    /// One of Apelin's own records: reading is the point, and its changes
    /// belong to the page that manages it.
    case record(FileBrowserProtectedRecord)

    var isWritable: Bool { self == .writable }

    /// What the page says about this place, nil when it may be changed.
    var refusal: String? {
        switch self {
        case .writable: return nil
        case let .readOnly(reason): return reason.sentence
        case let .record(record): return record.sentence
        }
    }
}

/// Why a place takes no change from this app.
enum FileBrowserReadOnly: Equatable {
    /// The file system refuses: the volume is read-only or mobile's
    /// permissions do not allow it. Asked of the place itself, never guessed
    /// from its name.
    case denied
    /// A symbolic link whose target does not resolve: there is nothing to
    /// change there, and what it pointed at is gone.
    case brokenLink

    var sentence: String {
        switch self {
        case .denied: return String(localized: "This place is read-only for Apelin.")
        case .brokenLink: return String(localized: "This link leads nowhere.")
        }
    }
}

/// Apelin's own records, grouped by the page that changes them.
///
/// Reading one is the point — knowing where a toolchain or an SDK sits is why
/// a file browser is here at all. Making, renaming and deleting them belongs to
/// the page that manages them, so the browser refuses it and says where to go
/// instead.
enum FileBrowserProtectedRecord: Equatable {
    /// The data folder itself, and every folder above it.
    case dataFolder
    /// `Projects/` and each project folder in it.
    case projects
    /// A project's description, `apelin-project.json`.
    case projectManifest
    /// `SDKs/`.
    case sdks
    /// `Environment/Toolchains/`, and the toolchains installed in the
    /// bootstrap, where the payload really lives.
    case toolchains
    /// `Environment/`, and the `inbox` the environment tasks stage into.
    case environment
    /// Apelin's own installed parts: the extensions and agent tools under
    /// `usr/share/apelin`, the runtime under `usr/libexec/apelin`.
    case applicationPayload
    case chats
    case sessions
    /// `Terminals/`, where the terminal keeps the reader's session list.
    case terminals
    case journal
    case builds
    case skills
    case console
    case backups
    case modelData
    case exports
    case temporary

    /// What the page shows in place of a file browser's actions.
    var sentence: String {
        switch self {
        case .dataFolder: return String(localized: "This is Apelin’s data folder; the app keeps its records here.")
        case .projects: return String(localized: "Projects are made, renamed and deleted in Projects.")
        case .projectManifest: return String(localized: "This project’s description is managed by Projects, and is read-only here.")
        case .sdks: return String(localized: "SDKs are managed in Settings ▸ SDKs.")
        case .toolchains: return String(localized: "Toolchains are managed in Settings ▸ Toolchains.")
        case .environment: return String(localized: "The environment’s records are managed in Settings ▸ Toolchains.")
        case .applicationPayload: return String(localized: "This is part of Apelin itself; it is installed and removed with the app.")
        case .chats: return String(localized: "Conversations are managed in their own chats.")
        case .sessions: return String(localized: "Session records are kept by the agent host.")
        case .terminals: return String(localized: "Terminal sessions are listed in the terminal; the app keeps this record.")
        case .journal: return String(localized: "This is Apelin’s own journal.")
        case .builds: return String(localized: "Builds are managed on the project’s Distribute page.")
        case .skills: return String(localized: "Skills are managed in Settings ▸ Skills.")
        case .console: return String(localized: "Console scripts are run and removed by the console.")
        case .backups: return String(localized: "Backups are kept by the app and are not edited here.")
        case .modelData: return String(localized: "The model data is refreshed by the app.")
        case .exports: return String(localized: "Exports are written by the app to be shared.")
        case .temporary: return String(localized: "Chat workspaces live here; each is made and removed with its conversation.")
        }
    }
}

/// A root whose contents are a record: what is at or below it, and what holds
/// it, is not the browser's to change.
struct FileBrowserRoot: Equatable {
    /// Canonical, and there when the policy was made.
    var path: String
    var record: FileBrowserProtectedRecord
}

/// Where a browser may write, worked out from paths the app already resolved —
/// `DataFolder.app`, and the bootstrap root the running app's own path names —
/// and never from a name typed here.
///
/// Browsing is a different question from changing, and it stays open: every
/// folder mobile can read is listed, inside the project and outside it. What
/// this decides is only which changes the page offers.
struct FileBrowserPolicy: Equatable {
    /// A project's description, at the root of every project folder.
    static let projectManifestName = "apelin-project.json"

    /// `~/Documents/wiki.qaq.apelin`, as `DataFolder.app` answers it.
    let dataFolder: URL?
    /// `Projects/` inside it.
    let projects: URL?
    /// The records installed in the bootstrap: the toolchains the app builds
    /// with, and the app's own payload.
    let payloadRoots: [FileBrowserRoot]
    /// Every root a change must keep out of, the data folder first.
    let roots: [FileBrowserRoot]

    /// `bootstrapRoot` is the install root as the running app's own bundle path
    /// answers it (`FileBrowserLocations.bootstrapRoot`); a root that is not
    /// there adds nothing, so a device without that layout is not protected
    /// against a folder it does not have.
    init(dataFolder: URL?, bootstrapRoot: String? = nil) {
        let root = dataFolder.flatMap {
            URL(fileURLWithPath: CanonicalPath.resolve($0.path) ?? $0.path, isDirectory: true)
        }
        self.dataFolder = root
        let projectsURL = root?.appendingPathComponent("Projects", isDirectory: true)
        projects = projectsURL.flatMap {
            URL(fileURLWithPath: CanonicalPath.resolve($0.path) ?? $0.path, isDirectory: true)
        }
        let payload = Self.installedRoots(bootstrapRoot: bootstrapRoot)
        payloadRoots = payload
        var roots: [FileBrowserRoot] = []
        if let path = root?.path {
            roots.append(FileBrowserRoot(path: path, record: .dataFolder))
        }
        if let path = projects?.path {
            roots.append(FileBrowserRoot(path: path, record: .projects))
        }
        roots.append(contentsOf: payload)
        self.roots = roots
    }

    /// The folders Apelin installed inside the bootstrap, each named by the
    /// page that manages it. Read at run time off the root the app's own path
    /// carries: the toolchains' payload is under `usr/lib/apelin/toolchains`
    /// (the catalog under the data folder is only the record), and the app's
    /// own parts under `usr/share/apelin` and `usr/libexec/apelin`.
    private static func installedRoots(bootstrapRoot: String?) -> [FileBrowserRoot] {
        guard let bootstrapRoot else { return [] }
        let spelled = [
            (bootstrapRoot + "/usr/lib/apelin/toolchains", FileBrowserProtectedRecord.toolchains),
            (bootstrapRoot + "/usr/share/apelin", .applicationPayload),
            (bootstrapRoot + "/usr/libexec/apelin", .applicationPayload)
        ]
        return spelled.compactMap { path, record in
            var metadata = stat()
            guard lstat(path, &metadata) == 0, let resolved = CanonicalPath.resolve(path) else { return nil }
            return FileBrowserRoot(path: resolved, record: record)
        }
    }

    // MARK: - Records

    /// The folder names under the data folder that only the app changes. A
    /// name not listed here is an ordinary folder: nothing is protected by
    /// being new.
    private static let recordFolders: [String: FileBrowserProtectedRecord] = [
        "Chats": .chats,
        "sessions": .sessions,
        "Terminals": .terminals,
        "Journal": .journal,
        "Builds": .builds,
        "skills": .skills,
        "console": .console,
        "backups": .backups,
        "ModelData": .modelData,
        "Exports": .exports,
        "Temporary": .temporary,
        "inbox": .environment,
        "Environment": .environment,
        "SDKs": .sdks,
        "Projects": .projects
    ]

    /// The record a canonical path belongs to, nil for an ordinary place.
    ///
    /// `Projects/` and the project folders in it are the projects page's; what
    /// a project holds — its sources, its own folders, its manifest's contents
    /// — is the project's own and stays open to the editor as it always was.
    func record(for path: String) -> FileBrowserProtectedRecord? {
        record(for: path, protectingIdentities: true)
    }

    /// The same rule, asked of a folder that something would be made in. A
    /// project folder, and a conversation's workspace, are the app's to rename
    /// and to delete, and the reader's to put files in: what they hold is the
    /// reader's own.
    private func dataRecord(
        for path: String,
        protectingIdentities: Bool
    ) -> FileBrowserProtectedRecord? {
        guard let dataRoot = dataFolder?.path,
              CanonicalPath.isCanonical(path, inside: dataRoot)
        else { return nil }
        if path == dataRoot { return .dataFolder }
        let rootDepth = CanonicalPath.components(dataRoot).count
        let parts = CanonicalPath.components(path)
        guard parts.count > rootDepth else { return .dataFolder }
        guard var record = Self.recordFolders[String(parts[rootDepth])] else { return nil }
        let depth = parts.count - rootDepth
        if record == .projects {
            // `Projects/` is one level down and each project folder two;
            // below them is the project itself, which is the reader's.
            let limit = protectingIdentities ? 2 : 1
            return depth <= limit ? .projects : nil
        }
        if record == .temporary {
            // One workspace per General Chat conversation: `Temporary/` and
            // each `Temporary/<conversationID>` are the app's to make and
            // remove, and what a workspace holds is the reader's own.
            let limit = protectingIdentities ? 2 : 1
            return depth <= limit ? .temporary : nil
        }
        if record == .environment, depth >= 2, String(parts[rootDepth + 1]) == "Toolchains" {
            record = .toolchains
        }
        return record
    }

    /// A folder that holds a root holds everything under it: deleting or moving
    /// the folder above an SDK, a toolchain or the data folder takes the
    /// records with it, so that folder is a change the browser does not make.
    /// Creating inside it is a different question and stays open.
    private func ancestorRecord(of path: String) -> FileBrowserProtectedRecord? {
        for root in roots where root.path != path && CanonicalPath.isCanonical(root.path, inside: path) {
            return root.record
        }
        return nil
    }

    // MARK: - What may change

    /// May this entry be renamed, moved out or deleted?
    ///
    /// Judged on where it actually is: a link in a project that points at a
    /// toolchain record is the record. A link that leads nowhere is still a
    /// name in its folder — removing or renaming it takes nothing else with it
    /// — while nothing may be written through it.
    func access(to url: URL) -> FileBrowserAccess {
        let spelled = url.path
        guard !CanonicalPath.containsNUL(spelled) else { return .readOnly(.brokenLink) }
        let effective: String
        if let resolved = CanonicalPath.resolve(spelled) {
            effective = resolved
        } else if Self.isSymbolicLink(spelled) {
            effective = spelled
        } else {
            return .readOnly(.brokenLink)
        }
        if let record = record(for: effective) { return .record(record) }
        if let record = ancestorRecord(of: effective) { return .record(record) }
        if isProjectManifest(effective) { return .record(.projectManifest) }
        guard Self.isWritableDirectory((effective as NSString).deletingLastPathComponent) else {
            return .readOnly(.denied)
        }
        return .writable
    }

    /// May something be made in this folder?
    func access(toCreateIn directory: URL) -> FileBrowserAccess {
        guard let resolved = CanonicalPath.resolve(directory.path) else { return .readOnly(.brokenLink) }
        if let record = record(for: resolved, protectingIdentities: false) { return .record(record) }
        guard Self.isWritableDirectory(resolved) else { return .readOnly(.denied) }
        return .writable
    }

    /// May this file be written where it lies? Asked of the file itself, not
    /// its folder: a folder that takes no new entries can still hold a file
    /// mobile may rewrite.
    ///
    /// A project's description is read-only here: its contents are the
    /// project's, and which project this is belongs to Projects, so the
    /// browser does not edit the file at all. The sidebar's editor is not
    /// affected.
    func access(toWriteFile url: URL) -> FileBrowserAccess {
        guard let effective = Self.effectivePath(of: url), !effective.isBroken else { return .readOnly(.brokenLink) }
        if let record = record(for: effective.path) { return .record(record) }
        if isProjectManifest(effective.path) { return .record(.projectManifest) }
        var metadata = stat()
        guard stat(effective.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            return .readOnly(.denied)
        }
        return Darwin.access(effective.path, W_OK) == 0 ? .writable : .readOnly(.denied)
    }

    private func record(
        for path: String,
        protectingIdentities: Bool
    ) -> FileBrowserProtectedRecord? {
        if let record = dataRecord(for: path, protectingIdentities: protectingIdentities) {
            return record
        }
        for root in payloadRoots where CanonicalPath.isCanonical(path, inside: root.path) {
            return root.record
        }
        return nil
    }

    // MARK: - The file system's own answer

    /// Where an action on `url` really lands: a link's target when it
    /// resolves, the link itself when it does not, and nil for a path that
    /// resolves nowhere and is no link — a name nothing exists at.
    static func effectivePath(of url: URL) -> (path: String, isBroken: Bool)? {
        let spelled = url.path
        guard !CanonicalPath.containsNUL(spelled) else { return nil }
        if let resolved = CanonicalPath.resolve(spelled) { return (resolved, false) }
        guard isSymbolicLink(spelled) else { return nil }
        return (spelled, true)
    }

    static func isSymbolicLink(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK
    }

    /// Whether anything at all is at this path, a link that leads nowhere
    /// included: `fileExists` follows a link and would call a dangling one
    /// absent, which is how a new name would overwrite it.
    static func exists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    /// `access(2)`, as the process really is: what a change would meet there,
    /// rather than a guess from the folder's name. A folder the app may not
    /// enter is not one it may write in, so the two rights are asked together.
    static func isWritableDirectory(_ path: String) -> Bool {
        var metadata = stat()
        guard stat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return false }
        return Darwin.access(path, W_OK | X_OK) == 0
    }

    /// Whether the path is a project's description sitting directly in a
    /// project folder: the file whose name says which project this is.
    private func isProjectManifest(_ path: String) -> Bool {
        guard let projectsPath = projects?.path,
              (path as NSString).lastPathComponent == Self.projectManifestName
        else { return false }
        let holder = (path as NSString).deletingLastPathComponent
        return (holder as NSString).deletingLastPathComponent == projectsPath
    }
}
