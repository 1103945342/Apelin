import ApelinCore
@testable import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

/// Mixed-language products: `SourceLanguage`, the source rules the schema
/// cannot state, and the checks `projectCheck` makes of the files a glob
/// really expands to.
final class SourceLanguageTests: XCTestCase {
    // MARK: Classification

    func testEveryExtensionMapsToOneLanguage() {
        XCTAssertEqual(SourceLanguage(path: "Sources/main.c"), .c)
        XCTAssertEqual(SourceLanguage(path: "Sources/App.m"), .objc)
        XCTAssertEqual(SourceLanguage(path: "Sources/core.cpp"), .cxx)
        XCTAssertEqual(SourceLanguage(path: "Sources/core.cc"), .cxx)
        XCTAssertEqual(SourceLanguage(path: "Sources/core.cxx"), .cxx)
        XCTAssertEqual(SourceLanguage(path: "Sources/core.C"), .cxx, ".C is C++, as clang compiles it")
        XCTAssertEqual(SourceLanguage(path: "Sources/Worker.mm"), .objcxx)
        XCTAssertEqual(SourceLanguage(path: "Sources/Helper.swift"), .swift)
        // A glob is classified by the extension it spells.
        XCTAssertEqual(SourceLanguage(path: "Sources/*.mm"), .objcxx)
        XCTAssertEqual(SourceLanguage(path: "Sources/**/*.c"), .c)
        // No extension, or one nothing compiles.
        for path in ["Sources/*", "Sources/**", "Sources/main.h", "Sources/main.ruby", "Makefile", ""] {
            XCTAssertNil(SourceLanguage(path: path), path)
        }
    }

    func testFamilyFlags() {
        XCTAssertTrue(SourceLanguage.cxx.isCXX)
        XCTAssertTrue(SourceLanguage.objcxx.isCXX)
        XCTAssertFalse(SourceLanguage.c.isCXX)
        XCTAssertFalse(SourceLanguage.objc.isCXX)
        XCTAssertFalse(SourceLanguage.swift.isCXX)

        XCTAssertTrue(SourceLanguage.objc.isObjC)
        XCTAssertTrue(SourceLanguage.objcxx.isObjC)
        XCTAssertFalse(SourceLanguage.c.isObjC)
        XCTAssertFalse(SourceLanguage.cxx.isObjC)
        XCTAssertFalse(SourceLanguage.swift.isObjC)
    }

    // MARK: Validation

    func testAMixedProductIsValid() throws {
        let text = projectJSON(
            sources: ["Sources/main.m", "Sources/core.cpp", "Sources/worker.mm", "Sources/Helper.swift"],
            bridgingHeader: "Sources/Bridge.h",
            cxxStandard: "c++20",
        )
        XCTAssertEqual(ProjectValidation.errors(try StrictJSON.parse(Data(text.utf8))), [])
    }

    func testADefiniteExtensionMustBeOneThisProjectCompiles() throws {
        for source in ["Sources/main.rb", "Sources/main.h", "Makefile"] {
            let document = try StrictJSON.parse(Data(projectJSON(sources: [source]).utf8))
            let errors = ProjectValidation.errors(document)
            XCTAssertTrue(
                errors.contains { $0.contains("is not a .c, .m, .cpp, .cc, .cxx, .mm or .swift source") },
                "\(source): \(errors)",
            )
        }
        // A pattern's own suffix must be one of them; a pattern with no
        // extension is checked once the files are known.
        XCTAssertTrue(
            ProjectValidation.errors(try StrictJSON.parse(Data(projectJSON(sources: ["Sources/*.rb"]).utf8)))
                .contains { $0.contains("is not a .c, .m, .cpp, .cc, .cxx, .mm or .swift source") },
        )
        XCTAssertEqual(ProjectValidation.errors(try StrictJSON.parse(Data(projectJSON(sources: ["Sources/*"]).utf8))), [])
    }

    func testAnyProjectMayCarrySwiftModules() throws {
        let document = try StrictJSON.parse(Data(projectJSON(language: "objc", sources: ["Sources/main.m"], swiftModule: "LogKit").utf8))
        XCTAssertEqual(ProjectValidation.errors(document), [])
        // A module still compiles Swift only.
        let broken = try StrictJSON.parse(Data(projectJSON(sources: ["Sources/main.m"], moduleSources: ["Vendor/LogKit/Sources/*.m"]).utf8))
        XCTAssertTrue(
            ProjectValidation.errors(broken).contains { $0.contains("is not a .swift source") },
            "\(ProjectValidation.errors(broken))",
        )
    }

    // MARK: projectCheck, on the files a glob expands to

    func testAnUnsupportedFileTheGlobMatchedIsReported() throws {
        let root = try projectRoot(
            projectJSON(sources: ["Sources/*"]),
            files: ["Sources/main.m", "Sources/core.cpp", "Sources/notes.rb"],
        )
        let diagnostics = checkDiagnostics(at: root)
        let unknown = diagnostics.filter { $0.code == "project.source.unsupported" }
        XCTAssertEqual(unknown.map(\.file), ["Sources/notes.rb"])
        XCTAssertEqual(unknown.first?.field, "/products/0/sources")
        XCTAssertEqual(unknown.first?.severity, .error)
    }

    func testABridgingHeaderNeedsSwiftSourcesAndARegularFileInsideTheProject() throws {
        // A header the product does not need: it compiles no Swift.
        var root = try projectRoot(
            projectJSON(sources: ["Sources/*.m"], bridgingHeader: "Sources/Bridge.h"),
            files: ["Sources/main.m", "Sources/Bridge.h"],
        )
        var diagnostics = checkDiagnostics(at: root)
        XCTAssertTrue(diagnostics.contains { $0.code == "project.bridgingHeader.unused" }, "\(diagnostics)")
        XCTAssertFalse(diagnostics.contains { $0.code == "project.bridgingHeader.missing" })

        // A header that is not there.
        root = try projectRoot(
            projectJSON(sources: ["Sources/*"], bridgingHeader: "Sources/Missing.h"),
            files: ["Sources/main.m", "Sources/Helper.swift"],
        )
        diagnostics = checkDiagnostics(at: root)
        XCTAssertTrue(diagnostics.contains { $0.code == "project.bridgingHeader.missing" }, "\(diagnostics)")
        XCTAssertFalse(diagnostics.contains { $0.code == "project.bridgingHeader.unused" })

        // A path that resolves outside the project is refused like a missing one.
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Sources/Missing.h").path,
            withDestinationPath: "/etc/hosts",
        )
        diagnostics = checkDiagnostics(at: root)
        XCTAssertTrue(diagnostics.contains { $0.code == "project.bridgingHeader.missing" }, "\(diagnostics)")
    }

    func testAnActualSwiftSourceAsksForTheSwiftToolchain() throws {
        var root = try projectRoot(
            projectJSON(sources: ["Sources/*"], bridgingHeader: "Sources/Bridge.h"),
            files: ["Sources/main.m", "Sources/Helper.swift", "Sources/Bridge.h"],
        )
        var diagnostics = checkDiagnostics(at: root)
        XCTAssertTrue(diagnostics.contains { $0.code == "environment.toolchain.noSwift" }, "\(diagnostics)")
        XCTAssertTrue(
            diagnostics.contains { $0.code == "environment.toolchain.incomplete" && $0.message.contains("swiftc") },
            "\(diagnostics)",
        )

        // The same product without Swift asks for clang alone.
        root = try projectRoot(projectJSON(sources: ["Sources/*"]), files: ["Sources/main.m", "Sources/core.cpp"])
        diagnostics = checkDiagnostics(at: root)
        XCTAssertFalse(diagnostics.contains { $0.code == "environment.toolchain.noSwift" }, "\(diagnostics)")
        XCTAssertFalse(diagnostics.contains { $0.message.contains("swiftc") }, "\(diagnostics)")
    }

    func testASwiftModuleAsksForTheSwiftToolchain() throws {
        let root = try projectRoot(
            projectJSON(language: "objc", sources: ["Sources/main.m"], swiftModule: "LogKit"),
            files: ["Sources/main.m", "Vendor/LogKit/Sources/LogKit.swift"],
        )
        let diagnostics = checkDiagnostics(at: root)
        XCTAssertTrue(diagnostics.contains { $0.code == "environment.toolchain.noSwift" }, "\(diagnostics)")
    }

    /// `-fmodules` reaches clang's module machinery from `cxxFlags` as much as
    /// from `cFlags`, and the check is the CPU's, not the flag list's.
    func testCXXModulesAreCheckedAgainstTheCPUThatBuildsThem() throws {
        let toolchain = RegisteredToolchain(
            id: "clt-27.0-sample",
            digest: "sha256:" + String(repeating: "1", count: 64),
            version: "27.0",
            path: "/nonexistent",
            components: ["c-family"],
            clangModuleCPUFeatures: ["FEAT_SHA3", "FEAT_NOT_ON_ANY_CPU"],
        )
        let sdk = RegisteredSDK(
            id: "iPhoneOS27.0-00000000",
            digest: "sha256:" + String(repeating: "2", count: 64),
            version: "27.0",
            path: "/nonexistent",
        )
        let registry = StaticEnvironmentRegistry(toolchains: [toolchain], sdks: [sdk])

        var root = try projectRoot(projectJSON(sources: ["Sources/core.cpp"], cxxFlags: ["-fmodules"]), files: ["Sources/core.cpp"])
        var diagnostics = checkDiagnostics(at: root, registry: registry)
        XCTAssertTrue(diagnostics.contains { $0.code == "environment.device.clangModules" }, "\(diagnostics)")

        root = try projectRoot(projectJSON(sources: ["Sources/core.cpp"]), files: ["Sources/core.cpp"])
        diagnostics = checkDiagnostics(at: root, registry: registry)
        XCTAssertFalse(diagnostics.contains { $0.code == "environment.device.clangModules" }, "\(diagnostics)")
    }

    // MARK: Fixtures

    private func projectJSON(
        language: String = "objc",
        sources: [String],
        bridgingHeader: String? = nil,
        cxxStandard: String? = nil,
        cxxFlags: [String] = [],
        swiftModule: String? = nil,
        moduleSources: [String] = ["Vendor/LogKit/Sources/*.swift"],
    ) -> String {
        func strings(_ list: [String]) -> String {
            "[" + list.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        }
        let flags = cxxFlags.isEmpty ? "" : ", \"cxxFlags\": \(strings(cxxFlags))"
        let extras = [
            bridgingHeader.map { ", \"bridgingHeader\": \"\($0)\"" },
            cxxStandard.map { ", \"cxxStandard\": \"\($0)\"" },
            swiftModule.map { _ in ", \"swiftModules\": [\"LogKit\"]" },
        ].compactMap { $0 }.joined()
        let modules = swiftModule.map { name in
            "\n  \"swiftModules\": [{\"name\": \"\(name)\", \"sources\": \(strings(moduleSources))}],"
        } ?? ""
        return """
        {
          "schemaVersion": 1,
          "projectID": "00000000-0000-4000-8000-000000000123",
          "kind": "cli",
          "template": {
            "extensionID": "wiki.qaq.apelin.dev.cli",
            "templateID": "c",
            "version": "0.1.2",
            "digest": "sha256:\(String(repeating: "a", count: 64))"
          },
          "environment": {
            "toolchain": {"id": "clt-27.0-sample", "digest": "sha256:\(String(repeating: "1", count: 64))"},
            "sdk": {"id": "iPhoneOS27.0-00000000", "digest": "sha256:\(String(repeating: "2", count: 64))"}
          },
          "language": "\(language)",
          "deploymentTarget": "16.0",
          "architectures": {"rootless": ["arm64"]},
          "configurations": {
            "Debug": {"optimization": "0", "debugInfo": true\(flags)},
            "Release": {"optimization": "2", "debugInfo": true}
          },\(modules)
          "products": [{"id": "tool", "type": "executable", "name": "tool", "sources": \(strings(sources))\(extras)}],
          "build": {"steps": [
            {"type": "compile", "product": "tool"},
            {"type": "link", "product": "tool"},
            {"type": "lipo", "product": "tool"},
            {"type": "sign", "product": "tool"}
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

    /// A project folder with its description and the files it names.
    private func projectRoot(_ text: String, files: [String]) throws -> URL {
        let root = try scratchDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data(text.utf8).write(to: root.appendingPathComponent("apelin-project.json"))
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("/* source */\n".utf8).write(to: url)
        }
        return root
    }

    private func checkDiagnostics(at root: URL, registry: EnvironmentRegistry = sampleRegistry()) -> [ProjectDiagnostic] {
        let store = ProjectStore(dataFolder: DataFolder(home: root.path))
        return ProjectCheck(store: store, catalog: ExtensionCatalog(directory: Repository.extensions), registry: registry)
            .run(root: root).diagnostics
    }
}
