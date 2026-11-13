import Foundation

/// Where a terminal starts, in the terms a restart can keep: a folder inside a
/// project, named by the project's folder and a plain relative path, or a
/// folder relative to Apelin's own data folder. Never an absolute path: on
/// roothide one carries an install root that a reboot may rename, and a record
/// written that way opens the wrong place — or nothing — the next day.
///
/// `TerminalPresenter` resolves one from the URL the caller has; the session
/// record persists this and nothing else about the place.
struct TerminalTarget: Codable, Hashable, Sendable {
    enum Location: Codable, Hashable, Sendable {
        /// `folder` is the project's directory under `Projects/`; a nil
        /// `relativePath` is that folder itself, and anything else is a plain
        /// relative path inside it, as the wire's `relativePath` takes.
        case project(folder: String, relativePath: String?)
        /// A folder inside `~/Documents/wiki.qaq.apelin` — General Chat's
        /// `Temporary/<id>`, say — kept relative to that folder.
        case data(relativePath: String)
        /// Neither: a folder the caller had this run only. Nothing about it is
        /// written down, so no record of such a session is kept.
        case elsewhere
    }

    var location: Location

    init(location: Location) {
        self.location = location
    }

    /// Only a target that names itself without an install root can be reopened.
    var isRestorable: Bool {
        switch location {
        case .project, .data: true
        case .elsewhere: false
        }
    }

    /// The wire's `projectID`, `project:<folder>`, for a project folder.
    var projectID: String? {
        guard case let .project(folder, _) = location else { return nil }
        return "project:" + folder
    }

    /// The wire's `relativePath`, for a folder inside a project; nil at the
    /// project's own folder and for every other kind of target.
    var relativePath: String? {
        guard case let .project(_, relativePath) = location else { return nil }
        return relativePath
    }

    /// The folder to start in, for a target that names itself.
    func startDirectory(dataRoot: URL) -> URL? {
        switch location {
        case let .project(folder, relativePath):
            var url = dataRoot
                .appendingPathComponent("Projects", isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true)
            if let relativePath, !relativePath.isEmpty {
                url.appendPathComponent(relativePath, isDirectory: true)
            }
            return url
        case let .data(relativePath):
            return dataRoot.appendingPathComponent(relativePath, isDirectory: true)
        case .elsewhere:
            return nil
        }
    }

    /// One line naming the place in a menu; no install root, so nothing here
    /// goes stale when the bootstrap moves.
    var displayName: String {
        switch location {
        case let .project(folder, relativePath):
            guard let relativePath, !relativePath.isEmpty else { return folder }
            return folder + "/" + relativePath
        case let .data(relativePath):
            return (relativePath as NSString).lastPathComponent
        case .elsewhere:
            return String(localized: "Terminal")
        }
    }

    /// Resolves where a caller asked for. A directory inside `projectRoot` is
    /// a project target — the root itself, or a plain relative path inside it;
    /// a directory inside `dataRoot` is a data target; anything else is the
    /// run's own.
    ///
    /// Both paths are resolved through symlinks and compared with the `/`
    /// boundary, so `/x/Project 2` is never read as inside `/x/Project`.
    static func resolve(directory: URL, projectRoot: URL?, dataRoot: URL) -> TerminalTarget {
        let directoryPath = canonicalPath(directory)
        if let projectRoot {
            let rootPath = canonicalPath(projectRoot)
            if let relative = relativePath(of: directoryPath, inside: rootPath) {
                let folder = (rootPath as NSString).lastPathComponent
                return TerminalTarget(location: .project(
                    folder: folder,
                    relativePath: relative.isEmpty ? nil : relative
                ))
            }
        }
        let dataPath = canonicalPath(dataRoot)
        if let relative = relativePath(of: directoryPath, inside: dataPath) {
            return TerminalTarget(location: .data(relativePath: relative))
        }
        return TerminalTarget(location: .elsewhere)
    }

    /// `path` relative to `root`, `""` when they are the same folder, nil when
    /// `path` is somewhere else. Both are already canonical.
    static func relativePath(of path: String, inside root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path == root || path == root + "/" {
            return ""
        }
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// `realpath` where the filesystem can answer, the standardised URL where
    /// the folder does not exist yet.
    static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().path
        if resolved.count > 1, resolved.hasSuffix("/") {
            return String(resolved.dropLast())
        }
        return resolved
    }
}

/// A terminal's place in this run: what the record keeps (`TerminalTarget`) and
/// the folder the shell actually starts in, canonical.
///
/// The folder is part of the identity and none of the record: two folders
/// outside Apelin's own storage both persist as `.elsewhere`, and a page
/// opened on the second must not be handed the first one's shell.
struct TerminalIdentity: Hashable, Sendable {
    let target: TerminalTarget
    /// The folder the shell starts in, canonical for this run.
    let directory: URL

    init(target: TerminalTarget, directory: URL) {
        self.target = target
        self.directory = URL(fileURLWithPath: TerminalTarget.canonicalPath(directory), isDirectory: true)
    }

    static func resolve(directory: URL, projectRoot: URL?, dataRoot: URL) -> TerminalIdentity {
        let target = TerminalTarget.resolve(
            directory: directory,
            projectRoot: projectRoot,
            dataRoot: dataRoot
        )
        let start = target.startDirectory(dataRoot: dataRoot) ?? directory
        return TerminalIdentity(target: target, directory: start)
    }

    var displayName: String {
        switch target.location {
        case .project, .data:
            return target.displayName
        case .elsewhere:
            let name = directory.lastPathComponent
            return name.isEmpty ? String(localized: "Terminal") : name
        }
    }
}
