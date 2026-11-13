import ApelinCore
import ApelinProtocol
@testable import ApelinProject
import Foundation
import XCTest

/// Swift's C++ interop as `apelin-project.json` describes it: which member
/// turns it on, what a product inherits from the modules it builds against,
/// the one standard the importer and native C++ must share, and the checks
/// that refuse a contradiction before a compiler sees it.
final class CXXInteropTests: XCTestCase {
    // MARK: Resolution

    func testInteropIsOffUnlessNamed() throws {
        let project = try document(products: [
            #"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"]}"#,
        ])
        let settings = try project.cxxInteropSettings(for: XCTUnwrap(project.products.first))
        XCTAssertEqual(settings, .disabled)
        XCTAssertNil(settings.standard)
        XCTAssertEqual(settings.headerSearchPaths, [])
    }

    func testAProductTurnsItOnWithCxx17() throws {
        let project = try document(products: [
            #"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "cxxInterop": true}"#,
        ])
        let settings = try project.cxxInteropSettings(for: XCTUnwrap(project.products.first))
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.standard, "c++17", "the importer's default, never nil while it is on")
        XCTAssertEqual(settings.headerSearchPaths, [])
    }

    func testTheProductsStandardIsTheImportersStandard() throws {
        let project = try document(products: [
            #"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "cxxInterop": true, "cxxStandard": "c++20"}"#,
        ])
        XCTAssertEqual(try project.cxxInteropSettings(for: XCTUnwrap(project.products.first)).standard, "c++20")
    }

    func testAModuleTurnsInteropOnForItsProductAndBringsItsHeaders() throws {
        let project = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "swiftModules": ["CxxKit"]}"#],
            modules: """
            [
              {"name": "CxxKit", "sources": ["Vendor/CxxKit/Sources/*.swift"], "cxxInterop": true,
               "headerSearchPaths": ["Vendor/CxxKit/include"], "cxxStandard": "c++20"},
              {"name": "LogKit", "sources": ["Vendor/LogKit/Sources/*.swift"]}
            ]
            """
        )
        let settings = try project.cxxInteropSettings(for: XCTUnwrap(project.products.first))
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.standard, "c++20")
        XCTAssertEqual(settings.headerSearchPaths, ["Vendor/CxxKit/include"])

        let disabled = try project.cxxInteropSettings(for: XCTUnwrap(project.swiftModules?.last))
        XCTAssertEqual(disabled, .disabled, "a module nobody enabled is left alone")
    }

    /// Interop and the paths reach a product through a module it never names.
    func testTheClosureCarriesInteropAndItsHeadersTransitively() throws {
        let project = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "swiftModules": ["Middle"]}"#],
            modules: """
            [
              {"name": "Middle", "sources": ["Vendor/Middle/Sources/*.swift"], "dependencies": ["Leaf"]},
              {"name": "Leaf", "sources": ["Vendor/Leaf/Sources/*.swift"], "cxxInterop": true,
               "headerSearchPaths": ["Vendor/Leaf/include", "Vendor/Leaf/include"], "cxxStandard": "c++20"}
            ]
            """
        )
        let settings = try project.cxxInteropSettings(for: XCTUnwrap(project.products.first))
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.standard, "c++20")
        XCTAssertEqual(settings.headerSearchPaths, ["Vendor/Leaf/include"], "carried through Middle, each path once")

        let middle = try project.cxxInteropSettings(for: XCTUnwrap(project.swiftModules?.first))
        XCTAssertEqual(middle.headerSearchPaths, ["Vendor/Leaf/include"], "a module inherits the paths it imports")
    }

    func testAModulesOwnHeaderPathsComeFirst() throws {
        let project = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "swiftModules": ["Top"]}"#],
            modules: """
            [
              {"name": "Top", "sources": ["Vendor/Top/Sources/*.swift"], "dependencies": ["Base"], "cxxInterop": true,
               "headerSearchPaths": ["Vendor/Top/include"]},
              {"name": "Base", "sources": ["Vendor/Base/Sources/*.swift"], "cxxInterop": true,
               "headerSearchPaths": ["Vendor/Base/include"]}
            ]
            """
        )
        let top = try project.cxxInteropSettings(for: XCTUnwrap(project.swiftModules?.first))
        XCTAssertEqual(top.headerSearchPaths, ["Vendor/Top/include", "Vendor/Base/include"])
    }

    /// A product's standard reaches the importer, but a module is compiled on
    /// its own: it cannot see the product's standard and would be built as
    /// c++17, so the check asks the module to name it.
    func testAProductStandardBesideASilentModuleIsRefused() throws {
        let project = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "cxxInterop": true, "cxxStandard": "c++20", "swiftModules": ["CxxKit"]}"#],
            modules: #"[{"name": "CxxKit", "sources": ["Vendor/CxxKit/Sources/*.swift"], "cxxInterop": true}]"#
        )
        XCTAssertThrowsError(try project.cxxInteropSettings(for: XCTUnwrap(project.products.first))) { error in
            XCTAssertEqual((error as? CXXInteropError)?.field, "/swiftModules/0/cxxStandard")
            XCTAssertTrue((error as? CXXInteropError)?.reason.contains("while this closure compiles as c++20") == true, "\(error)")
        }
    }

    func testAModuleThatNamesTheStandardIsAccepted() throws {
        let project = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "cxxInterop": true, "cxxStandard": "c++20", "swiftModules": ["CxxKit"]}"#],
            modules: #"[{"name": "CxxKit", "sources": ["Vendor/CxxKit/Sources/*.swift"], "cxxInterop": true, "cxxStandard": "c++20"}]"#
        )
        XCTAssertEqual(try project.cxxInteropSettings(for: XCTUnwrap(project.products.first)).standard, "c++20")
    }

    /// A bridging header and interop cannot meet: the importer stops reading
    /// the header the moment interop is on, without a word, so validation
    /// refuses the pair — also when a module turned interop on — and a
    /// resolver failure is left to speak for itself.
    func testABridgingHeaderCannotBeCombinedWithInterop() throws {
        let direct = try document(products: [
            #"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "bridgingHeader": "Sources/Bridge.h", "cxxInterop": true}"#,
        ])
        var errors = ProjectValidation.semanticErrors(direct)
        XCTAssertTrue(
            errors.contains { $0.hasPrefix("/products/0/bridgingHeader: ") && $0.contains("cannot be combined with C++ interop") },
            "\(errors)",
        )

        let viaModule = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "bridgingHeader": "Sources/Bridge.h", "swiftModules": ["CxxKit"]}"#],
            modules: #"[{"name": "CxxKit", "sources": ["Vendor/CxxKit/Sources/*.swift"], "cxxInterop": true}]"#,
        )
        errors = ProjectValidation.semanticErrors(viaModule)
        XCTAssertTrue(errors.contains { $0.hasPrefix("/products/0/bridgingHeader: ") }, "\(errors)")

        let off = try document(products: [
            #"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "bridgingHeader": "Sources/Bridge.h"}"#,
        ])
        XCTAssertFalse(ProjectValidation.semanticErrors(off).contains { $0.contains("cannot be combined with C++ interop") })

        let broken = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "bridgingHeader": "Sources/Bridge.h", "cxxInterop": true, "cxxStandard": "c++20", "swiftModules": ["CxxKit"]}"#],
            modules: #"[{"name": "CxxKit", "sources": ["Vendor/CxxKit/Sources/*.swift"], "cxxInterop": true}]"#,
        )
        errors = ProjectValidation.semanticErrors(broken)
        XCTAssertTrue(errors.contains { $0.contains("while this closure compiles as c++20") }, "the standard error is not masked: \(errors)")
        XCTAssertFalse(errors.contains { $0.contains("cannot be combined with C++ interop") })
    }

    func testTwoStandardsInOneClosureAreRefused() throws {
        let project = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "cxxInterop": true, "swiftModules": ["AlphaKit", "BetaKit"]}"#],
            modules: """
            [
              {"name": "AlphaKit", "sources": ["Vendor/AlphaKit/Sources/*.swift"], "cxxInterop": true, "cxxStandard": "c++17"},
              {"name": "BetaKit", "sources": ["Vendor/BetaKit/Sources/*.swift"], "cxxInterop": true, "cxxStandard": "c++20"}
            ]
            """
        )
        XCTAssertThrowsError(try project.cxxInteropSettings(for: XCTUnwrap(project.products.first))) { error in
            XCTAssertTrue((error as? CXXInteropError)?.reason.contains("names more than one standard") == true, "\(error)")
        }
    }

    /// The importer is C++14; a project's own C++ files may still be c++11.
    func testCxx11IsRefusedOnlyInsideAnInteropClosure() throws {
        let interop = try document(products: [
            #"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "cxxInterop": true, "cxxStandard": "c++11"}"#,
        ])
        XCTAssertThrowsError(try interop.cxxInteropSettings(for: XCTUnwrap(interop.products.first))) { error in
            XCTAssertEqual((error as? CXXInteropError)?.field, "/products/0/cxxStandard")
            XCTAssertTrue((error as? CXXInteropError)?.reason.contains("older than Swift's C++ interop supports") == true, "\(error)")
        }

        let native = try document(products: [
            #"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.cpp"], "cxxStandard": "c++11"}"#,
        ])
        XCTAssertEqual(try native.cxxInteropSettings(for: XCTUnwrap(native.products.first)), .disabled)
    }

    func testFalseBesideAnEnabledModuleIsRefused() throws {
        let project = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "cxxInterop": false, "swiftModules": ["CxxKit"]}"#],
            modules: #"[{"name": "CxxKit", "sources": ["Vendor/CxxKit/Sources/*.swift"], "cxxInterop": true}]"#
        )
        XCTAssertThrowsError(try project.cxxInteropSettings(for: XCTUnwrap(project.products.first))) { error in
            XCTAssertEqual((error as? CXXInteropError)?.field, "/products/0/cxxInterop")
            XCTAssertTrue((error as? CXXInteropError)?.reason.contains("sets cxxInterop to false") == true, "\(error)")
        }
        // The module itself is not contradictory: only the product that says
        // false beside it is.
        XCTAssertTrue(try project.cxxInteropSettings(for: XCTUnwrap(project.swiftModules?.first)).enabled)
    }

    func testAModuleSayingFalseBesideAnEnabledDependencyIsRefused() throws {
        let project = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "swiftModules": ["Top"]}"#],
            modules: """
            [
              {"name": "Top", "sources": ["Vendor/Top/Sources/*.swift"], "dependencies": ["Base"], "cxxInterop": false},
              {"name": "Base", "sources": ["Vendor/Base/Sources/*.swift"], "cxxInterop": true}
            ]
            """
        )
        XCTAssertThrowsError(try project.cxxInteropSettings(for: XCTUnwrap(project.swiftModules?.first))) { error in
            XCTAssertEqual((error as? CXXInteropError)?.field, "/swiftModules/0/cxxInterop")
            XCTAssertTrue((error as? CXXInteropError)?.reason.contains("depends on") == true, "\(error)")
        }
    }

    /// A cycle is refused by validation, but the resolver a build calls must
    /// still answer instead of looping.
    func testACycleIsSafe() throws {
        let project = try document(
            products: [#"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "swiftModules": ["A"]}"#],
            modules: """
            [
              {"name": "A", "sources": ["Vendor/A/Sources/*.swift"], "dependencies": ["B"]},
              {"name": "B", "sources": ["Vendor/B/Sources/*.swift"], "dependencies": ["A"], "cxxInterop": true}
            ]
            """
        )
        let settings = try project.cxxInteropSettings(for: XCTUnwrap(project.products.first))
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.standard, "c++17")
    }

    // MARK: Validation

    func testTheFixturesAgree() throws {
        let valid = Repository.fixtures.appendingPathComponent("project/valid/cxx-interop-swift.json")
        XCTAssertEqual(ProjectValidation.errors(try StrictJSON.parse(contentsOf: valid)), [])

        let invalid = Repository.fixtures.appendingPathComponent("project/invalid/product-cxx-interop-false-with-module.json")
        XCTAssertTrue(ProjectValidation.errors(try StrictJSON.parse(contentsOf: invalid)).contains {
            $0.hasPrefix("/products/0/cxxInterop: ")
        })
    }

    /// The description a project file is approved by names the interop
    /// members — so changing one asks — but never the bytes of a header or a
    /// module map the importer reads.
    func testHeaderAndModuleMapContentNeverMovesTheDigest() throws {
        let root = try interopProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try ApprovalDigests.compute(projectAt: root)

        try Data("struct Counter { int other; };\n".utf8).write(to: root.appendingPathComponent("Headers/Counter.hpp"))
        XCTAssertEqual(try ApprovalDigests.compute(projectAt: root).build.digest, base.build.digest, "a header's content is a source edit")

        try Data("module Counter { header \"Counter.hpp\" export * }\n".utf8)
            .write(to: root.appendingPathComponent("Headers/module.modulemap"))
        XCTAssertEqual(try ApprovalDigests.compute(projectAt: root).build.digest, base.build.digest, "a module map's content too")

        try Data("struct Extra { int value; };\n".utf8).write(to: root.appendingPathComponent("Headers/Extra.hpp"))
        XCTAssertEqual(try ApprovalDigests.compute(projectAt: root).build.digest, base.build.digest, "a new header under an existing path")
    }

    func testChangingAnInteropMemberMovesTheDigest() throws {
        let root = try interopProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try ApprovalDigests.compute(projectAt: root)

        // The product stops asking; its module still turns interop on for it.
        try edit(root) { document in
            setProduct(&document, 0) { tool in
                tool["cxxInterop"] = nil
            }
        }
        let withoutFlag = try ApprovalDigests.compute(projectAt: root)
        XCTAssertNotEqual(withoutFlag.build.digest, base.build.digest, "a product member is approved")

        // A module's standard is approved too; both move together so the
        // closure stays consistent.
        try edit(root) { document in
            setProduct(&document, 0) { tool in
                tool["cxxStandard"] = .string("c++17")
            }
            setModule(&document, 0) { module in
                module["cxxStandard"] = .string("c++17")
            }
        }
        XCTAssertNotEqual(try ApprovalDigests.compute(projectAt: root).build.digest, withoutFlag.build.digest)

        // headerSearchPaths on a product are an input path, like sources.
        let beforePaths = try ApprovalDigests.compute(projectAt: root).build.digest
        try edit(root) { document in
            setProduct(&document, 0) { tool in
                tool["headerSearchPaths"] = .array([.string("Vendor/CxxKit/include")])
            }
        }
        XCTAssertEqual(try ApprovalDigests.compute(projectAt: root).build.digest, beforePaths, "a search path is not a description")
    }

    // MARK: projectCheck

    func testAProductWithoutSwiftIsRefused() throws {
        let root = try interopProjectRoot(products: [
            #"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.cpp"], "cxxInterop": true}"#,
        ], files: ["Sources/main.cpp"])
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = check(at: root)
        XCTAssertTrue(
            diagnostics.contains { $0.code == "project.cxxInterop.noSwift" && $0.field == "/products/0/cxxInterop" },
            "\(diagnostics)"
        )
    }

    func testInteropWantsCommandLineTools15() throws {
        let root = try interopProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(check(at: root, version: "14.2").contains { $0.code == "environment.toolchain.cxxInterop" })
        XCTAssertFalse(check(at: root, version: "15.0").contains { $0.code == "environment.toolchain.cxxInterop" })
    }

    func testInteropWantsTheClangModuleMachinery() throws {
        let root = try interopProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(check(at: root, features: ["FEAT_SHA3", "FEAT_NOT_ON_ANY_CPU"])
            .contains { $0.code == "environment.device.clangModules" && $0.field == "/products" })
        XCTAssertFalse(check(at: root, features: ["FEAT_SHA3"]).contains { $0.code == "environment.device.clangModules" })
    }

    func testAModulesHeaderPathMustExist() throws {
        let root = try interopProjectRoot(includeExistingDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(check(at: root).contains {
            $0.code == "project.directory.missing" && $0.field == "/swiftModules/0/headerSearchPaths"
        })
    }

    // MARK: Fixtures

    private func document(products: [String], modules: String? = nil) throws -> ProjectDocument {
        let text = try documentJSON(
            products: products,
            modules: modules ?? "[]",
            projectID: "00000000-0000-4000-8000-00000000a09a"
        )
        return try ProjectDocument(document: StrictJSON.parse(Data(text.utf8)))
    }

    /// A project root that passes validation: an executable with Swift and a
    /// C++ header, a module that imports it with interop on, a header folder
    /// and a module map.
    private func interopProjectRoot(
        products: [String]? = nil,
        files: [String] = [],
        includeExistingDirectory: Bool = true
    ) throws -> URL {
        let products = products ?? [
            #"{"id": "tool", "type": "executable", "name": "tool", "sources": ["Sources/*.swift"], "headerSearchPaths": ["Headers"], "cxxInterop": true, "cxxStandard": "c++20", "swiftModules": ["CxxKit"]}"#,
        ]
        let include = includeExistingDirectory ? "Headers" : "Missing"
        let modules = """
        [{"name": "CxxKit", "sources": ["Vendor/CxxKit/Sources/*.swift"], "cxxInterop": true,
          "headerSearchPaths": ["\(include)"], "cxxStandard": "c++20"}]
        """
        let text = try documentJSON(
            products: products,
            modules: modules,
            projectID: "00000000-0000-4000-8000-00000000a09b"
        )
        let root = try scratchDirectory()
        try Data(text.utf8).write(to: root.appendingPathComponent("apelin-project.json"))
        var paths = files.isEmpty ? ["Sources/Probe.swift"] : files
        paths.append("Vendor/CxxKit/Sources/CxxKit.swift")
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("/* source */\n".utf8).write(to: url)
        }
        if includeExistingDirectory {
            let headers = root.appendingPathComponent("Headers")
            try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
            try Data("struct Counter { int value; };\n".utf8).write(to: headers.appendingPathComponent("Counter.hpp"))
            try Data("module Counter { header \"Counter.hpp\" export * }\n".utf8)
                .write(to: headers.appendingPathComponent("module.modulemap"))
        }
        return root
    }

    private func documentJSON(products: [String], modules: String, projectID: String) throws -> String {
        let productList = products.joined(separator: ",\n    ")
        let moduleList = modules == "[]" ? "" : ",\n  \"swiftModules\": \(modules)"
        return """
        {
          "schemaVersion": 1,
          "projectID": "\(projectID)",
          "kind": "cli",
          "template": {
            "extensionID": "wiki.qaq.apelin.dev.cli",
            "templateID": "swift",
            "version": "0.1.2",
            "digest": "sha256:\(String(repeating: "a", count: 64))"
          },
          "environment": {
            "toolchain": {"id": "clt-27.0-sample", "digest": "sha256:\(String(repeating: "1", count: 64))"},
            "sdk": {"id": "iPhoneOS27.0-00000000", "digest": "sha256:\(String(repeating: "2", count: 64))"}
          },
          "language": "swift",
          "deploymentTarget": "16.0",
          "architectures": {"rootless": ["arm64"]},
          "configurations": {
            "Debug": {"optimization": "0", "debugInfo": true},
            "Release": {"optimization": "2", "debugInfo": true}
          },
          "products": [
            \(productList)
          ]\(moduleList),
          "build": {"steps": [
            {"type": "compile", "product": "tool"},
            {"type": "link", "product": "tool"},
            {"type": "lipo", "product": "tool"},
            {"type": "sign", "product": "tool", "identity": "adhoc"}
          ]},
          "package": {
            "id": "com.example.tool",
            "name": "Tool",
            "version": "0.0.1",
            "description": "A tool.",
            "author": "Apelin User",
            "section": "Development",
            "layout": [{"path": "/usr/bin/tool", "product": "tool"}]
          }
        }
        """
    }

    private func edit(_ root: URL, _ change: (inout JSONObject) -> Void) throws {
        let url = root.appendingPathComponent("apelin-project.json")
        guard case var .object(document) = try StrictJSON.parse(contentsOf: url) else {
            return XCTFail("the project file is not an object")
        }
        change(&document)
        try Data((JSONWriter.indented(.object(document)) + "\n").utf8).write(to: url)
    }

    private func setProduct(_ document: inout JSONObject, _ index: Int, _ change: (inout JSONObject) -> Void) {
        var items = document["products"]?.arrayValue ?? []
        guard items.indices.contains(index), case var .object(product) = items[index] else {
            return XCTFail("no product \(index)")
        }
        change(&product)
        items[index] = .object(product)
        document["products"] = .array(items)
    }

    private func setModule(_ document: inout JSONObject, _ index: Int, _ change: (inout JSONObject) -> Void) {
        var items = document["swiftModules"]?.arrayValue ?? []
        guard items.indices.contains(index), case var .object(module) = items[index] else {
            return XCTFail("no swift module \(index)")
        }
        change(&module)
        items[index] = .object(module)
        document["swiftModules"] = .array(items)
    }

    private func check(
        at root: URL,
        version: String = "27.0",
        features: [String] = ["FEAT_SHA3"]
    ) -> [ProjectDiagnostic] {
        let toolchain = RegisteredToolchain(
            id: "clt-27.0-sample",
            digest: "sha256:" + String(repeating: "1", count: 64),
            version: version,
            path: "/nonexistent",
            components: ["c-family", "swift"],
            clangModuleCPUFeatures: features
        )
        let sdk = RegisteredSDK(
            id: "iPhoneOS27.0-00000000",
            digest: "sha256:" + String(repeating: "2", count: 64),
            version: "27.0",
            path: "/nonexistent"
        )
        let store = ProjectStore(dataFolder: DataFolder(home: root.path))
        return ProjectCheck(
            store: store,
            catalog: ExtensionCatalog(directory: Repository.extensions),
            registry: StaticEnvironmentRegistry(toolchains: [toolchain], sdks: [sdk])
        ).run(root: root).diagnostics
    }
}
