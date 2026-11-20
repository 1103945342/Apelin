import Darwin
import Foundation

/// Version ordering, relation parsing, index and status reading, and the
/// order a dependency closure installs in — the whole resolver, off a device.
@main
struct ResolutionChecks {
    static func main() throws {
        var count = 0
        func ok(_ condition: Bool, _ what: String) {
            count += 1
            guard condition else {
                print("FAILED: \(what)")
                exit(1)
            }
        }
        func passes<T>(_ what: String, _ body: () throws -> T) throws -> T {
            count += 1
            do {
                return try body()
            } catch {
                print("FAILED: \(what) threw \(error)")
                exit(1)
            }
        }
        func fails<T>(_ what: String, _ body: () throws -> T) {
            count += 1
            do {
                _ = try body()
                print("FAILED: \(what) answered instead of refusing")
                exit(1)
            } catch {}
        }
        func version(_ text: String) throws -> DebianVersion { try DebianVersion(text) }

        // Versions.
        try ok(version("1.0") < version("1.1"), "1.0 sorts before 1.1")
        try ok(version("1.0~rc1") < version("1.0"), "a tilde sorts before the release")
        try ok(version("1.0") < version("2.0"), "2.0 is newer")
        try ok(version("1:0.1") > version("2.0"), "the epoch wins over everything")
        try ok(version("1.0-2") > version("1.0-1"), "the revision counts")
        try ok(version("1.0") == version("1.0"), "equal versions are equal")
        try ok(version("1.0.10") > version("1.0.9"), "digits compare by value, not as text")
        try ok(version("1.0-a") > version("1.0-A"), "letters compare by ASCII")
        try ok(version("3.0.0").description == "3.0.0", "a version prints back as it was given")
        fails("an empty version") { try version("") }

        // Relations.
        let relation = try passes("a versioned relation") { PackageRelation.parse("libssl3 (>= 3.0.0)")! }
        ok(relation.name == "libssl3" && relation.op == .ge && relation.version == "3.0.0", "a relation keeps its operator and version")
        ok(relation.accepts("3.0.0") && relation.accepts("3.1") && !relation.accepts("2.9"), "a relation accepts only what it allows")
        let qualifier = try passes("an architecture qualifier") { PackageRelation.parse("libc6:any")! }
        ok(qualifier.name == "libc6", "an architecture qualifier is dropped")
        let groups = PackageRelation.groups("libssl3 (>= 3.0) | libssl1.1, zlib1g, libfoo (<< 2)")
        ok(groups.count == 3, "three relations, one with two alternatives: \(groups)")
        ok(groups[0].map(\.name) == ["libssl3", "libssl1.1"], "the first keeps both alternatives")
        ok(groups[2].first?.op == .lt, "a limit survives")

        // An index.
        let indexText = """
        Package: widget
        Version: 2.0
        Architecture: iphoneos-arm64
        Filename: ./Pool/widget.deb
        Size: 1234
        SHA256: \(String(repeating: "a", count: 64))
        Depends: libbar (>= 1.0) | libbaz, libqux

        Package: libbar
        Version: 1.5
        Architecture: iphoneos-arm64
        Filename: ./Pool/libbar.deb
        Size: 100
        SHA256: \(String(repeating: "b", count: 64))

        Package: libqux
        Version: 3.0
        Architecture: all
        Filename: ./Pool/libqux.deb
        Size: 10
        SHA256: \(String(repeating: "c", count: 64))

        Package: elsewhere
        Version: 1.0
        Architecture: iphoneos-arm
        Filename: ./Pool/elsewhere.deb
        Size: 10
        SHA256: \(String(repeating: "d", count: 64))

        """
        let index = IndexedPackage.parse(indexText, architecture: "iphoneos-arm64", source: "test")
        ok(index.map(\.name) == ["widget", "libbar", "libqux"], "the other architecture is left out: \(index.map(\.name))")
        ok(index[0].depends.count == 2, "widget asks for two relations")

        // Installed.
        let status = """
        Package: libbaz
        Status: install ok installed
        Version: 0.9
        Provides: libqux

        Package: gone
        Status: deinstall ok config-files
        Version: 1.0

        """
        let installed = InstalledPackages(status: status)
        ok(installed.versions == ["libbaz": "0.9"], "only an installed package counts: \(installed.versions)")
        ok(installed.provided["libqux"] == "0.9", "a provided name is remembered")
        ok(installed.satisfies(PackageRelation(name: "libbaz")), "an installed package satisfies its name")
        ok(!installed.satisfies(PackageRelation(name: "gone")), "a removed package satisfies nothing")

        // A plan: dependencies first, the alternative that is installed wins.
        let planner = PackagePlanner(index: index, installed: InstalledPackages())
        let plan = try passes("a plan for widget") { try planner.plan(installing: ["widget"]) }
        ok(plan.install.map(\.name) == ["libbar", "libqux", "widget"], "dependencies come first: \(plan.install.map(\.name))")

        // An installed alternative means the other one is never fetched.
        let withBar = PackagePlanner(index: index, installed: InstalledPackages(status: """
        Package: libbar
        Status: install ok installed
        Version: 1.5

        """))
        let shorter = try passes("a plan with libbar installed") { try withBar.plan(installing: ["widget"]) }
        ok(shorter.install.map(\.name) == ["libqux", "widget"], "only what is missing installs: \(shorter.install.map(\.name))")
        ok(shorter.alreadyInstalled.contains("libbar"), "the installed alternative is reported")

        // An installed target is left alone.
        let nothing = try passes("a plan for something installed") {
            try withBar.plan(installing: ["libbar"])
        }
        ok(nothing.install.isEmpty && nothing.alreadyInstalled == ["libbar"], "an installed target installs nothing")

        // Refusals.
        fails("a package no index offers") { try planner.plan(installing: ["nothing"]) }
        let missingDependency = [
            IndexedPackage(name: "lonely", version: "1.0", architecture: "all", filename: "./l.deb", size: 1,
                           sha256: String(repeating: "e", count: 64),
                           depends: [[PackageRelation(name: "absent")]]),
        ]
        fails("a dependency nothing offers") { try PackagePlanner(index: missingDependency, installed: InstalledPackages()).plan(installing: ["lonely"]) }

        // A cycle ends instead of spinning.
        let cycle = [
            IndexedPackage(name: "a", version: "1", architecture: "all", filename: "./a.deb", size: 1,
                           sha256: String(repeating: "f", count: 64), depends: [[PackageRelation(name: "b")]]),
            IndexedPackage(name: "b", version: "1", architecture: "all", filename: "./b.deb", size: 1,
                           sha256: String(repeating: "0", count: 64), depends: [[PackageRelation(name: "a")]]),
        ]
        let cycled = try passes("a cycle") { try PackagePlanner(index: cycle, installed: InstalledPackages()).plan(installing: ["a"]) }
        ok(Set(cycled.install.map(\.name)) == ["a", "b"], "both ends of the cycle are planned once: \(cycled.install.map(\.name))")

        // The newest version of a name wins.
        let twoVersions = [
            IndexedPackage(name: "x", version: "1.0", architecture: "all", filename: "./x1.deb", size: 1,
                           sha256: String(repeating: "1", count: 64)),
            IndexedPackage(name: "x", version: "1.10", architecture: "all", filename: "./x10.deb", size: 1,
                           sha256: String(repeating: "2", count: 64)),
        ]
        let newest = try passes("two versions of one name") {
            try PackagePlanner(index: twoVersions, installed: InstalledPackages()).plan(installing: ["x"])
        }
        ok(newest.install.first?.version == "1.10", "1.10 is newer than 1.0, not older: \(newest.install.first?.version ?? "-")")

        // The repositories the device has, and where their files are.
        let list = """
        # a comment
        deb [arch=iphoneos-arm64] https://apt.procurs.us/ 1900 main
        deb http://another.example/repo ./ .
        deb [arch=iphoneos-arm] https://other.example/ stable main

        """
        let repositories = PackageSources.parse(list: list, architecture: "iphoneos-arm64")
        ok(repositories.count == 2, "one deb822-eligible line each: \(repositories.count)")
        ok(repositories[0].uri == "https://apt.procurs.us", "a trailing slash is dropped")
        ok(repositories[0].indexName == "apt.procurs.us_dists_1900_main_binary-iphoneos-arm64_Packages",
           "the index name is the one APT writes: \(repositories[0].indexName)")
        ok(repositories[0].packagesURL == "https://apt.procurs.us/dists/1900/main/binary-iphoneos-arm64/Packages",
           "the index URL is built from the source")
        ok(repositories[0].url(for: "./Pool/x.deb") == "https://apt.procurs.us/Pool/x.deb",
           "a package URL drops the leading ./")
        ok(repositories[1].url(for: "/Pool/y.deb") == "http://another.example/repo/Pool/y.deb",
           "a package URL drops a leading slash")

        let deb822 = """
        Types: deb
        URIs: https://apt.procurs.us/
        Suites: 1900
        Components: main
        Architectures: iphoneos-arm64

        """
        let paragraphs = PackageSources.parse(deb822: deb822, architecture: "iphoneos-arm64")
        ok(paragraphs.count == 1, "one repository from one paragraph: \(paragraphs.count)")
        ok(paragraphs[0].indexName == repositories[0].indexName, "both spellings name the same index")
        ok(PackageSources.parse(deb822: deb822, architecture: "iphoneos-arm64e").isEmpty,
           "a repository for another architecture is left out")

        print("\(count) package resolution checks passed")
    }
}
