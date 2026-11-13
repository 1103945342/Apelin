import ApelinCore
import Foundation

/// What the browser allows where: a project's own files stay the reader's, the
/// projects page keeps its projects, the SDK and toolchain records keep
/// themselves — their folders, the folders that hold them, and the payload
/// installed in the bootstrap — and everything is judged on where a path really
/// leads: a link included, and a folder's permissions asked of the file system
/// rather than guessed from its name.
func checkFileBrowserPolicy() throws {
    let work = try temporaryFolder("policy")
    defer { try? FileManager.default.removeItem(at: work) }
    let data = work.appendingPathComponent("Documents/wiki.qaq.apelin", isDirectory: true)
    let projects = data.appendingPathComponent("Projects", isDirectory: true)
    let project = projects.appendingPathComponent("Demo", isDirectory: true)
    let sources = project.appendingPathComponent("Sources", isDirectory: true)
    let sdk = data.appendingPathComponent("SDKs/ios17.4-abc", isDirectory: true)
    let toolchain = data.appendingPathComponent("Environment/Toolchains/clt-15.3", isDirectory: true)
    let chats = data.appendingPathComponent("Chats", isDirectory: true)
    // The terminal keeps the reader's session list here.
    let terminals = data.appendingPathComponent("Terminals", isDirectory: true)
    // General Chat keeps one workspace per conversation under `Temporary/`,
    // and that workspace is where the reader actually works.
    let temporary = data.appendingPathComponent("Temporary", isDirectory: true)
    let workspace = temporary.appendingPathComponent("6F1C5B0E-0000-4000-8000-00000000F00D", isDirectory: true)
    for folder in [sources, sdk, toolchain, chats, terminals, workspace] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let sessionsFile = terminals.appendingPathComponent("sessions.json")
    try Data("[]".utf8).write(to: sessionsFile)
    let workspaceFile = workspace.appendingPathComponent("notes.md")
    try Data("notes".utf8).write(to: workspaceFile)
    let manifest = project.appendingPathComponent("apelin-project.json")
    try Data("{}".utf8).write(to: manifest)
    let source = sources.appendingPathComponent("App.swift")
    try Data("let a = 1\n".utf8).write(to: source)

    // A bootstrap wearing the shape the app installs into: the toolchains'
    // payload is here, not in the data folder, whose folder is only a record.
    let bootstrap = work.appendingPathComponent("jbroot", isDirectory: true)
    let toolchainPayload = bootstrap.appendingPathComponent("usr/lib/apelin/toolchains/clt-15.3", isDirectory: true)
    let sharePayload = bootstrap.appendingPathComponent("usr/share/apelin", isDirectory: true)
    for folder in [toolchainPayload, sharePayload] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    let policy = FileBrowserPolicy(dataFolder: data, bootstrapRoot: bootstrap.path)

    // Which places are records, and which are the reader's own.
    precondition(policy.record(for: canonical(data.path)) == .dataFolder)
    precondition(policy.record(for: canonical(projects.path)) == .projects)
    precondition(policy.record(for: canonical(project.path)) == .projects, "a project folder is the projects page's")
    precondition(policy.record(for: canonical(sources.path)) == nil, "a project's own folder is ordinary")
    precondition(policy.record(for: canonical(chats.path)) == .chats)
    precondition(policy.record(for: canonical(terminals.path)) == .terminals, "the terminal's session list is a record")
    precondition(policy.record(for: canonical(sessionsFile.path)) == .terminals, "and so is the file inside it")
    precondition(policy.access(toCreateIn: canonicalURL(terminals.path)) == .record(.terminals))
    precondition(policy.access(toWriteFile: sessionsFile) == .record(.terminals), "nor is it edited by hand in the browser")
    precondition(policy.access(to: canonicalURL(sessionsFile.path)) == .record(.terminals), "nor deleted and replaced by a new one")
    precondition(policy.record(for: canonical(sdk.path)) == .sdks)
    precondition(policy.record(for: canonical(toolchain.path)) == .toolchains)
    precondition(policy.record(for: canonical(data.appendingPathComponent("Environment").path)) == .environment)
    precondition(policy.record(for: canonical(toolchainPayload.path)) == .toolchains, "the toolchain's payload is its page's")
    precondition(policy.record(for: canonical(sharePayload.path)) == .applicationPayload)

    // A chat workspace is the app's to make and remove, and the reader's to
    // work in — General Chat's files must not become read-only with it.
    precondition(policy.record(for: canonical(temporary.path)) == .temporary, "the workspaces' root is the app's")
    precondition(policy.record(for: canonical(workspace.path)) == .temporary, "one workspace is made and removed with its conversation")
    precondition(policy.record(for: canonical(workspaceFile.path)) == nil, "and what it holds is the reader's")
    precondition(policy.access(toCreateIn: canonicalURL(workspace.path)) == .writable, "a workspace takes new files")
    precondition(policy.access(to: canonicalURL(workspaceFile.path)) == .writable, "and its files are renamed and deleted here")
    precondition(policy.access(toWriteFile: workspaceFile) == .writable, "and edited here")
    precondition(policy.access(to: canonicalURL(workspace.path)) == .record(.temporary), "the workspace folder itself is not removed here")
    precondition(policy.access(toCreateIn: canonicalURL(temporary.path)) == .record(.temporary), "nor is a workspace made by typing a name")
    precondition(policy.record(for: "/private/var/mobile") == nil, "outside the records nothing is one")

    // What may be made where.
    precondition(policy.access(toCreateIn: canonicalURL(sources.path)) == .writable, "a project's sources are the reader's")
    precondition(policy.access(toCreateIn: canonicalURL(project.path)) == .writable, "and so is the project folder itself")
    precondition(policy.access(toCreateIn: canonicalURL(projects.path)) == .record(.projects), "a project is made in Projects")
    precondition(policy.access(toCreateIn: canonicalURL(sdk.path)) == .record(.sdks))
    precondition(policy.access(toCreateIn: canonicalURL(toolchain.path)) == .record(.toolchains))
    precondition(policy.access(toCreateIn: canonicalURL(toolchainPayload.path)) == .record(.toolchains))
    precondition(policy.access(toCreateIn: canonicalURL(chats.path)) == .record(.chats))
    precondition(policy.access(toCreateIn: canonicalURL(data.path)) == .record(.dataFolder))
    let outside = work.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    precondition(policy.access(toCreateIn: canonicalURL(outside.path)) == .writable, "anywhere else mobile writes is writable")

    // A folder that holds a record holds everything under it: removing or
    // moving it takes the records with it. Making something else there is a
    // different question and stays open.
    let documents = work.appendingPathComponent("Documents", isDirectory: true)
    precondition(policy.access(to: canonicalURL(documents.path)) == .record(.dataFolder), "the folder above the data folder")
    precondition(policy.access(toCreateIn: canonicalURL(documents.path)) == .writable, "still takes the reader's own files")
    precondition(policy.access(to: canonicalURL(bootstrap.appendingPathComponent("usr/lib").path)) == .record(.toolchains),
                 "the folder above a toolchain payload")
    precondition(policy.access(to: canonicalURL(bootstrap.path)) == .record(.toolchains), "and the bootstrap above both")

    // A project's description is read-only here: what makes it this project
    // belongs to Projects, and this version does not edit it in the browser.
    precondition(policy.access(to: manifest) == .record(.projectManifest), "its name and place are the projects page's")
    precondition(policy.access(toWriteFile: manifest) == .record(.projectManifest), "and so is its text, in the browser")
    precondition(policy.access(to: source) == .writable)
    precondition(policy.access(toWriteFile: source) == .writable)
    precondition(policy.access(to: canonicalURL(sdk.path)) == .record(.sdks), "an SDK folder is not renamed here")

    // A link is judged by where it leads, at the moment it is asked.
    let sdkLink = work.appendingPathComponent("link-to-sdk")
    try FileManager.default.createSymbolicLink(atPath: sdkLink.path, withDestinationPath: sdk.path)
    precondition(policy.access(to: sdkLink) == .record(.sdks), "a link into a record is the record")
    let dangling = work.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(
        atPath: dangling.path,
        withDestinationPath: work.appendingPathComponent("gone").path
    )
    precondition(
        policy.access(to: dangling) == .writable,
        "a link that leads nowhere is still a name in an ordinary folder"
    )
    precondition(policy.access(toWriteFile: dangling) == .readOnly(.brokenLink), "and nothing is written through it")
    let sourceLink = work.appendingPathComponent("source-link")
    try FileManager.default.createSymbolicLink(atPath: sourceLink.path, withDestinationPath: source.path)
    precondition(policy.access(toWriteFile: sourceLink) == .writable, "a link to a project's source is as writable")

    // Permissions are asked of the file system.
    let locked = work.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    precondition(policy.access(toCreateIn: canonicalURL(locked.path)) == .writable)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    precondition(policy.access(toCreateIn: canonicalURL(locked.path)) == .readOnly(.denied), "a folder mobile may not write in says so")
    let readOnlyFile = work.appendingPathComponent("read-only.txt")
    try Data("x".utf8).write(to: readOnlyFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyFile.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readOnlyFile.path) }
    precondition(policy.access(toWriteFile: readOnlyFile) == .readOnly(.denied), "a file mobile may not rewrite says so")

    // The system volume takes no write from anyone: the page shows it
    // read-only instead of offering a change that cannot finish.
    if FileManager.default.fileExists(atPath: "/System") {
        precondition(
            policy.access(toCreateIn: URL(fileURLWithPath: "/System")) == .readOnly(.denied),
            "/System is read-only"
        )
    }
    print("ok: a project stays the reader's, records and their payloads stay their pages', and a link is judged by its target")
}
