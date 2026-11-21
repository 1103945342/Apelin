import Foundation

/// Settings ▸ Storage behind the wire (`Lurosd/Session/Storage/StorageKeeper`):
/// what each area costs, what an area that is missing or unreadable answers,
/// which folders an emptying leaves alone, and which paths it refuses.
///
/// Device: `bash Scripts/test-storage.sh --device <tool.entitlements>`.
/// The walk and the removal are the code the host runs, so the folders here
/// are made to look exactly like the ones under `~/Documents/com.fluoxetine.luros`.

private var checks = 0

private func check(_ passed: Bool, _ what: String) {
    if !passed {
        FileHandle.standardError.write(Data("FAILED: \(what)\n".utf8))
        exit(1)
    }
    checks += 1
}

private func scratch() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("storage-checks-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ bytes: Int, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
    )
    FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: bytes))
}

/// Sets a file's or folder's modification time, so "written an hour ago" can
/// be said of it.
private func age(_ url: URL, seconds: TimeInterval, now: Date = Date()) {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { return }
    let when = now.addingTimeInterval(-seconds)
    var times = [timespec]()
    times.append(timespec(tv_sec: Int(when.timeIntervalSince1970), tv_nsec: 0))
    times.append(timespec(tv_sec: Int(when.timeIntervalSince1970), tv_nsec: 0))
    times.withUnsafeBufferPointer { buffer in
        _ = utimensat(AT_FDCWD, url.path, buffer.baseAddress, 0)
    }
}

private func note(_ what: String) {
    print("· \(what)")
}

@main
struct StorageChecks {
    static func main() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = DataFolder(root: root.appendingPathComponent("data", isDirectory: true))
        let bootstrap = root.appendingPathComponent("bootstrap", isDirectory: true)
        try FileManager.default.createDirectory(at: data.root, withIntermediateDirectories: true)

        // An area costs every regular file below it, and nothing else.
        write(1000, to: data.root.appendingPathComponent("Builds/build-1/product.zip"))
        write(2000, to: data.root.appendingPathComponent("Builds/build-1/logs/build.log"))
        write(500, to: data.root.appendingPathComponent("Temporary/staging/thing.bin"))
        let builds = StorageKeeper.measure(.builds, data: data, installRoot: bootstrap.path, children: false)
        check(builds.bytes == 3000 && builds.files == 2, "a build folder is measured byte for byte")
        check(builds.failure == nil, "a readable area reports no failure")
        let temporary = StorageKeeper.measure(.temporary, data: data, installRoot: bootstrap.path, children: false)
        check(temporary.bytes == 500 && temporary.files == 1, "a second area is measured on its own")
        note("areas are measured one at a time")

        // A folder that is not there yet costs nothing.
        let exports = StorageKeeper.measure(.exports, data: data, installRoot: bootstrap.path, children: false)
        check(exports.bytes == 0 && exports.failure == nil, "an absent area is zero, not a failure")
        let nowhere = StorageKeeper.measure(.backups, data: DataFolder(root: root.appendingPathComponent("gone")), installRoot: bootstrap.path, children: false)
        check(nowhere.bytes == 0 && nowhere.failure == nil, "a data folder that is not there has no areas")
        note("absent folders answer zero")

        // Emptied: the files go, the area goes with them, and the bytes come
        // back as the answer.
        let reclaimed = try StorageKeeper.purge(.temporary, data: data)
        check(reclaimed == 500, "the temporary folder's bytes are reported as reclaimed")
        check(!FileManager.default.fileExists(atPath: data.root.appendingPathComponent("Temporary").path),
              "an emptied area leaves no empty folder behind")
        check(StorageKeeper.measure(.builds, data: data, installRoot: bootstrap.path, children: false).bytes == 3000,
              "emptying one area leaves the others alone")
        note("temporary is emptied")

        // A build folder or cache entry written within the hour stays: a build
        // may be writing it.
        let fresh = data.root.appendingPathComponent("Builds/build-fresh/app.bin")
        write(700, to: fresh)
        let old = data.root.appendingPathComponent("Builds/build-old/app.bin")
        write(300, to: old)
        age(data.root.appendingPathComponent("Builds/build-old"), seconds: 2 * 60 * 60)
        let cacheOld = data.root.appendingPathComponent("Builds/.build-cache/project/unit.o")
        write(90, to: cacheOld)
        age(data.root.appendingPathComponent("Builds/.build-cache/project"), seconds: 3 * 60 * 60)
        let buildReclaimed = try StorageKeeper.purge(.builds, data: data)
        check(!FileManager.default.fileExists(atPath: data.root.appendingPathComponent("Builds/build-old").path),
              "a build folder written two hours ago is removed")
        check(FileManager.default.fileExists(atPath: data.root.appendingPathComponent("Builds/build-fresh").path),
              "a build folder written just now stays")
        check(!FileManager.default.fileExists(atPath: data.root.appendingPathComponent("Builds/.build-cache/project").path),
              "a cache entry written three hours ago is removed")
        check(buildReclaimed == 390, "what the two removals reclaimed is counted")
        note("builds keep the last hour")

        // Logs are the journal and the console's finished runs; a script
        // waiting in the inbox and one that is running are not logs.
        write(120, to: data.root.appendingPathComponent("Journal/2026-11-21.log"))
        write(130, to: data.root.appendingPathComponent("console/done/script-1.sh"))
        write(140, to: data.root.appendingPathComponent("console/out/run-1.jsonl"))
        write(150, to: data.root.appendingPathComponent("console/inbox/waiting.sh"))
        write(160, to: data.root.appendingPathComponent("console/running/in-flight.sh"))
        let logReclaimed = try StorageKeeper.purge(.logs, data: data)
        check(logReclaimed == 390, "the journal and the finished runs are what a log purge takes")
        check(FileManager.default.fileExists(atPath: data.root.appendingPathComponent("console/inbox/waiting.sh").path),
              "a script waiting in the inbox is not a log")
        check(FileManager.default.fileExists(atPath: data.root.appendingPathComponent("console/running/in-flight.sh").path),
              "a script that is running is not a log")
        note("logs spare the inbox and the running script")

        // The areas holding a model are never emptied here.
        for area in [StorageArea.projects, .chats, .sessions, .sdks, .toolchains] {
            check(!area.isPurgeable, "\(area.rawValue) is not the host's to empty")
            var refused: LurosError?
            do {
                _ = try StorageKeeper.purge(area, data: data)
            } catch {
                refused = error as? LurosError
            }
            check(refused?.code == .badRequest, "emptying \(area.rawValue) is refused")
        }
        note("the areas holding a model are refused")

        // A folder replaced by a link is refused rather than followed.
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        write(10, to: elsewhere.appendingPathComponent("keep.txt"))
        try FileManager.default.removeItem(at: data.root.appendingPathComponent("Builds"))
        try FileManager.default.createSymbolicLink(
            atPath: data.root.appendingPathComponent("Builds").path,
            withDestinationPath: elsewhere.path,
        )
        let linked = StorageKeeper.measure(.builds, data: data, installRoot: bootstrap.path, children: false)
        check(linked.failure != nil, "a folder that is a link is not measured")
        var linkRefused: LurosError?
        do {
            _ = try StorageKeeper.purge(.builds, data: data)
        } catch {
            linkRefused = error as? LurosError
        }
        check(linkRefused?.code == .denied, "a folder that is a link is not emptied")
        check(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("keep.txt").path),
              "what the link points at is untouched")
        note("a linked folder is refused, not followed")

        // What the children of an area cost: a project is a folder, a
        // conversation is its record and its event log counted together.
        try? FileManager.default.removeItem(at: data.root.appendingPathComponent("Builds"))
        write(40, to: data.root.appendingPathComponent("Projects/Alpha/a.swift"))
        write(60, to: data.root.appendingPathComponent("Projects/Beta/b.swift"))
        let projects = StorageKeeper.measure(.projects, data: data, installRoot: bootstrap.path, children: true)
        check(projects.entries?.count == 2, "each project is an entry")
        check(projects.entries?.first?.name == "Beta" && projects.entries?.first?.bytes == 60,
              "the largest project comes first")
        write(70, to: data.root.appendingPathComponent("Chats/ABC.json"))
        write(30, to: data.root.appendingPathComponent("Chats/ABC.events.jsonl"))
        let chats = StorageKeeper.measure(.chats, data: data, installRoot: bootstrap.path, children: true)
        check(chats.entries?.count == 1, "a conversation is one entry")
        check(chats.entries?.first?.bytes == 100 && chats.entries?.first?.files == 2,
              "a conversation counts its record and its event log together")
        note("children are listed by size")

        // A toolchain is unpacked into the bootstrap, not into the data
        // folder: measuring Environment/ alone answered a few kilobytes.
        write(1500, to: bootstrap.appendingPathComponent("usr/lib/luros/toolchains/clt-1/usr/bin/swiftc"))
        write(90, to: data.root.appendingPathComponent("Environment/Toolchains/registry.json"))
        let toolchains = StorageKeeper.measure(
            .toolchains, data: data, installRoot: bootstrap.path, children: false,
        )
        check(toolchains.bytes == 1590, "a toolchain is measured where it is unpacked, not only its registry")
        check(toolchains.failure == nil, "the toolchains area reads both folders")
        note("toolchains are measured in the bootstrap")

        // A running build or environment task stops an emptying; nothing else does.
        check(StorageKeeper.busy(["build": 1])?.code == .conflict, "a running build refuses an emptying")
        check(StorageKeeper.busy(["environment": 2])?.code == .conflict, "a running environment task refuses it")
        check(StorageKeeper.busy(["agent": 1, "terminal": 3]) == nil, "an agent turn and a terminal do not")
        check(StorageKeeper.busy([:]) == nil, "an idle host does not")
        note("busy is build or environment only")

        // The disk is the device's, as statfs answers it.
        let disk = StorageKeeper.disk(at: data.root)
        check(disk != nil && (disk?.total ?? 0) > 0, "the disk's total is read")
        check((disk?.available ?? -1) >= 0, "the disk's free space is read")
        note("disk figures are read")

        print("\(checks) storage checks passed")
    }
}
