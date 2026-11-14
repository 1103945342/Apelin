import ApelinBuild
import ApelinMachO
import ApelinProject
import Foundation
import XCTest

/// Swift's own C++ interop: a project's C++ is imported through a
/// `module.modulemap` in one of its header search paths, and the product's
/// Swift constructs a C++ type and calls it directly — no `extern "C"`, no
/// `@_silgen_name`, no bridging header.
///
/// `cxxInterop` on a product or a Swift module is what turns the importer on:
/// `-cxx-interoperability-mode=default`, the standard as `-Xcc -std=…`
/// (c++17 when none is named), and the header search paths for the modulemap.
/// A module's settings reach the products that use it, so a consumer never
/// repeats them. The iOS binary is built and signed here, never run: CI has no
/// iOS device, and the device run is `Scripts/test-mixed-build-device.py`.
final class CXXInteropBuildTests: XCTestCase {
    /// `Counter(40).add(2)`, where `add` is not inline: Swift imports the C++
    /// type through `CxxCounter`, and the link needs the product's own C++
    /// object and the C++ runtime.
    func testSwiftConstructsANonInlineCXXTypeThroughAModulemap() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-cxx-interop")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "InteropNative",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/main.c"))
        try NativeBuild.write(Self.interopMain, to: "Sources/main.swift", in: root)
        try NativeBuild.write(Self.counterSource, to: "Sources/counter.cpp", in: root)
        try NativeBuild.write(Self.counterHeader, to: "Include/counter.hpp", in: root)
        try NativeBuild.write(Self.counterModuleMap, to: "Include/module.modulemap", in: root)
        try NativeBuild.describe(Self.interopProduct, in: root)

        let inputs = try NativeBuild.inputs(
            created,
            bootstrap: .rootless,
            label: "interop",
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

        let product = try XCTUnwrap(products.product("tool"))
        let image = try MachOImage(contentsOfFile: product.executable)
        XCTAssertEqual(image.slices.map(\.architecture).sorted(), ["arm64", "arm64e"])
        XCTAssertTrue(image.slices.allSatisfy(\.isCodeSigned))

        // The fixture is Swift calling C++ as Swift, and nothing else.
        XCTAssertTrue(Self.interopMain.contains("import CxxCounter"))
        XCTAssertTrue(Self.interopMain.contains("Counter(40)"))
        XCTAssertFalse(Self.interopMain.contains("@_silgen_name"), "no silgen shim")
        XCTAssertFalse(Self.interopMain.contains("extern \"C\""), "no extern \"C\" wrapper")

        let include = root.appendingPathComponent("Include").path
        let architectures = try XCTUnwrap(inputs.project.architectures[.rootless]).map(\.rawValue)
        for arch in architectures {
            let target = "-target \(arch)-apple-ios\(inputs.project.deploymentTarget)"
            let swift = try XCTUnwrap(
                NativeBuild.command(in: reporter, target, "-module-name Interop"),
                "no Swift compilation for \(arch)"
            )
            XCTAssertTrue(swift.contains("-cxx-interoperability-mode=default"), swift)
            XCTAssertTrue(swift.contains("-Xcc -std=c++17"), "c++17 when the project names none: \(swift)")
            XCTAssertTrue(swift.contains("-Xcc -I\(include)"), "the modulemap's search path reaches clang: \(swift)")
            XCTAssertFalse(swift.contains("-import-objc-header"), "interop replaces the bridging header: \(swift)")
            for identity in ["APELIN_BUILD_ID", "APELIN_PACKAGE_ID", "APELIN_VERSION"] {
                XCTAssertFalse(
                    swift.contains("-Xcc -D" + identity),
                    "the importer never sees \(identity): clang keys its module cache on the macro set, so "
                        + "every build would rebuild the imported standard library: \(swift)"
                )
            }

            // The C++ file is still the product's own source, compiled by clang.
            let counter = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-x c++ -c Sources/counter.cpp"))
            XCTAssertTrue(counter.contains("-I" + include), "the native C++ compile sees the header: \(counter)")

            let link = try XCTUnwrap(
                NativeBuild.command(in: reporter, target, "-o " + inputs.workDirectory.appendingPathComponent("link/tool").path),
                "no link for \(arch)"
            )
            XCTAssertTrue(link.contains("-lc++"), "the imported C++ needs the C++ runtime: \(link)")
        }
    }

    /// A header-only C++ module: the product compiles no C++ file at all, and
    /// still builds — Swift calls the inline members the header declares.
    func testAHeaderOnlyCXXModuleNeedsNoNativeSource() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-cxx-header-only")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "InteropHeaderOnly",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/main.c"))
        try NativeBuild.write(Self.onlyMain, to: "Sources/main.swift", in: root)
        try NativeBuild.write(Self.onlyHeader, to: "Include/only.hpp", in: root)
        try NativeBuild.write(Self.onlyModuleMap, to: "Include/module.modulemap", in: root)
        var product = Self.interopProduct
        product["name"] = "OnlyHeader"
        product["sources"] = ["Sources/**/*.swift"]
        try NativeBuild.describe(product, in: root)

        let inputs = try NativeBuild.inputs(
            created,
            bootstrap: .roothide,
            label: "header-only",
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
        XCTAssertFalse(
            reporter.lines.contains { $0.hasPrefix("$ ") && $0.contains("/clang ") },
            "no C++ file means no clang invocation: \(reporter.lines.filter { $0.hasPrefix("$ ") })"
        )
        let include = root.appendingPathComponent("Include").path
        let target = "-target arm64e-apple-ios\(inputs.project.deploymentTarget)"
        let swift = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-module-name OnlyHeader"))
        XCTAssertTrue(swift.contains("-cxx-interoperability-mode=default"), swift)
        XCTAssertTrue(swift.contains("-Xcc -I\(include)"), swift)

        // Calling the header's `new`/`delete` puts C++ runtime symbols in the
        // product, and interop alone must bring the runtime to the link.
        let link = try XCTUnwrap(
            NativeBuild.command(in: reporter, target, "-o " + inputs.workDirectory.appendingPathComponent("link/tool").path),
            "no link"
        )
        XCTAssertTrue(link.contains("-lc++"), "an interop product links the C++ runtime: \(link)")

        // And the object really asks the C++ runtime for storage, so the
        // assertion above is about a dependency, not a flag passed along.
        let object = inputs.workDirectory.appendingPathComponent("obj/tool/arm64e/swift/OnlyHeader.o").path
        let symbols = try runTool("/usr/bin/nm", ["-u", object])
        XCTAssertEqual(symbols.status, 0, symbols.output)
        XCTAssertTrue(symbols.output.contains("__Znw"), "the Swift object calls operator new: \(symbols.output)")
    }

    /// A Swift module carries its own interop settings, and the product that
    /// links it inherits them: without `-cxx-interoperability-mode` and the
    /// module's standard and header path, the product's
    /// `import CxxKit` fails with "missing required module".
    func testAModulesInteropSettingsReachTheProductThatUsesIt() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-cxx-chain")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "InteropChain",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/main.c"))
        try NativeBuild.write(Self.chainMain, to: "Sources/main.swift", in: root)
        try NativeBuild.write(Self.chainCounterSource, to: "Sources/counter.cpp", in: root)
        try NativeBuild.write(Self.counterHeader, to: "Vendor/CxxKit/Include/counter.hpp", in: root)
        try NativeBuild.write(Self.counterModuleMap, to: "Vendor/CxxKit/Include/module.modulemap", in: root)
        try NativeBuild.write(Self.kitSwift, to: "Vendor/CxxKit/Sources/Kit.swift", in: root)
        // The product names neither `cxxInterop`, a standard, nor the module's
        // header path: only the module does, and all three must reach the
        // product. Its C++ file finds the header by a relative include, so no
        // header search path of its own can stand in for the module's.
        var product = Self.interopProduct
        product["name"] = "Chain"
        product["swiftModules"] = ["CxxKit"]
        product.removeValue(forKey: "cxxInterop")
        product.removeValue(forKey: "headerSearchPaths")
        try describe(product, modules: [Self.cxxKitModule], in: root)

        let inputs = try NativeBuild.inputs(
            created,
            bootstrap: .roothide,
            label: "chain",
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
        let target = "-target arm64e-apple-ios\(inputs.project.deploymentTarget)"
        let include = root.appendingPathComponent("Vendor/CxxKit/Include").path

        // The module itself.
        let module = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-module-name CxxKit"))
        XCTAssertTrue(module.contains("-cxx-interoperability-mode=default"), module)
        XCTAssertTrue(module.contains("-Xcc -std=c++20"), "the module's own standard: \(module)")

        // And the product, which declares none of it.
        let consumer = try XCTUnwrap(
            NativeBuild.command(in: reporter, target, "-module-name Chain"),
            "the product's Swift compilation"
        )
        XCTAssertTrue(consumer.contains("-cxx-interoperability-mode=default"), "interop reaches the consumer: \(consumer)")
        XCTAssertTrue(consumer.contains("-Xcc -std=c++20"), "so does the module's standard: \(consumer)")
        XCTAssertTrue(consumer.contains("-Xcc -I\(include)"), "and the modulemap's search path: \(consumer)")
    }

    /// A product that turns interop off where a module it uses needs it is
    /// refused, before anything is linked.
    func testAProductTurningInteropOffAgainstAModuleIsRefused() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-cxx-conflict")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "InteropConflict",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/main.c"))
        try NativeBuild.write(Self.chainMain, to: "Sources/main.swift", in: root)
        try NativeBuild.write(Self.chainCounterSource, to: "Sources/counter.cpp", in: root)
        try NativeBuild.write(Self.counterHeader, to: "Vendor/CxxKit/Include/counter.hpp", in: root)
        try NativeBuild.write(Self.counterModuleMap, to: "Vendor/CxxKit/Include/module.modulemap", in: root)
        try NativeBuild.write(Self.kitSwift, to: "Vendor/CxxKit/Sources/Kit.swift", in: root)
        var product = Self.interopProduct
        product["name"] = "Chain"
        product["swiftModules"] = ["CxxKit"]
        product["cxxInterop"] = false
        product.removeValue(forKey: "headerSearchPaths")
        try describe(product, modules: [Self.cxxKitModule], in: root)

        let reporter = Collector()
        // The refusal may come from resolving the project or from the build
        // itself; either way nothing is linked.
        XCTAssertThrowsError(try {
            let inputs = try NativeBuild.inputs(
                created,
                bootstrap: .roothide,
                label: "conflict",
                store: store,
                catalog: catalog,
                registry: registry,
                home: home
            )
            _ = try BuildPipeline(inputs: inputs, reporter: reporter, cancellation: BuildCancellation()).run()
        }()) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.lowercased().contains("interop"), text)
            XCTAssertTrue(text.contains("CxxKit"), "the refusal names the module: \(text)")
        }
        XCTAssertFalse(reporter.stages.contains("link:tool"), "nothing is linked: \(reporter.stages)")
    }

    /// A C module beside a C++ module, both in one `module.modulemap`: the
    /// C declarations are `[extern_c]`, so interop leaves them C and the C
    /// file beside them links. Swift imports both and calls both.
    func testACModuleAndACXXModuleLiveTogetherThroughAModulemap() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-cxx-both")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "InteropBoth",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/main.c"))
        try NativeBuild.write(Self.bothMain, to: "Sources/main.swift", in: root)
        try NativeBuild.write(Self.valuesSource, to: "Sources/cvalue.c", in: root)
        try NativeBuild.write(Self.counterSource, to: "Sources/counter.cpp", in: root)
        try NativeBuild.write(Self.valuesHeader, to: "Include/values.h", in: root)
        try NativeBuild.write(Self.counterHeader, to: "Include/counter.hpp", in: root)
        try NativeBuild.write(Self.bothModuleMap, to: "Include/module.modulemap", in: root)
        var product = Self.interopProduct
        product["name"] = "Both"
        product["sources"] = ["Sources/**/*.swift", "Sources/**/*.c", "Sources/**/*.cpp"]
        try NativeBuild.describe(product, in: root)

        let inputs = try NativeBuild.inputs(
            created,
            bootstrap: .roothide,
            label: "both",
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
        let artifact = try XCTUnwrap(products.product("tool"))
        let image = try MachOImage(contentsOfFile: artifact.executable)
        XCTAssertTrue(image.slices.allSatisfy(\.isCodeSigned))

        let include = root.appendingPathComponent("Include").path
        let target = "-target arm64e-apple-ios\(inputs.project.deploymentTarget)"
        let swift = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-module-name Both"))
        XCTAssertTrue(swift.contains("-cxx-interoperability-mode=default"), swift)
        XCTAssertTrue(swift.contains("-Xcc -I\(include)"), "both modulemaps are found: \(swift)")
        _ = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-x c -c Sources/cvalue.c"))
        _ = try XCTUnwrap(NativeBuild.command(in: reporter, target, "-x c++ -c Sources/counter.cpp"))
        let link = try XCTUnwrap(
            NativeBuild.command(in: reporter, target, "-o " + inputs.workDirectory.appendingPathComponent("link/tool").path)
        )
        XCTAssertTrue(link.contains("-lc++"), link)
    }

    /// A bridging header and C++ interop in one product are refused: Swift's
    /// importer drops the header while the interop mode is on, silently, so
    /// every declaration in it would be missing from Swift.
    ///
    /// The document validation refuses the same combination before a build is
    /// resolved; this decodes the project without it, so the pipeline's own
    /// guard is what fails here.
    func testABridgingHeaderBesideInteropIsRefused() throws {
        let registry = try NativeBuild.requireTools()
        let scratch = try scratchDirectory("apelin-cxx-bridge")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.cli/c",
            name: "InteropBridge",
            values: [:],
            catalog: catalog,
            registry: registry
        )
        let root = created.root
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/main.c"))
        try NativeBuild.write(Self.bridgeOnlyMain, to: "Sources/main.swift", in: root)
        try NativeBuild.write(Self.counterSource, to: "Sources/counter.cpp", in: root)
        try NativeBuild.write(Self.bridgeHeaderOnly, to: "Sources/Bridge.h", in: root)
        try NativeBuild.write(Self.counterHeader, to: "Include/counter.hpp", in: root)
        try NativeBuild.write(Self.counterModuleMap, to: "Include/module.modulemap", in: root)
        var product = Self.interopProduct
        product["name"] = "Bridged"
        product["bridgingHeader"] = "Sources/Bridge.h"
        try NativeBuild.describe(product, in: root)

        // The store refuses it first: validation names the same two facts.
        XCTAssertThrowsError(try NativeBuild.inputs(
            created,
            bootstrap: .roothide,
            label: "bridge-store",
            store: store,
            catalog: catalog,
            registry: registry,
            home: home
        )) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("cannot be combined with C++ interop"), text)
            XCTAssertTrue(text.contains("module.modulemap"), text)
        }

        let toolchain = try XCTUnwrap(try registry.toolchains().first)
        let sdk = try XCTUnwrap(try registry.sdks().first)
        let inputs = BuildInputs(
            buildID: "bridge",
            projectRoot: root,
            project: try JSONDecoder().decode(
                ProjectDocument.self,
                from: Data(contentsOf: root.appendingPathComponent("apelin-project.json"))
            ),
            configuration: .debug,
            bootstrap: .roothide,
            toolchain: toolchain,
            sdk: sdk,
            catalog: catalog,
            workDirectory: scratch.appendingPathComponent("work-bridge"),
            installRoot: NativeBuild.installRoot(of: .roothide),
            home: home.path
        )
        let reporter = Collector()
        XCTAssertThrowsError(try BuildPipeline(inputs: inputs, reporter: reporter, cancellation: BuildCancellation()).run()) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("bridgingHeader cannot be combined with C++ interop"), text)
            XCTAssertTrue(text.contains("module.modulemap"), "the refusal says where to put the declarations: \(text)")
        }
        XCTAssertFalse(reporter.stages.contains("link:tool"), "nothing is linked: \(reporter.stages)")
        XCTAssertFalse(reporter.lines.contains { $0.hasPrefix("$ ") }, "no tool ran: \(reporter.lines)")
    }

    // MARK: Fixtures

    /// One product with the C++ module beside it: the modulemap and header in
    /// `Include`, the C++ implementation among the product's sources.
    private static let interopProduct: [String: Any] = [
        "id": "tool",
        "type": "executable",
        "name": "Interop",
        "sources": ["Sources/**/*.swift", "Sources/**/*.cpp"],
        "headerSearchPaths": ["Include"],
        "cxxInterop": true,
        "entitlements": "Packaging/Tool.entitlements",
    ]

    /// The module a product links: it imports the C++ module itself and hands
    /// the C++ type back to its consumers.
    private static let cxxKitModule: [String: Any] = [
        "name": "CxxKit",
        "sources": ["Vendor/CxxKit/Sources/*.swift"],
        "cxxInterop": true,
        "headerSearchPaths": ["Vendor/CxxKit/Include"],
        "cxxStandard": "c++20",
    ]

    private static let interopMain = """
    import CxxCounter

    var counter = Counter(40)
    let total = counter.add(2)
    print("interop \\(total)")
    """

    private static let counterHeader = """
    #pragma once

    struct Counter {
        explicit Counter(int start);
        int add(int amount);
        int value;
    };
    """

    private static let counterModuleMap = """
    module CxxCounter {
        header "counter.hpp"
        export *
    }
    """

    private static let counterSource = """
    #include "counter.hpp"

    Counter::Counter(int start) : value(start) {}

    int Counter::add(int amount) {
        value += amount;
        return value;
    }
    """

    /// The chain product declares no header search path of its own: its C++
    /// file reaches the module's header by a relative include, so the importer
    /// finds `CxxCounter` only through what the module hands down.
    private static let chainCounterSource = """
    #include "../Vendor/CxxKit/Include/counter.hpp"

    Counter::Counter(int start) : value(start) {}

    int Counter::add(int amount) {
        value += amount;
        return value;
    }
    """

    private static let onlyMain = """
    import CxxOnly

    var only = HeaderOnly()
    only.base = 21
    var value: Int32 = 0
    if let copy = only.makeCopy() {
        value = copy.pointee
        only.drop(copy)
    }
    print("header-only \\(only.twice()) \\(value)")
    """

    /// Header-only, but its `new` and `delete` put C++ runtime symbols in the
    /// product: interop alone has to bring the C++ runtime to the link.
    private static let onlyHeader = """
    #pragma once

    struct HeaderOnly {
        int base;

        int twice() const {
            return base * 2;
        }

        int *makeCopy() const {
            return new int(base);
        }

        void drop(int *value) const {
            delete value;
        }
    };
    """

    private static let onlyModuleMap = """
    module CxxOnly {
        header "only.hpp"
        export *
    }
    """

    private static let kitSwift = """
    import CxxCounter

    public func made(_ start: Int32) -> Counter {
        return Counter(start)
    }
    """

    private static let chainMain = """
    import CxxKit

    var counter = made(40)
    print("chain \\(counter.add(2))")
    """

    /// A C module and a C++ module in one modulemap, called from Swift.
    private static let bothMain = """
    import CValues
    import CxxCounter

    var counter = Counter(40)
    print("both \\(c_value()) \\(counter.add(2))")
    """

    private static let valuesHeader = """
    #pragma once

    int c_value(void);
    """

    private static let valuesSource = """
    #include "values.h"

    int c_value(void) {
        return 5;
    }
    """

    /// `[extern_c]` keeps the C declarations C: under the interop mode a C
    /// module is otherwise imported with C++ linkage, and the link misses
    /// `c_value` while the compiler says nothing.
    private static let bothModuleMap = """
    module CValues [extern_c] {
        header "values.h"
        export *
    }

    module CxxCounter {
        header "counter.hpp"
        export *
    }
    """

    /// The declaration a refused product's bridging header would hold.
    private static let bridgeHeaderOnly = """
    #pragma once

    int c_value(void);
    """

    private static let bridgeOnlyMain = """
    import Foundation

    print("bridged \\(c_value())")
    """

    /// `NativeBuild.describe`, then the project's Swift modules beside the
    /// product: the fixture's document is the product's, its modules are the
    /// project's.
    private func describe(_ product: [String: Any], modules: [[String: Any]], in root: URL) throws {
        try NativeBuild.describe(product, in: root)
        let manifest = root.appendingPathComponent("apelin-project.json")
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
            "the description is not a JSON object"
        )
        document["swiftModules"] = modules
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifest)
    }
}
