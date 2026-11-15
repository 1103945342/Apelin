@testable import ApelinBuild
import ApelinProject
import Foundation
import XCTest

/// The compile cache on its own: what a key is a function of, what comes back
/// out of an entry, and what happens to one that does not read.
final class BuildCacheTests: XCTestCase {
    private func scratchCache(_ scratch: URL) -> BuildCache {
        BuildCache(
            root: scratch.appendingPathComponent("Builds/.build-cache/project", isDirectory: true),
            projectRoot: "/private/tmp/project",
            installRoot: "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
        )
    }

    /// A file in the build's work directory, as a compile would leave it.
    @discardableResult
    private func makeWork(_ scratch: URL, _ name: String, _ bytes: String) throws -> String {
        let directory = scratch.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name).path
        try Data(bytes.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func entry(_ cache: BuildCache, _ unit: BuildCache.Unit, _ key: String) -> URL {
        cache.root
            .appendingPathComponent(unit.identifier, isDirectory: true)
            .appendingPathComponent(String(key.dropFirst("sha256:".count)), isDirectory: true)
    }

    private func setLastUsed(_ entry: URL, _ seconds: Int) throws {
        let url = entry.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        var manifest = try XCTUnwrap(parsed as? [String: Any])
        manifest["lastUsedAt"] = seconds
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: url, options: .atomic)
    }

    func testTheKeyIsTheSameWhateverOrderTheMembersComeIn() {
        let cache = BuildCache(root: URL(fileURLWithPath: "/tmp/cache"), projectRoot: "/p", installRoot: "/")
        let unit = BuildCache.Unit(kind: .swiftModule, name: "Core", arch: "arm64")
        let one = cache.key(unit, [("sources", .string("a")), ("flags", .string("-g"))])
        let two = cache.key(unit, [("flags", .string("-g")), ("sources", .string("a"))])
        XCTAssertEqual(one, two, "canonical form sorts the members")
        XCTAssertNotEqual(one, cache.key(unit, [("sources", .string("b")), ("flags", .string("-g"))]))
        let other = BuildCache.Unit(kind: .swiftModule, name: "Core", arch: "arm64e")
        XCTAssertNotEqual(one, cache.key(other, [("sources", .string("a")), ("flags", .string("-g"))]))
    }

    func testAUnitIdentifierCarriesNoPath() {
        let unit = BuildCache.Unit(kind: .clangObject, name: "app:Sources/Core/a.c", arch: "arm64")
        XCTAssertFalse(unit.identifier.contains("/"), unit.identifier)
        XCTAssertEqual(
            unit.identifier,
            BuildCache.Unit(kind: .clangObject, name: "app:Sources/Core/a.c", arch: "arm64").identifier
        )
        XCTAssertNotEqual(
            unit.identifier,
            BuildCache.Unit(kind: .clangObject, name: "app:Sources/Core/b.c", arch: "arm64").identifier
        )
    }

    func testStablePathSpellsTheRootsRelative() {
        let cache = BuildCache(
            root: URL(fileURLWithPath: "/tmp/cache"),
            projectRoot: "/var/jb/projects/App",
            installRoot: "/var/jb"
        )
        XCTAssertEqual(cache.stablePath("/var/jb/projects/App/Sources/a.swift"), "<project>/Sources/a.swift")
        XCTAssertEqual(cache.stablePath("/var/jb/usr/lib/libx.dylib"), "<root>/usr/lib/libx.dylib")
        XCTAssertEqual(cache.stablePath("/usr/lib/libsystem.dylib"), "/usr/lib/libsystem.dylib")
    }

    func testWhatWasStoredComesBack() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let cache = scratchCache(scratch)
        let unit = BuildCache.Unit(kind: .swiftModule, name: "Core", arch: "arm64")
        let object = try makeWork(scratch, "Core.o", "object bytes")
        let members: [(String, JSONDocument)] = [("sources", .string("a"))]
        let key = cache.key(unit, members)
        cache.store(unit, key: key, outputs: [.init(name: "Core.o", destination: object)], members: members)
        XCTAssertEqual(cache.misses, 1)

        try FileManager.default.removeItem(atPath: object)
        let outputs = [BuildCache.Output(name: "Core.o", destination: object)]
        XCTAssertTrue(cache.restore(unit, key: key, outputs: outputs))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: object)), Data("object bytes".utf8))
        XCTAssertEqual(cache.hits, 1)
        XCTAssertEqual(cache.misses, 1)
    }

    /// A file that does not match the digest it was stored with is compiled
    /// again, and the entry that held it is replaced rather than left to fail
    /// every later build.
    func testAnEntryThatDoesNotVerifyIsAMissAndIsReplaced() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let cache = scratchCache(scratch)
        let unit = BuildCache.Unit(kind: .swiftProduct, name: "app", arch: "arm64")
        let object = try makeWork(scratch, "app.o", "first bytes")
        let members: [(String, JSONDocument)] = [("sources", .string("a"))]
        let key = cache.key(unit, members)
        let outputs = [BuildCache.Output(name: "app.o", destination: object)]
        cache.store(unit, key: key, outputs: outputs, members: members)

        try Data("tampered".utf8).write(to: entry(cache, unit, key).appendingPathComponent("app.o"))
        try FileManager.default.removeItem(atPath: object)
        XCTAssertFalse(cache.restore(unit, key: key, outputs: outputs))
        XCTAssertEqual(cache.hits, 0)

        try Data("second bytes".utf8).write(to: URL(fileURLWithPath: object))
        cache.store(unit, key: key, outputs: outputs, members: members)
        try FileManager.default.removeItem(atPath: object)
        XCTAssertTrue(cache.restore(unit, key: key, outputs: outputs))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: object)), Data("second bytes".utf8))
    }

    func testPruneKeepsTheTwoMostRecentlyUsedEntriesOfAUnit() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let cache = scratchCache(scratch)
        let unit = BuildCache.Unit(kind: .swiftProduct, name: "app", arch: "arm64")
        var written: [URL] = []
        for index in 0 ..< 3 {
            let object = try makeWork(scratch, "app\(index).o", "bytes \(index)")
            let members: [(String, JSONDocument)] = [("sources", .string("\(index)"))]
            let key = cache.key(unit, members)
            cache.store(unit, key: key, outputs: [.init(name: "app.o", destination: object)], members: members)
            let directory = entry(cache, unit, key)
            written.append(directory)
            try setLastUsed(directory, index)
        }
        cache.prune()
        let remaining = try FileManager.default.contentsOfDirectory(
            at: cache.root.appendingPathComponent(unit.identifier, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: []
        ).map(\.lastPathComponent).sorted()
        XCTAssertEqual(remaining, [written[1].lastPathComponent, written[2].lastPathComponent].sorted())
    }

    /// A header a compile imports is an input like a source: the project
    /// description never names it one by one, and its bytes still count.
    func testAHeaderIsPartOfWhatACompileRead() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let cache = scratchCache(scratch)
        let headers = scratch.appendingPathComponent("headers/Shim", isDirectory: true)
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        let header = headers.appendingPathComponent("Shim.h")
        try Data("int a;\n".utf8).write(to: header)
        let before = CanonicalJSON.string(try cache.headerDigests([headers.path]))
        try Data("int a;\nint b;\n".utf8).write(to: header)
        let after = CanonicalJSON.string(try cache.headerDigests([headers.path]))
        XCTAssertNotEqual(before, after)
    }
}

/// Two builds of one project, on the Mac, with Xcode's tools: the second
/// compiles nothing it compiled the first time, and one edited source
/// compiles that unit alone.
final class IncrementalBuildTests: XCTestCase {
    func testASecondBuildReusesWhatDidNotChange() throws {
        guard let registry = macRegistry() else { throw XCTSkip("no iPhoneOS SDK on this Mac") }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.app/uikit-swift",
            name: "Cached App",
            values: [:],
            catalog: catalog,
            registry: registry
        )

        func build(_ label: String) throws -> Collector {
            let buildID = "mac-\(label)-\(UUID().uuidString.prefix(8).lowercased())"
            let inputs = try BuildInputs.resolve(
                buildID: buildID,
                projectID: created.projectID,
                configuration: .debug,
                store: store,
                catalog: catalog,
                registry: registry,
                installRoot: "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF",
                home: home.path,
                bootstrap: .roothide
            )
            let reporter = Collector()
            _ = try BuildService.build(inputs: inputs, store: store, reporter: reporter, cancellation: BuildCancellation())
            return reporter
        }

        let first = try build("first")
        let firstLog = first.lines.joined(separator: "\n")
        let firstCompile = try XCTUnwrap(first.lines.first { $0.hasPrefix("swift ") }, firstLog)
        XCTAssertTrue(firstCompile.contains(" in "), firstLog)
        XCTAssertTrue(first.lines.contains { $0.hasPrefix("compile cache: 0 unit(s) reused") }, firstLog)

        let second = try build("second")
        let secondLog = second.lines.joined(separator: "\n")
        XCTAssertTrue(second.lines.contains { $0.hasPrefix("swift ") && $0.hasSuffix("— reused") }, secondLog)
        XCTAssertTrue(second.lines.contains { $0.hasPrefix("compile cache: 1 unit(s) reused, 0 compiled") }, secondLog)

        let sources = try FileManager.default.contentsOfDirectory(
            at: created.root.appendingPathComponent("Sources"),
            includingPropertiesForKeys: nil,
            options: []
        )
        let edited = try XCTUnwrap(sources.first { $0.pathExtension == "swift" })
        try (Data(contentsOf: edited) + Data("\n// one more line\n".utf8)).write(to: edited)

        let third = try build("third")
        let thirdLog = third.lines.joined(separator: "\n")
        XCTAssertTrue(third.lines.contains { $0.hasPrefix("swift ") && $0.contains(" in ") }, thirdLog)
        XCTAssertTrue(third.lines.contains { $0.hasPrefix("compile cache: 0 unit(s) reused, 1 compiled") }, thirdLog)
        XCTAssertEqual(third.diagnostics.filter { $0.severity == .error }, [], thirdLog)
    }
}
