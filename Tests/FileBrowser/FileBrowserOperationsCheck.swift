import ApelinCore
import Foundation

/// What the page does to the disk: names that may be used, a copy that takes
/// the next free name, a folder kept out of itself, a record left alone, a
/// link removed without its target — and the top of the file system never.
func checkFileBrowserOperations() throws {
    let work = try temporaryFolder("operations")
    defer { try? FileManager.default.removeItem(at: work) }
    let data = work.appendingPathComponent("data", isDirectory: true)
    let project = data.appendingPathComponent("Projects/Demo", isDirectory: true)
    let sources = project.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let policy = FileBrowserPolicy(dataFolder: data)

    // Making one, and the names it may have.
    let file = try FileBrowserOperations.createFile(named: "notes.md", in: sources, policy: policy)
    precondition(FileManager.default.fileExists(atPath: file.path))
    precondition(FileBrowserOperations.check(name: "notes.md", in: sources, policy: policy) == .exists)
    precondition(FileBrowserOperations.check(name: " ", in: sources, policy: policy) == .invalidName)
    precondition(FileBrowserOperations.check(name: "a/b", in: sources, policy: policy) == .invalidName)
    precondition(FileBrowserOperations.check(name: "..", in: sources, policy: policy) == .invalidName)
    precondition(FileBrowserOperations.check(name: "a\0b", in: sources, policy: policy) == .invalidName)
    precondition(FileBrowserOperations.check(name: "fresh", in: sources, policy: policy) == nil)
    precondition(
        FileBrowserOperations.check(name: "fresh", in: data.appendingPathComponent("Projects"), policy: policy)
            == .record(.projects),
        "a project is not made by typing a name in Projects"
    )

    // Renaming, copying and moving, each keeping the folder's own rules.
    let renamed = try FileBrowserOperations.rename(file, to: "plan.md", policy: policy)
    precondition(renamed.lastPathComponent == "plan.md" && !FileManager.default.fileExists(atPath: file.path))
    let copy = try FileBrowserOperations.copy(renamed, into: sources, policy: policy)
    precondition(copy.lastPathComponent == "plan 2.md", "a name already there takes a number: \(copy.lastPathComponent)")
    try FileBrowserOperations.createFolder(named: "Deep", in: sources, policy: policy)
    let deeper = sources.appendingPathComponent("Deep", isDirectory: true)
    let moved = try FileBrowserOperations.move(copy, into: deeper, policy: policy)
    precondition(
        moved.deletingLastPathComponent().lastPathComponent == "Deep"
            && !FileManager.default.fileExists(atPath: copy.path),
        "a moved entry leaves its old place"
    )
    do {
        _ = try FileBrowserOperations.move(deeper, into: deeper, policy: policy)
        preconditionFailure("a folder inside itself is refused")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .insideItself, "\(failure)")
    }

    // A record takes none of it.
    let sdk = data.appendingPathComponent("SDKs/one", isDirectory: true)
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    do {
        try FileBrowserOperations.createFile(named: "x", in: sdk, policy: policy)
        preconditionFailure("an SDK record takes no new file")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .record(.sdks), "\(failure)")
    }
    do {
        try FileBrowserOperations.remove(sdk, policy: policy)
        preconditionFailure("an SDK record is not removed here")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .record(.sdks), "\(failure)")
    }
    let manifest = project.appendingPathComponent("apelin-project.json")
    try Data("{}".utf8).write(to: manifest)
    do {
        try FileBrowserOperations.remove(manifest, policy: policy)
        preconditionFailure("a project's description is not removed here")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .record(.projectManifest), "\(failure)")
    }

    // Reading is not changing: a record's file is copied out, and is not
    // moved out or deleted.
    let recordFile = sdk.appendingPathComponent("tool.txt")
    try Data("payload".utf8).write(to: recordFile)
    let copiedOut = try FileBrowserOperations.copy(recordFile, into: sources, policy: policy)
    precondition(
        copiedOut.lastPathComponent == "tool.txt" && FileManager.default.fileExists(atPath: copiedOut.path),
        "a record's file is copied out"
    )
    do {
        _ = try FileBrowserOperations.move(recordFile, into: sources, policy: policy)
        preconditionFailure("a record's file is not moved out")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .record(.sdks), "\(failure)")
    }

    // The terminal's own session list is a record: not removed, and not
    // replaced by a new file of the same name.
    let terminals = data.appendingPathComponent("Terminals", isDirectory: true)
    try FileManager.default.createDirectory(at: terminals, withIntermediateDirectories: true)
    let sessions = terminals.appendingPathComponent("sessions.json")
    try Data("[]".utf8).write(to: sessions)
    do {
        try FileBrowserOperations.remove(sessions, policy: policy)
        preconditionFailure("the terminal's session list is not removed here")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .record(.terminals), "\(failure)")
    }
    do {
        try FileBrowserOperations.createFile(named: "sessions.json", in: terminals, policy: policy)
        preconditionFailure("nor replaced by a new file of the same name")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .record(.terminals), "\(failure)")
    }

    // A link goes, and what it leads to stays.
    let kept = sources.appendingPathComponent("kept.txt")
    try Data("kept".utf8).write(to: kept)
    let link = work.appendingPathComponent("kept-link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: kept.path)
    try FileBrowserOperations.remove(link, policy: policy)
    precondition(!FileManager.default.fileExists(atPath: link.path))
    precondition(FileManager.default.fileExists(atPath: kept.path), "the target of a removed link stays")

    // A link is renamed where it sits: its name changes, its target does not.
    let second = work.appendingPathComponent("second-link")
    try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: kept.path)
    let renamedLink = try FileBrowserOperations.rename(second, to: "third-link", policy: policy)
    precondition(renamedLink.lastPathComponent == "third-link")
    precondition(canonical(renamedLink.path) == canonical(kept.path), "the renamed link leads where it did")
    precondition(FileManager.default.fileExists(atPath: kept.path), "and its target is still there")

    // A name is not taken over a link that leads nowhere, either way it is
    // asked for; and a link that leads nowhere is still renamed as a name.
    let dangling = work.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(
        atPath: dangling.path,
        withDestinationPath: work.appendingPathComponent("gone").path
    )
    do {
        try FileBrowserOperations.createFile(named: "dangling", in: work, policy: policy)
        preconditionFailure("a dangling link holds its name")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .exists, "\(failure)")
    }
    do {
        _ = try FileBrowserOperations.rename(renamedLink, to: "dangling", policy: policy)
        preconditionFailure("nor is it taken by renaming onto it")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .exists, "\(failure)")
    }
    let movedDangling = try FileBrowserOperations.rename(dangling, to: "gone-link", policy: policy)
    precondition(
        movedDangling.lastPathComponent == "gone-link" && FileBrowserPolicy.isSymbolicLink(movedDangling.path),
        "a link that leads nowhere is still renamed as a name"
    )

    // A file the reader made goes when it is deleted, and the top of the file
    // system never does.
    try FileBrowserOperations.remove(moved, policy: policy)
    precondition(!FileManager.default.fileExists(atPath: moved.path))
    do {
        try FileBrowserOperations.remove(URL(fileURLWithPath: "/"), policy: policy)
        preconditionFailure("the root is refused")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .atRoot, "\(failure)")
    }
    // The folder above a record holds it: neither the data folder's parent nor
    // the folder above a toolchain's payload is removed from here.
    do {
        try FileBrowserOperations.remove(data, policy: policy)
        preconditionFailure("the folder above the data folder is refused")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .record(.dataFolder), "\(failure)")
    }
    let bootstrap = work.appendingPathComponent("jbroot", isDirectory: true)
    let payload = bootstrap.appendingPathComponent("usr/lib/apelin/toolchains/clt", isDirectory: true)
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    let guarded = FileBrowserPolicy(dataFolder: data, bootstrapRoot: bootstrap.path)
    do {
        try FileBrowserOperations.remove(bootstrap.appendingPathComponent("usr/lib"), policy: guarded)
        preconditionFailure("the folder above a toolchain payload is refused")
    } catch let failure as FileBrowserFailure {
        precondition(failure == .record(.toolchains), "\(failure)")
    }

    // Copying only reads: a file mobile may not write is still copied.
    let frozen = work.appendingPathComponent("frozen.txt")
    try Data("frozen".utf8).write(to: frozen)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: frozen.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: frozen.path) }
    let frozenCopy = try FileBrowserOperations.copy(frozen, into: sources, policy: policy)
    precondition(FileManager.default.fileExists(atPath: frozenCopy.path), "a read-only file is copied")

    print("ok: names, copies, moves, records, links and the root are each held to their rule")
}
