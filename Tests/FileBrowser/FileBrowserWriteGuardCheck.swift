import ApelinCore
import Foundation

/// The guard the browser hands the editor is a value of its own: it keeps
/// working after the page that opened the file is gone, and it refuses a save
/// whose target changed underneath — a file replaced, a link re-aimed, a path
/// that now leads into one of Apelin's records — instead of answering nil
/// because there is no page left to ask.
func checkFileBrowserWriteGuard() throws {
    let work = try temporaryFolder("guard")
    defer { try? FileManager.default.removeItem(at: work) }
    let data = work.appendingPathComponent("data", isDirectory: true)
    let sdk = data.appendingPathComponent("SDKs/one", isDirectory: true)
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    let policy = FileBrowserPolicy(dataFolder: data)

    let file = work.appendingPathComponent("notes.txt")
    try Data("first".utf8).write(to: file)
    let ordinary = FileBrowserWriteGuard(url: file, policy: policy)
    precondition(ordinary.refusal() == nil, "an ordinary file in an ordinary folder may be written")

    // Written in place by someone else, under the same inode and the same
    // length: the bytes decide, not the identity of the file.
    let handle = try FileHandle(forWritingTo: file)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data("secon".utf8))
    try handle.close()
    precondition(
        ordinary.refusal() == String(localized: "This file changed since it was opened."),
        "an edit made while the file was open is refused, not overwritten: \(ordinary.refusal() ?? "-")"
    )
    ordinary.didSave()
    precondition(ordinary.refusal() == nil, "the file the editor just wrote is the one to expect next")

    // Touched, not written: the bytes are still the ones that were opened, so
    // there is nothing to lose and nothing to refuse.
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)],
        ofItemAtPath: file.path
    )
    precondition(ordinary.refusal() == nil, "a new time alone is not a change to refuse")

    // Written in place and its modification time put back: size, time, device
    // and inode are all as they were, and only the bytes say it changed.
    let original = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    let retouch = try FileHandle(forWritingTo: file)
    try retouch.seek(toOffset: 0)
    try retouch.write(contentsOf: Data("secoN".utf8))
    try retouch.close()
    if let original {
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: file.path)
    }
    precondition(
        ordinary.refusal() == String(localized: "This file changed since it was opened."),
        "an in-place change with its time put back is refused: \(ordinary.refusal() ?? "-")"
    )

    // Replaced by another file, as someone else's atomic write leaves it.
    let replacement = work.appendingPathComponent("replacement")
    try Data("second".utf8).write(to: replacement)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: replacement, to: file)
    precondition(
        ordinary.refusal() == String(localized: "This file was replaced by another."),
        "a file replaced under the editor is refused: \(ordinary.refusal() ?? "-")"
    )

    // A link re-aimed at another file.
    let link = work.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)
    let linked = FileBrowserWriteGuard(url: link, policy: policy)
    precondition(linked.refusal() == nil)
    let other = work.appendingPathComponent("other.txt")
    try Data("other".utf8).write(to: other)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: other.path)
    precondition(
        linked.refusal() == String(localized: "This file now leads somewhere else."),
        "a link re-aimed under the editor is refused: \(linked.refusal() ?? "-")"
    )

    // A name that now leads into a record: the record's page says why.
    let before = work.appendingPathComponent("retargeted.txt")
    try Data("third".utf8).write(to: before)
    let retargeted = FileBrowserWriteGuard(url: before, policy: policy)
    precondition(retargeted.refusal() == nil)
    let recordFile = sdk.appendingPathComponent("tool.json")
    try Data("{}".utf8).write(to: recordFile)
    try FileManager.default.removeItem(at: before)
    try FileManager.default.createSymbolicLink(atPath: before.path, withDestinationPath: recordFile.path)
    precondition(
        retargeted.refusal() == FileBrowserProtectedRecord.sdks.sentence,
        "a path that now leads into a record is refused: \(retargeted.refusal() ?? "-")"
    )

    // The file gone, and a link that leads nowhere: each says what it is.
    let gone = FileBrowserWriteGuard(url: work.appendingPathComponent("gone.txt"), policy: policy)
    precondition(
        gone.refusal() == String(localized: "This file is no longer there."),
        "a file that is not there is refused: \(gone.refusal() ?? "-")"
    )
    let dangling = work.appendingPathComponent("dangling.txt")
    try FileManager.default.createSymbolicLink(
        atPath: dangling.path,
        withDestinationPath: work.appendingPathComponent("never").path
    )
    let broken = FileBrowserWriteGuard(url: dangling, policy: policy)
    precondition(
        broken.refusal() == FileBrowserReadOnly.brokenLink.sentence,
        "a link that leads nowhere is refused: \(broken.refusal() ?? "-")"
    )
    print("ok: a save is judged on where the path leads now, after the page that opened it is gone")
}
