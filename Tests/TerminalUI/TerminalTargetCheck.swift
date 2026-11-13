import Foundation

/// Where a terminal starts, and what a record may write down about it: a
/// project folder with a relative path, a folder relative to the data folder,
/// or nothing at all. Run by `Tests/TerminalUI/run.sh`.
enum TerminalTargetCheck {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("ok   \(message)")
        } else {
            failures += 1
            print("FAIL \(message)")
        }
    }

    static func run() -> Int {
        failures = 0
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("apelin-terminal-target-\(UUID().uuidString)", isDirectory: true)
        let dataRoot = base.appendingPathComponent("wiki.qaq.apelin", isDirectory: true)
        let project = dataRoot.appendingPathComponent("Projects/Project", isDirectory: true)
        let nested = project.appendingPathComponent("Sources/App", isDirectory: true)
        let sibling = base.appendingPathComponent("ProjectsOutside/Project 2", isDirectory: true)
        let temporary = dataRoot.appendingPathComponent("Temporary/1234", isDirectory: true)
        let outside = base.appendingPathComponent("Elsewhere", isDirectory: true)
        for folder in [nested, temporary, sibling, outside] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        // A project's own folder.
        let root = TerminalTarget.resolve(directory: project, projectRoot: project, dataRoot: dataRoot)
        check(root == TerminalTarget(location: .project(folder: "Project", relativePath: nil)),
              "the project folder resolves to the project, with no relative path")
        check(root.projectID == "project:Project", "the wire's project id names the folder")
        check(root.relativePath == nil, "the project folder itself has no relative path")
        check(root.isRestorable, "a project target is restorable")
        check(root.startDirectory(dataRoot: dataRoot)?.standardizedFileURL.path
              == project.standardizedFileURL.path, "a project target starts in its folder")

        // A folder inside it, however deep.
        let inner = TerminalTarget.resolve(directory: nested, projectRoot: project, dataRoot: dataRoot)
        check(inner == TerminalTarget(location: .project(folder: "Project", relativePath: "Sources/App")),
              "a folder inside the project keeps a plain relative path")
        check(inner.relativePath == "Sources/App", "the relative path is what the wire sends")
        check(inner.startDirectory(dataRoot: dataRoot)?.standardizedFileURL.path
              == nested.standardizedFileURL.path, "the start directory comes back from the record")

        // A sibling whose name starts with the same characters is not inside.
        let notInside = TerminalTarget.resolve(directory: sibling, projectRoot: project, dataRoot: dataRoot)
        check(notInside == TerminalTarget(location: .elsewhere),
              "a sibling with the same prefix is not inside the project")

        // A trailing slash is the same folder.
        let slashed = TerminalTarget.resolve(
            directory: URL(fileURLWithPath: nested.path + "/"),
            projectRoot: project,
            dataRoot: dataRoot
        )
        check(slashed == inner, "a trailing slash does not change the target")

        // Apelin's own data folder: General Chat's temporary workspace.
        let data = TerminalTarget.resolve(directory: temporary, projectRoot: nil, dataRoot: dataRoot)
        check(data == TerminalTarget(location: .data(relativePath: "Temporary/1234")),
              "a folder in the data folder is kept relative to it")
        check(data.isRestorable, "a data target is restorable")
        check(data.startDirectory(dataRoot: dataRoot)?.standardizedFileURL.path
              == temporary.standardizedFileURL.path, "a data target starts where it did")

        // Anywhere else: this run only, and never written down.
        let other = TerminalTarget.resolve(directory: outside, projectRoot: project, dataRoot: dataRoot)
        check(other == TerminalTarget(location: .elsewhere), "a folder outside both is run-only")
        check(other.isRestorable == false, "a run-only target is not restorable")
        check(other.startDirectory(dataRoot: dataRoot) == nil, "a run-only target has no recorded directory")

        // Records round-trip, relative paths included.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for target in [root, inner, data, other] {
            guard let data = try? encoder.encode(target),
                  let decoded = try? decoder.decode(TerminalTarget.self, from: data)
            else {
                check(false, "a target round-trips through JSON")
                continue
            }
            check(decoded == target, "a target round-trips through JSON")
        }

        // Names a menu can show without an install root in them.
        check(inner.displayName == "Project/Sources/App", "a nested target is named by its path in the project")
        check(root.displayName == "Project", "the project folder is named by the project")
        check(data.displayName == "1234", "a data folder is named by its last component")

        // Two folders outside both are one target but two places: a page opened
        // on the second must not be handed the first one's shell.
        let outsideA = base.appendingPathComponent("ElsewhereA", isDirectory: true)
        let outsideB = base.appendingPathComponent("ElsewhereB", isDirectory: true)
        let outsideBLink = base.appendingPathComponent("ElsewhereBLink", isDirectory: true)
        for folder in [outsideA, outsideB] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try? FileManager.default.createSymbolicLink(at: outsideBLink, withDestinationURL: outsideB)
        let identityA = TerminalIdentity.resolve(directory: outsideA, projectRoot: nil, dataRoot: dataRoot)
        let identityB = TerminalIdentity.resolve(directory: outsideB, projectRoot: nil, dataRoot: dataRoot)
        let identityBLink = TerminalIdentity.resolve(directory: outsideBLink, projectRoot: nil, dataRoot: dataRoot)
        check(identityA.target == identityB.target, "two run-only folders record the same target")
        check(identityA != identityB, "two run-only folders are two different sessions")
        check(identityB == identityBLink, "a link to a folder is the same session as the folder")
        check(identityA.displayName == "ElsewhereA", "a run-only place is named by its folder")

        let identityProject = TerminalIdentity.resolve(
            directory: nested,
            projectRoot: project,
            dataRoot: dataRoot
        )
        let identityProjectAgain = TerminalIdentity.resolve(
            directory: URL(fileURLWithPath: nested.path + "/"),
            projectRoot: project,
            dataRoot: dataRoot
        )
        check(identityProject == identityProjectAgain, "the same project folder is one session however it is spelled")
        let canonicalNested = URL(fileURLWithPath: TerminalTarget.canonicalPath(nested), isDirectory: true)
        check(identityProject.directory == canonicalNested, "a project identity keeps the canonical folder")

        print(failures == 0 ? "TerminalTargetCheck: all checks passed" : "TerminalTargetCheck: \(failures) failed")
        return failures
    }
}

