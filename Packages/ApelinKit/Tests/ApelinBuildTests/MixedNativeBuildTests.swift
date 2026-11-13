import ApelinBuild
import ApelinMachO
import ApelinProject
import Foundation
import XCTest

/// One executable whose sources are Swift, C, Objective-C, C++ and
/// Objective-C++ at once, built by the real pipeline — clang, swiftc, ld,
/// lipo and the ad-hoc signer — for both bootstraps.
///
/// Swift is compiled first and emits `<ProductName>-Swift.h`; the
/// Objective-C file imports it and calls a Swift `@objc` class, while Swift's
/// `main.swift` calls the C, Objective-C, C++ and Objective-C++ wrappers. The
/// link goes through swiftc because there is Swift, adds `-lc++` for the C++
/// objects, and a static library beside the product must be found through
/// `librarySearchPaths`. Nothing here is packaged.
final class MixedNativeBuildTests: XCTestCase {
    func testOneExecutableOfEveryNativeLanguageBuildsForBothBootstraps() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-mixed-native")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "MixedNative",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        // The template's C entry point goes: `main.swift` is the entry point
        // here, and the C file would give the linker a second `main`.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/main.c"))
        try NativeBuild.write(Self.mainSwift, to: "Sources/main.swift", in: root)
        try NativeBuild.write(Self.greeterSwift, to: "Sources/Greeter.swift", in: root)
        try NativeBuild.write(Self.objcHeader, to: "Sources/objc_wrapper.h", in: root)
        try NativeBuild.write(Self.cSource, to: "Sources/c_wrapper.c", in: root)
        try NativeBuild.write(Self.objcSource, to: "Sources/objc_wrapper.m", in: root)
        try NativeBuild.write(Self.cxxSource, to: "Sources/cpp_wrapper.cpp", in: root)
        try NativeBuild.write(Self.objcxxSource, to: "Sources/objcxx_wrapper.mm", in: root)
        try NativeBuild.write(Self.fixtureSource, to: "Fixture/fixture.c", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try NativeBuild.describe(Self.mixedProduct, in: root)
        let deploymentTarget = try store.locate(created.projectID).project.deploymentTarget
        try NativeBuild.makeStaticLibrary(for: [.arm64, .arm64e], deploymentTarget: deploymentTarget, in: root, scratch: scratch)

        let sources = root.appendingPathComponent("Sources").path
        let frameworks = root.appendingPathComponent("Frameworks").path
        let libraries = root.appendingPathComponent("Fixture/lib").path

        for bootstrap in [Bootstrap.roothide, .rootless] {
            let inputs = try NativeBuild.inputs(
                created,
                bootstrap: bootstrap,
                label: "mixed",
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
                XCTFail("\(bootstrap.rawValue): \(error)\n\(reporter.lines.suffix(40).joined(separator: "\n"))")
                continue
            }
            XCTAssertEqual(reporter.stages, ["compile:tool", "link:tool", "lipo:tool", "sign:tool"], "\(bootstrap.rawValue)")
            XCTAssertEqual(reporter.diagnostics.filter { $0.severity == .error }, [], "\(bootstrap.rawValue)")

            let product = try XCTUnwrap(products.product("tool"))
            let image = try MachOImage(contentsOfFile: product.executable)
            XCTAssertEqual(
                image.slices.map(\.architecture).sorted(),
                bootstrap == .rootless ? ["arm64", "arm64e"] : ["arm64e"],
                "\(bootstrap.rawValue): the slices this bootstrap builds"
            )
            XCTAssertTrue(image.slices.allSatisfy(\.isCodeSigned), "\(bootstrap.rawValue): every slice is signed")

            let architectures = try XCTUnwrap(inputs.project.architectures[bootstrap]).map(\.rawValue)
            XCTAssertEqual(architectures.sorted(), bootstrap == .rootless ? ["arm64", "arm64e"] : ["arm64e"])

            for arch in architectures {
                let target = "-target \(arch)-apple-ios\(inputs.project.deploymentTarget)"
                let swiftDirectory = inputs.workDirectory.appendingPathComponent("obj/tool/\(arch)/swift").path

                // Swift first, with its Objective-C interface beside it.
                let swift = try XCTUnwrap(
                    NativeBuild.command(in: reporter, target, "-module-name Mixed", "-emit-objc-header"),
                    "no Swift compilation for \(arch):\n\(reporter.lines.joined(separator: "\n"))"
                )
                XCTAssertTrue(
                    swift.contains("-emit-objc-header-path \(swiftDirectory)/Mixed-Swift.h"),
                    "the generated header is where the Objective-C files look for it: \(swift)"
                )
                XCTAssertTrue(swift.contains("-I \(sources)"), "header search paths reach Swift: \(swift)")
                XCTAssertTrue(swift.contains("-Xcc -I\(sources)"), "header search paths reach Swift's clang importer: \(swift)")
                XCTAssertTrue(swift.contains("-F \(frameworks)"), "framework search paths reach Swift's clang importer: \(swift)")
                let header = try String(contentsOfFile: swiftDirectory + "/Mixed-Swift.h", encoding: .utf8)
                XCTAssertTrue(header.contains("@interface Greeter"), "the generated header declares the Swift class")

                // Each native file by its own language; ARC only for the
                // Objective-C ones.
                let c = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-x c -c Sources/c_wrapper.c"))
                XCTAssertFalse(c.contains("-fobjc-arc"), "C is not ARC: \(c)")
                XCTAssertTrue(c.contains("-isysroot \(inputs.sdk.path)"), "clang is given an explicit iOS target: \(c)")
                let objc = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-x objective-c -c Sources/objc_wrapper.m"))
                XCTAssertTrue(objc.contains("-fobjc-arc"), "Objective-C is ARC: \(objc)")
                XCTAssertTrue(objc.contains("-I" + swiftDirectory), "the Objective-C file finds <Mixed-Swift.h>: \(objc)")
                XCTAssertTrue(objc.contains("-F" + frameworks), "framework search paths reach the compile: \(objc)")
                let cxx = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-x c++ -c Sources/cpp_wrapper.cpp"))
                XCTAssertFalse(cxx.contains("-fobjc-arc"), "C++ is not ARC: \(cxx)")
                let objcxx = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-x objective-c++ -c Sources/objcxx_wrapper.mm"))
                XCTAssertTrue(objcxx.contains("-fobjc-arc"), "Objective-C++ is ARC: \(objcxx)")

                // Swift is compiled before any native file needs its header.
                let swiftIndex = try XCTUnwrap(reporter.lines.firstIndex(of: swift))
                let objcIndex = try XCTUnwrap(reporter.lines.firstIndex(of: objc))
                XCTAssertLessThan(swiftIndex, objcIndex, "Swift's interface is emitted before clang runs")

                // The link: swiftc's, with the C++ runtime, the search paths,
                // the weak framework and the static library.
                let link = try XCTUnwrap(
                    NativeBuild.command(in: reporter, target, "-o " + inputs.workDirectory.appendingPathComponent("link/tool").path),
                    "no link for \(arch)"
                )
                XCTAssertTrue(
                    link.hasPrefix("$ " + inputs.toolchain.tool("swiftc").path + " "),
                    "a product with Swift links with swiftc: \(link)"
                )
                XCTAssertTrue(link.contains("-lc++"), "the C++ objects need the C++ runtime: \(link)")
                XCTAssertTrue(link.contains("-L \(libraries)"), "library search paths reach the link: \(link)")
                XCTAssertTrue(link.contains("-lmixedfixture"), "the fixture library is linked: \(link)")
                XCTAssertTrue(link.contains("-F \(frameworks)"), "framework search paths reach the link: \(link)")
                XCTAssertTrue(link.contains("-framework Foundation"), link)
                XCTAssertTrue(
                    link.contains("-Xlinker -weak_framework -Xlinker CoreLocation"),
                    "a weak framework is weak in both drivers: \(link)"
                )
            }
        }
    }

    /// Swift's top-level entry point: it calls each wrapper, and the
    /// Objective-C one calls back into Swift through the generated header.
    private static let mainSwift = """
    import Foundation

    @_silgen_name("c_value") func c_value() -> UnsafePointer<CChar>
    @_silgen_name("objc_value") func objc_value() -> UnsafePointer<CChar>
    @_silgen_name("cpp_value") func cpp_value() -> UnsafePointer<CChar>
    @_silgen_name("objcxx_value") func objcxx_value() -> UnsafePointer<CChar>
    @_silgen_name("mixed_fixture_value") func mixed_fixture_value() -> Int32

    let names = [c_value(), objc_value(), cpp_value(), objcxx_value()].map { String(cString: $0) }
    print("mixed: " + names.joined(separator: "+") + " fixture=" + String(mixed_fixture_value()))
    print(Greeter(name: "Apelin").greeting())
    """

    private static let greeterSwift = """
    import Foundation

    @objc public final class Greeter: NSObject {
        @objc public let name: String

        @objc public init(name: String) {
            self.name = name
            super.init()
        }

        @objc public func greeting() -> String {
            return "Hello, " + name
        }
    }
    """

    private static let objcHeader = """
    #ifndef APELIN_MIXED_OBJC_WRAPPER_H
    #define APELIN_MIXED_OBJC_WRAPPER_H

    #ifdef __cplusplus
    extern "C" {
    #endif

    const char *objc_value(void);

    #ifdef __cplusplus
    }
    #endif

    #endif
    """

    private static let cSource = """
    #include "objc_wrapper.h"

    const char *c_value(void) {
        return "c";
    }
    """

    private static let objcSource = """
    #import <Foundation/Foundation.h>
    #import <Mixed-Swift.h>

    #include <string.h>

    #include "objc_wrapper.h"

    const char *objc_value(void) {
        static char buffer[64];
        Greeter *greeter = [[Greeter alloc] initWithName:@"Apelin"];
        strlcpy(buffer, [[greeter greeting] UTF8String], sizeof(buffer));
        return buffer;
    }
    """

    private static let cxxSource = """
    #include <string>

    #include "objc_wrapper.h"

    extern "C" const char *cpp_value(void) {
        static const std::string value = std::string("cp") + "p";
        return value.c_str();
    }
    """

    private static let objcxxSource = """
    #import <Foundation/Foundation.h>

    #include <string>

    #include "objc_wrapper.h"

    extern "C" const char *objcxx_value(void) {
        static const std::string value = std::string("objc") + "xx";
        return value.c_str();
    }
    """

    private static let fixtureSource = """
    int mixed_fixture_value(void) {
        return 7;
    }
    """

    private static let mixedProduct: [String: Any] = [
        "id": "tool",
        "type": "executable",
        "name": "Mixed",
        "sources": ["Sources/**/*.swift", "Sources/**/*.c", "Sources/**/*.m", "Sources/**/*.cpp", "Sources/**/*.mm"],
        "headerSearchPaths": ["Sources"],
        "entitlements": "Packaging/Tool.entitlements",
        "frameworkSearchPaths": ["Frameworks"],
        "librarySearchPaths": ["Fixture/lib"],
        "frameworks": ["Foundation"],
        "weakFrameworks": ["CoreLocation"],
        "libraries": ["mixedfixture"],
        "objcARC": true,
    ]
}
