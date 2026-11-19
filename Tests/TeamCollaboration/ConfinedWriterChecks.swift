import Foundation

/// Device checks for the confined writer a delegated conversation writes
/// through: descriptor-relative steps, no link followed, exclusive creation,
/// a parent replaced by a link, and failures that leave the target alone.
/// Run by `Scripts/test-team-confined-writer.sh`, on a Mac or signed on the
/// device.
@main
struct ConfinedWriterChecks {
    static func main() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("confined-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Project", isDirectory: true)
        let outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let writer = ConfinedWriter(rootPath: root.path)

        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
        }
        func refuses(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                fatalError("allowed: \(name)")
            } catch {
                check(true, name)
            }
        }
        func read(_ relative: String) -> String? {
            try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }
        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        }

        // 1. A normal write, making the directories it needs.
        try writer.write(Data("first".utf8), to: "Sources/Nested/File.txt", exclusive: false)
        check(read("Sources/Nested/File.txt") == "first", "creates missing directories and writes")

        // 2. Replacing a regular file keeps its path.
        try writer.write(Data("second".utf8), to: "Sources/Nested/File.txt", exclusive: false)
        check(read("Sources/Nested/File.txt") == "second", "replaces a regular file")

        // 3. Exclusive creation refuses an existing file and leaves it alone.
        refuses("exclusive creation over an existing file") {
            try writer.write(Data("third".utf8), to: "Sources/Nested/File.txt", exclusive: true)
        }
        check(read("Sources/Nested/File.txt") == "second", "a refused exclusive write leaves the file")

        // 4. Paths that leave the project, a git directory, and an absolute one.
        refuses("parent escape") { try writer.write(Data(), to: "../Outside/x", exclusive: false) }
        refuses("absolute path") { try writer.write(Data(), to: "/etc/x", exclusive: false) }
        refuses("git directory") { try writer.write(Data(), to: ".git/config", exclusive: false) }
        check(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("x").path),
              "an escaped path wrote nothing")

        // 5. A symbolic link inside the root is not written through.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Link"),
            withDestinationURL: outside,
        )
        refuses("symlink directory component") {
            try writer.write(Data("x".utf8), to: "Link/File.txt", exclusive: false)
        }
        check(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("File.txt").path),
              "the link's target was not written")

        // 6. A parent replaced by a link after it was used is refused.
        try writer.write(Data("a".utf8), to: "P/File.txt", exclusive: false)
        let parent = root.appendingPathComponent("P")
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        refuses("parent replaced by a link") {
            try writer.write(Data("b".utf8), to: "P/File.txt", exclusive: false)
        }
        check(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("File.txt").path),
              "nothing was written through the replaced parent")

        // 7. Content over the limit writes nothing.
        let huge = Data(repeating: 0x41, count: ConfinedWriter.maximumBytes + 1)
        refuses("content over the limit") {
            try writer.write(huge, to: "Sources/Huge.txt", exclusive: false)
        }
        check(!exists("Sources/Huge.txt"), "an oversized write leaves nothing behind")

        // 8. The final component being a link is refused, not replaced.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Sources/Target.txt"),
            withDestinationURL: outside.appendingPathComponent("Outside.txt"),
        )
        refuses("symlink as the final component") {
            try writer.write(Data("x".utf8), to: "Sources/Target.txt", exclusive: false)
        }
        check(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("Outside.txt").path),
              "the final link's target was not written through")

        // 9. A parent moved out of the project after the walk is refused:
        //    the identity read again before the commit is not the one held.
        let parentDirectory = root.appendingPathComponent("Q", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let movedParent = outside.appendingPathComponent("Moved", isDirectory: true)
        var movingParent = ConfinedWriter(rootPath: root.path)
        movingParent.betweenWalkAndCommit = {
            try? FileManager.default.moveItem(at: parentDirectory, to: movedParent)
            try? FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        }
        refuses("parent moved out after the walk") {
            try movingParent.write(Data("c".utf8), to: "Q/File.txt", exclusive: false)
        }
        check(!FileManager.default.fileExists(atPath: movedParent.appendingPathComponent("File.txt").path),
              "nothing was written in the moved directory")
        check(!FileManager.default.fileExists(atPath: parentDirectory.appendingPathComponent("File.txt").path),
              "nothing was written in the directory that took its place")

        // 10. A target with several hard links is not written through: the
        //     name inside the project is replaced, and the other link, here
        //     one outside the project, keeps its content. This is why no
        //     link count is refused: the writer never opens the target for
        //     writing, it moves a new file onto the name.
        let sharedFile = outside.appendingPathComponent("Shared.txt")
        try Data("shared".utf8).write(to: sharedFile)
        let sharedDirectory = root.appendingPathComponent("H", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: sharedFile, to: sharedDirectory.appendingPathComponent("Shared.txt"))
        try writer.write(Data("inside".utf8), to: "H/Shared.txt", exclusive: false)
        check(read("H/Shared.txt") == "inside", "the name inside the project holds the new content")
        check((try? String(contentsOf: sharedFile, encoding: .utf8)) == "shared",
              "the other hard link was not written through")

        // 11. The root itself replaced after the walk is refused.
        let movedRoot = outside.appendingPathComponent("ProjectMoved", isDirectory: true)
        var movingRoot = ConfinedWriter(rootPath: root.path)
        movingRoot.betweenWalkAndCommit = {
            try? FileManager.default.moveItem(at: root, to: movedRoot)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        refuses("root replaced after the walk") {
            try movingRoot.write(Data("d".utf8), to: "R/File.txt", exclusive: false)
        }
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("R/File.txt").path),
              "nothing was written under the new root")
        check(!FileManager.default.fileExists(atPath: movedRoot.appendingPathComponent("R/File.txt").path),
              "nothing was written under the moved root")

        print("ok: \(count) confined-writer checks")
    }
}
