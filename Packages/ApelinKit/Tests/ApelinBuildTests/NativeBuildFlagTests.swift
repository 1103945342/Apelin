import ApelinBuild
import ApelinMachO
import ApelinProject
import Foundation
import XCTest

/// The rest of the native build's decisions, each on the real pipeline: a
/// pure C++ product linked by clang with the standard it asks for, two sources
/// whose names would collide once flattened, a source no language knows, and
/// the bridging header.
final class NativeBuildFlagTests: XCTestCase {
    /// No Swift anywhere: clang links, and a C++ product needs `-lc++` or the
    /// link fails with undefined `std::__1` symbols. `cxxStandard` and the
    /// configuration's `cxxFlags` reach every C++ file.
    func testAPureCxxProductLinksWithClangTheStandardAndTheRuntime() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-cxx-native")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "PureCXX",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/main.c"))
        try NativeBuild.write(Self.cxxMain, to: "Sources/main.cpp", in: root)
        try NativeBuild.write(Self.cxxHelper, to: "Sources/helper.cc", in: root)
        try NativeBuild.write(Self.cxxHeader, to: "Sources/helper.hpp", in: root)
        try NativeBuild.describe(Self.cxxProduct, cxxFlags: ["-DMIXED_CXX_FLAG=1"], in: root)

        let inputs = try NativeBuild.inputs(
            created,
            bootstrap: .rootless,
            label: "cxx",
            store: store,
            catalog: catalog,
            registry: registry,
            home: home
        )
        let reporter = Collector()
        let products: BuildProducts
        do {
            products = try BuildPipeline(inputs: inputs, reporter: reporter, cancellation: BuildCancellation()).run()
        } catch {
            XCTFail("\(error)\n\(reporter.lines.suffix(40).joined(separator: "\n"))")
            return
        }
        XCTAssertEqual(reporter.stages, ["compile:tool", "link:tool", "lipo:tool", "sign:tool"])
        XCTAssertEqual(reporter.diagnostics.filter { $0.severity == .error }, [])
        XCTAssertFalse(
            reporter.lines.contains { $0.hasPrefix("$ ") && $0.contains("swiftc") },
            "a product with no Swift never runs swiftc"
        )

        let product = try XCTUnwrap(products.product("tool"))
        let image = try MachOImage(contentsOfFile: product.executable)
        XCTAssertEqual(image.slices.map(\.architecture).sorted(), ["arm64", "arm64e"])
        XCTAssertTrue(image.slices.allSatisfy(\.isCodeSigned))

        let architectures = try XCTUnwrap(inputs.project.architectures[.rootless]).map(\.rawValue)
        for arch in architectures {
            let target = "-target \(arch)-apple-ios\(inputs.project.deploymentTarget)"
            for source in ["Sources/main.cpp", "Sources/helper.cc"] {
                let compile = try XCTUnwrap(
                    NativeBuild.command(in: reporter, target, "-x c++ -c \(source)"),
                    "no C++ compilation of \(source) for \(arch)"
                )
                XCTAssertTrue(compile.contains("-std=c++17"), "the product's standard: \(compile)")
                XCTAssertTrue(compile.contains("-DMIXED_CXX_FLAG=1"), "the configuration's cxxFlags: \(compile)")
            }
            let link = try XCTUnwrap(
                NativeBuild.command(in: reporter, target, "-o " + inputs.workDirectory.appendingPathComponent("link/tool").path),
                "no link for \(arch)"
            )
            XCTAssertTrue(
                link.hasPrefix("$ " + inputs.toolchain.tool("clang").path + " "),
                "a product with no Swift links with clang: \(link)"
            )
            XCTAssertTrue(link.contains("-lc++"), "C++ objects need the C++ runtime: \(link)")
            XCTAssertTrue(
                link.contains("-Xlinker -weak_framework -Xlinker CoreLocation"),
                "clang's link carries the weak framework too: \(link)"
            )
        }
    }

    /// `a/b.c` and `a__b.c` are two files whose names collide once flattened.
    /// Each keeps its own object, and both symbols reach the link.
    func testSourcesInDifferentFoldersKeepDifferentObjects() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-native-collision")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "Collision",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        try NativeBuild.write(Self.collisionMain, to: "Sources/main.c", in: root)
        try NativeBuild.write("int from_folder(void) { return 1; }\n", to: "Sources/a/b.c", in: root)
        try NativeBuild.write("int from_underscore(void) { return 2; }\n", to: "Sources/a__b.c", in: root)
        try NativeBuild.describe(Self.collisionProduct, in: root)

        let inputs = try NativeBuild.inputs(
            created,
            bootstrap: .rootless,
            label: "collision",
            store: store,
            catalog: catalog,
            registry: registry,
            home: home
        )
        let reporter = Collector()
        do {
            _ = try BuildPipeline(inputs: inputs, reporter: reporter, cancellation: BuildCancellation()).run()
        } catch {
            XCTFail("\(error)\n\(reporter.lines.suffix(40).joined(separator: "\n"))")
            return
        }
        XCTAssertEqual(reporter.diagnostics.filter { $0.severity == .error }, [])

        let architectures = try XCTUnwrap(inputs.project.architectures[.rootless]).map(\.rawValue)
        for arch in architectures {
            let target = "-target \(arch)-apple-ios\(inputs.project.deploymentTarget)"
            let folder = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-c Sources/a/b.c"))
            XCTAssertTrue(folder.contains("/clang/Sources/a/b.c.o"), "the object keeps its folder: \(folder)")
            let underscore = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-c Sources/a__b.c"))
            XCTAssertTrue(underscore.contains("/clang/Sources/a__b.c.o"), "the other keeps its own: \(underscore)")
        }
    }

    /// A file no compiler mode claims stops the build before any tool runs.
    func testASourceWithNoKnownLanguageStopsTheBuild() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-native-unsupported")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "UnsupportedSource",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        try NativeBuild.write("not a source\n", to: "Sources/notes.txt", in: root)
        // A pattern that spells no extension classifies every file it matches,
        // so the .txt is seen.
        var product = Self.collisionProduct
        product["sources"] = ["Sources/**"]
        try NativeBuild.describe(product, in: root)

        let inputs = try NativeBuild.inputs(
            created,
            bootstrap: .rootless,
            label: "unsupported",
            store: store,
            catalog: catalog,
            registry: registry,
            home: home
        )
        let reporter = Collector()
        XCTAssertThrowsError(try BuildPipeline(inputs: inputs, reporter: reporter, cancellation: BuildCancellation()).run()) { error in
            XCTAssertEqual(String(describing: error), "unsupported source language: Sources/notes.txt")
        }
        XCTAssertFalse(reporter.lines.contains { $0.hasPrefix("$ ") }, "no tool ran: \(reporter.lines)")
    }

    /// The bridging header is handed to Swift, and a product that names one
    /// without compiling Swift is refused with a reason.
    func testABridgingHeaderReachesSwiftAndIsRefusedWithoutSwift() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-native-bridge")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "Bridged",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/main.c"))
        try NativeBuild.write(Self.bridgeHeader, to: "Sources/Bridge.h", in: root)
        try NativeBuild.write(Self.bridgedSource, to: "Sources/bridged.c", in: root)
        try NativeBuild.write(Self.bridgedSwift, to: "Sources/main.swift", in: root)
        try NativeBuild.describe(Self.bridgeProduct, in: root)

        let inputs = try NativeBuild.inputs(
            created,
            bootstrap: .rootless,
            label: "bridge",
            store: store,
            catalog: catalog,
            registry: registry,
            home: home
        )
        let reporter = Collector()
        do {
            _ = try BuildPipeline(inputs: inputs, reporter: reporter, cancellation: BuildCancellation()).run()
        } catch {
            XCTFail("\(error)\n\(reporter.lines.suffix(40).joined(separator: "\n"))")
            return
        }
        XCTAssertEqual(reporter.diagnostics.filter { $0.severity == .error }, [])
        let bridge = root.appendingPathComponent("Sources/Bridge.h").path
        let swift = try XCTUnwrap(
            NativeBuild.command(in: reporter, "-module-name Bridged", "-import-objc-header"),
            "\(reporter.lines.suffix(20).joined(separator: "\n"))"
        )
        XCTAssertTrue(swift.contains("-import-objc-header \(bridge)"), swift)

        // The same product without a Swift file: refused, and before any tool.
        var withoutSwift = Self.bridgeProduct
        withoutSwift["sources"] = ["Sources/**/*.c"]
        try NativeBuild.describe(withoutSwift, in: root)
        let refused = try NativeBuild.inputs(
            created,
            bootstrap: .rootless,
            label: "bridge-refused",
            store: store,
            catalog: catalog,
            registry: registry,
            home: home
        )
        let silent = Collector()
        XCTAssertThrowsError(try BuildPipeline(inputs: refused, reporter: silent, cancellation: BuildCancellation()).run()) { error in
            XCTAssertTrue(
                String(describing: error).contains("bridgingHeader requires Swift sources in this product"),
                "\(error)"
            )
        }
        XCTAssertFalse(silent.lines.contains { $0.hasPrefix("$ ") }, "no tool ran: \(silent.lines)")
    }

    private static let cxxMain = """
    #include <cstdio>
    #include <string>

    #include "helper.hpp"

    int main() {
        std::string greeting = helper_greeting();
        std::printf("%s %d\\n", greeting.c_str(), MIXED_CXX_FLAG);
        return 0;
    }
    """

    private static let cxxHelper = """
    #include "helper.hpp"

    #include <string>

    std::string helper_greeting() { return std::string("cxx"); }
    """

    private static let cxxHeader = """
    #ifndef APELIN_MIXED_CXX_HELPER_H
    #define APELIN_MIXED_CXX_HELPER_H

    #include <string>

    std::string helper_greeting();

    #endif
    """

    private static let cxxProduct: [String: Any] = [
        "id": "tool",
        "type": "executable",
        "name": "CxxTool",
        "sources": ["Sources/**/*.cpp", "Sources/**/*.cc"],
        "headerSearchPaths": ["Sources"],
        "entitlements": "Packaging/Tool.entitlements",
        "cxxStandard": "c++17",
        "weakFrameworks": ["CoreLocation"],
    ]

    private static let collisionMain = """
    int from_folder(void);
    int from_underscore(void);

    int main(void) {
        return from_folder() + from_underscore();
    }
    """

    private static let collisionProduct: [String: Any] = [
        "id": "tool",
        "type": "executable",
        "name": "Collision",
        "sources": ["Sources/**/*.c"],
        "headerSearchPaths": ["Sources"],
        "entitlements": "Packaging/Tool.entitlements",
    ]

    private static let bridgeHeader = """
    #ifndef APELIN_MIXED_BRIDGE_H
    #define APELIN_MIXED_BRIDGE_H

    int bridged_value(void);

    #endif
    """

    private static let bridgedSource = """
    int bridged_value(void) {
        return 42;
    }
    """

    private static let bridgedSwift = """
    import Foundation

    print("bridged " + String(bridged_value()))
    """

    private static let bridgeProduct: [String: Any] = [
        "id": "tool",
        "type": "executable",
        "name": "Bridged",
        "sources": ["Sources/**/*.swift", "Sources/**/*.c"],
        "headerSearchPaths": ["Sources"],
        "bridgingHeader": "Sources/Bridge.h",
        "entitlements": "Packaging/Tool.entitlements",
    ]
}
