@testable import ApelinBuild
import ApelinProject
import Foundation
import XCTest

/// Old build folders: what the app keeps, and what goes when the next build
/// starts.
final class BuildCleanupTests: XCTestCase {
    private func makeScratch() throws -> (scratch: URL, builds: URL) {
        let scratch = try scratchDirectory()
        let builds = scratch.appendingPathComponent("Builds", isDirectory: true)
        try FileManager.default.createDirectory(at: builds, withIntermediateDirectories: true)
        return (scratch, builds)
    }

    /// A build folder as a finished build leaves it: a package inside, and a
    /// modification date `hoursAgo` in the past.
    private func makeBuild(
        _ builds: URL,
        _ project: String,
        _ name: String,
        hoursAgo: Double,
        bytes: Int = 4096,
    ) throws {
        let directory = builds
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: directory.appendingPathComponent("package.ipa"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-hoursAgo * 3600)],
            ofItemAtPath: directory.path,
        )
    }

    private func remaining(_ builds: URL, _ project: String) -> [String] {
        let path = builds.appendingPathComponent(project, isDirectory: true).path
        return ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    func testTheTwoNewestStayAndOlderBuildsGo() throws {
        let (scratch, builds) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (index, hours) in [2.0, 3.0, 4.0, 5.0].enumerated() {
            try makeBuild(builds, "p", "b\(index)", hoursAgo: hours)
        }
        var lines: [String] = []
        BuildCleanup.prune(projectID: "p", keeping: "current", in: builds) { lines.append($0) }
        XCTAssertEqual(remaining(builds, "p"), ["b0", "b1"])
        XCTAssertEqual(lines, ["removed 2 old builds, 8 KB"])
    }

    func testTwoBuildsAreLeftAlone() throws {
        let (scratch, builds) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try makeBuild(builds, "p", "b0", hoursAgo: 2)
        try makeBuild(builds, "p", "b1", hoursAgo: 3)
        var lines: [String] = []
        BuildCleanup.prune(projectID: "p", keeping: "current", in: builds) { lines.append($0) }
        XCTAssertEqual(remaining(builds, "p"), ["b0", "b1"])
        XCTAssertTrue(lines.isEmpty)
    }

    /// A folder written in the last hour may belong to a build running in
    /// another worker, and is never removed.
    func testAFolderWrittenJustNowIsKept() throws {
        let (scratch, builds) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try makeBuild(builds, "p", "fresh", hoursAgo: 0)
        try makeBuild(builds, "p", "b0", hoursAgo: 2)
        try makeBuild(builds, "p", "b1", hoursAgo: 3)
        try makeBuild(builds, "p", "b2", hoursAgo: 4)
        BuildCleanup.prune(projectID: "p", keeping: "current", in: builds) { _ in }
        XCTAssertEqual(remaining(builds, "p"), ["b0", "fresh"])
    }

    func testTheBuildStartingIsNeverRemoved() throws {
        let (scratch, builds) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (index, hours) in [2.0, 3.0, 4.0, 5.0].enumerated() {
            try makeBuild(builds, "p", "b\(index)", hoursAgo: hours)
        }
        BuildCleanup.prune(projectID: "p", keeping: "b3", in: builds) { _ in }
        XCTAssertEqual(remaining(builds, "p"), ["b0", "b1", "b3"])
    }

    func testAProjectWithNoBuildsFolderIsLeftAlone() throws {
        let (scratch, builds) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        BuildCleanup.prune(projectID: "missing", keeping: "current", in: builds) { _ in }
        XCTAssertEqual(remaining(builds, "missing"), [])
    }
}
