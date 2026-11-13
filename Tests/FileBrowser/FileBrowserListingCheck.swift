import ApelinCore
import Foundation

/// One folder is read as it is: folders first, hidden names shown, a link
/// pointing at what it leads to — and a folder that cannot be read says why
/// rather than standing in as an empty one.
func checkFileBrowserListing() throws {
    let work = try temporaryFolder("listing")
    defer { try? FileManager.default.removeItem(at: work) }
    let folder = work.appendingPathComponent("folder", isDirectory: true)
    let sub = folder.appendingPathComponent("Sub", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data("three".utf8).write(to: folder.appendingPathComponent("a.txt"))
    try Data("one".utf8).write(to: folder.appendingPathComponent("b.txt"))
    try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden"))
    try FileManager.default.createSymbolicLink(
        atPath: folder.appendingPathComponent("alias").path,
        withDestinationPath: sub.path
    )
    try FileManager.default.createSymbolicLink(
        atPath: folder.appendingPathComponent("dangling").path,
        withDestinationPath: folder.appendingPathComponent("gone").path
    )

    guard case let .success(entries) = FileBrowserListing.list(folder) else {
        preconditionFailure("the folder lists")
    }
    precondition(
        Set(entries.map(\.name)) == Set(["Sub", "alias", ".hidden", "a.txt", "b.txt", "dangling"]),
        "everything the folder holds, hidden names included: \(entries.map(\.name))"
    )
    let flags = entries.map(\.opensAsDirectory)
    precondition(
        (flags.lastIndex(of: true) ?? -1) < (flags.firstIndex(of: false) ?? flags.count),
        "folders, and links into them, come first: \(entries.map(\.name))"
    )
    let files = entries.filter { !$0.opensAsDirectory }.map(\.name)
    precondition(
        files.firstIndex(of: "a.txt")! < files.firstIndex(of: "b.txt")!,
        "files are read by name: \(files)"
    )
    precondition(entries.first { $0.name == "Sub" }?.kind == .directory)
    precondition(entries.first { $0.name == "alias" }?.isLink == true)
    precondition(
        entries.first { $0.name == "alias" }?.kind == .link(target: canonical(sub.path)),
        "a link carries its resolved target"
    )
    precondition(entries.first { $0.name == "dangling" }?.kind == .link(target: nil), "a link that leads nowhere says so")
    precondition(entries.first { $0.name == ".hidden" }?.isHidden == true)
    precondition(entries.first { $0.name == "a.txt" }?.byteCount == 5)

    // Empty is empty; a refusal is a refusal.
    let empty = work.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    guard case let .success(nothing) = FileBrowserListing.list(empty) else {
        preconditionFailure("an empty folder lists")
    }
    precondition(nothing.isEmpty)
    precondition(FileBrowserListing.list(work.appendingPathComponent("gone")) == .failure(.missing))
    precondition(
        FileBrowserListing.list(folder.appendingPathComponent("a.txt")) == .failure(.notADirectory),
        "a file is not a folder"
    )
    let locked = work.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    precondition(
        FileBrowserListing.list(locked) == .failure(.notPermitted),
        "a folder mobile may not open is never an empty one"
    )
    print("ok: a folder is read as it is — folders first, hidden shown, links resolved, refusals named")
}
