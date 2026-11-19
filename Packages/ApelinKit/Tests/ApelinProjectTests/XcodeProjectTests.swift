import ApelinCore
@testable import ApelinProject
import Foundation
import XCTest

/// The Xcode project a new project carries: made from the description beside
/// it, read back the way Xcode reads it first, and never replaced once Xcode
/// has touched it.
final class XcodeProjectTests: XCTestCase {
    // A project folder shaped like the tweak template's output, written
    // straight from its description rather than through creation, so these
    // tests say what the generator does and nothing about the templates.
    private static let tweak = """
    {
      "schemaVersion": 1,
      "projectID": "3f1c2a44-0d6e-4c31-9a3d-2b1f0e8c7d55",
      "kind": "tweak",
      "template": {
        "extensionID": "wiki.qaq.apelin.dev.tweak", "templateID": "objc-hook",
        "version": "0.1.1",
        "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
      },
      "environment": { "toolchain": { "id": "t", "digest": "sha256:00" }, "sdk": { "id": "s", "digest": "sha256:00" } },
      "language": "objc",
      "deploymentTarget": "16.0",
      "architectures": { "rootless": ["arm64", "arm64e"], "roothide": ["arm64e"] },
      "configurations": {
        "Debug": { "optimization": "0", "debugInfo": true, "defines": { "DEBUG": "1" } },
        "Release": { "optimization": "2", "debugInfo": true }
      },
      "products": [{
        "id": "tweak", "type": "dylib", "name": "SmokeTweak",
        "sources": ["Sources/*.m"], "headerSearchPaths": ["Sources"], "objcARC": true,
        "frameworks": ["Foundation", "UIKit"], "libraries": ["substrate"],
        "extensionSupport": [{ "extension": "wiki.qaq.apelin.dev.tweak", "component": "substrate" }]
      }],
      "build": { "steps": [{ "type": "compile", "product": "tweak" }, { "type": "link", "product": "tweak" }] },
      "package": {
        "id": "local.apelin.smoke", "name": "Smoke", "version": "0.0.1", "description": "Smoke",
        "author": "Smoke", "section": "Tweaks",
        "layout": [{ "path": "/Library/MobileSubstrate/DynamicLibraries/SmokeTweak.dylib", "product": "tweak" }],
        "tweakFilter": { "dylib": "tweak", "bundles": ["com.apple.SpringBoard"] }
      }
    }
    """

    private static let app = """
    {
      "schemaVersion": 1,
      "projectID": "3f1c2a44-0d6e-4c31-9a3d-2b1f0e8c7d56",
      "kind": "app",
      "template": {
        "extensionID": "wiki.qaq.apelin.dev.app", "templateID": "uikit-swift",
        "version": "0.1.1",
        "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
      },
      "environment": { "toolchain": { "id": "t", "digest": "sha256:00" }, "sdk": { "id": "s", "digest": "sha256:00" } },
      "language": "swift",
      "deploymentTarget": "16.0",
      "architectures": { "rootless": ["arm64"], "roothide": ["arm64"] },
      "configurations": {
        "Debug": { "optimization": "0", "debugInfo": true },
        "Release": { "optimization": "2", "debugInfo": true }
      },
      "products": [{
        "id": "app", "type": "app", "name": "SmokeApp",
        "sources": ["Sources/*.swift"], "resources": ["Resources/icon.png"],
        "infoPlist": "Resources/Info.plist", "entitlements": "Packaging/App.entitlements",
        "frameworks": ["Foundation", "UIKit"]
      }],
      "build": { "steps": [{ "type": "compile", "product": "app" }, { "type": "link", "product": "app" }] },
      "package": {
        "id": "local.apelin.smoke", "name": "Smoke", "version": "0.0.1", "description": "Smoke",
        "author": "Smoke", "section": "Applications",
        "layout": [{ "path": "/Applications/SmokeApp.app", "product": "app" }]
      }
    }
    """

    /// Writes `files` into `root` and decodes `json` into the description the
    /// generator reads.
    private func project(_ json: String, in root: URL, files: [String: String]) throws -> ProjectDocument {
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try Data(text.utf8).write(to: url)
        }
        return try JSONDecoder().decode(ProjectDocument.self, from: Data(json.utf8))
    }

    /// The generated `project.pbxproj`, read the way Xcode reads it first: as
    /// an OpenStep property list.
    private func objects(
        _ written: XcodeProject.Written,
    ) throws -> (root: [String: Any], objects: [String: [String: Any]]) {
        let data = try Data(contentsOf: URL(fileURLWithPath: written.path + "/project.pbxproj"))
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        let root = try XCTUnwrap(plist as? [String: Any])
        let objects = try XCTUnwrap(root["objects"] as? [String: Any])
        var typed: [String: [String: Any]] = [:]
        for (key, value) in objects {
            typed[key] = try XCTUnwrap(value as? [String: Any], key)
        }
        return (root, typed)
    }

    private func body(_ objects: [String: [String: Any]], isa: String) -> [[String: Any]] {
        objects.values.filter { $0["isa"] as? String == isa }
    }

    func testATweakBecomesADylibTarget() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("Smoke Tweak")
        let document = try project(Self.tweak, in: root, files: ["Sources/Tweak.m": "#import <substrate.h>\n"])
        let written = try XcodeProject.write(
            document,
            name: "Smoke Tweak",
            root: root,
            catalog: ExtensionCatalog(directory: Repository.extensions),
        )
        XCTAssertEqual(written.targets, ["SmokeTweak"])
        XCTAssertEqual(written.path, root.appendingPathComponent("Smoke Tweak.xcodeproj").path)

        let (rootObject, objects) = try objects(written)
        XCTAssertEqual(rootObject["objectVersion"] as? Int, 56)
        XCTAssertNotNil(objects[rootObject["rootObject"] as? String ?? ""])

        let target = try XCTUnwrap(body(objects, isa: "PBXNativeTarget").first)
        XCTAssertEqual(target["name"] as? String, "SmokeTweak")
        XCTAssertEqual(target["productType"] as? String, "com.apple.product-type.library.dynamic")
        let reference = try XCTUnwrap(objects[target["productReference"] as? String ?? ""])
        XCTAssertEqual(reference["path"] as? String, "SmokeTweak.dylib")

        // The source file is compiled, and the link names what the extension
        // support supplies: the settings a Mac needs to build the same dylib.
        let phases = (target["buildPhases"] as? [String] ?? []).compactMap { objects[$0] }
        let sources = try XCTUnwrap(phases.first { $0["isa"] as? String == "PBXSourcesBuildPhase" })
        let build = (sources["files"] as? [String] ?? []).compactMap { objects[$0] }
        XCTAssertEqual(build.count, 1)
        let source = try XCTUnwrap(objects[build[0]["fileRef"] as? String ?? ""])
        XCTAssertEqual(source["path"] as? String, "Tweak.m")

        let settings = try XCTUnwrap(
            body(objects, isa: "XCBuildConfiguration").first { $0["name"] as? String == "Debug" },
        )
        let values = try XCTUnwrap(settings["buildSettings"] as? [String: Any])
        XCTAssertEqual(values["PRODUCT_NAME"] as? String, "SmokeTweak")
        XCTAssertEqual(values["LD_DYLIB_INSTALL_NAME"] as? String, "@rpath/SmokeTweak.dylib")
        XCTAssertEqual(values["CLANG_ENABLE_OBJC_ARC"] as? String, "YES")
        XCTAssertEqual(
            values["HEADER_SEARCH_PATHS"] as? [String],
            ["$(inherited)", "$(SRCROOT)/Sources", "$(SRCROOT)/Xcode/Support/support/include"],
        )
        XCTAssertEqual(
            values["LIBRARY_SEARCH_PATHS"] as? [String],
            ["$(inherited)", "$(SRCROOT)/Xcode/Support/support/lib/roothide"],
        )
        XCTAssertEqual(
            values["OTHER_LDFLAGS"] as? [String],
            ["$(inherited)", "-framework", "Foundation", "-framework", "UIKit", "-lsubstrate"],
        )

        // The extension's headers and stubs came with it, and the README says
        // what stays on the device.
        let support = root.appendingPathComponent("Xcode/Support/support")
        for file in ["include/substrate.h", "lib/roothide/libsubstrate.tbd"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: support.appendingPathComponent(file).path),
                file,
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Xcode/README.md").path))

        // The scheme Xcode opens is a shared one, and it is XML.
        let scheme = written.path + "/xcshareddata/xcschemes/SmokeTweak.xcscheme"
        XCTAssertTrue(XMLParser(contentsOf: URL(fileURLWithPath: scheme))?.parse() ?? false)
    }

    func testAnAppCopiesItsResourcesAndNotItsInfoPlist() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("Smoke App")
        let document = try project(Self.app, in: root, files: [
            "Sources/main.swift": "import UIKit\n",
            "Resources/icon.png": "png",
            "Resources/Info.plist": "<plist version=\"1.0\"><dict/></plist>\n",
            "Packaging/App.entitlements": "<plist version=\"1.0\"><dict/></plist>\n",
        ])
        let written = try XcodeProject.write(document, name: "Smoke App", root: root)
        let (_, objects) = try objects(written)

        let target = try XCTUnwrap(body(objects, isa: "PBXNativeTarget").first)
        XCTAssertEqual(target["productType"] as? String, "com.apple.product-type.application")
        let phases = (target["buildPhases"] as? [String] ?? []).compactMap { objects[$0] }
        let resources = try XCTUnwrap(phases.first { $0["isa"] as? String == "PBXResourcesBuildPhase" })
        let copied = (resources["files"] as? [String] ?? []).compactMap { objects[$0] }
            .compactMap { objects[$0["fileRef"] as? String ?? ""]?["path"] as? String }
        XCTAssertEqual(copied, ["icon.png"])

        let settings = try XCTUnwrap(
            body(objects, isa: "XCBuildConfiguration").first { $0["name"] as? String == "Release" },
        )
        let values = try XCTUnwrap(settings["buildSettings"] as? [String: Any])
        XCTAssertEqual(values["INFOPLIST_FILE"] as? String, "Resources/Info.plist")
        XCTAssertEqual(values["CODE_SIGN_ENTITLEMENTS"] as? String, "Packaging/App.entitlements")
        XCTAssertEqual(values["PRODUCT_BUNDLE_IDENTIFIER"] as? String, "local.apelin.smoke")

        // Nothing is signed here: the device's package comes from Apelin.
        let project = try XCTUnwrap(
            body(objects, isa: "XCBuildConfiguration").first { $0["buildSettings"] is [String: Any] },
        )
        XCTAssertEqual((project["buildSettings"] as? [String: Any])?["CODE_SIGNING_ALLOWED"] as? String, "NO")
    }

    /// Regenerating in another folder is byte for byte the same project: the
    /// identifiers come from the project's own, not from a clock.
    func testTheSameDescriptionWritesTheSameBytes() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = scratch.appendingPathComponent("One/Smoke")
        let second = scratch.appendingPathComponent("Two/Smoke")
        let left = try XcodeProject.write(
            try project(Self.tweak, in: first, files: ["Sources/Tweak.m": "x\n"]),
            name: "Smoke",
            root: first,
            catalog: ExtensionCatalog(directory: Repository.extensions),
        )
        let right = try XcodeProject.write(
            try project(Self.tweak, in: second, files: ["Sources/Tweak.m": "x\n"]),
            name: "Smoke",
            root: second,
            catalog: ExtensionCatalog(directory: Repository.extensions),
        )
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: left.path + "/project.pbxproj")),
            try Data(contentsOf: URL(fileURLWithPath: right.path + "/project.pbxproj")),
        )
    }

    /// A folder that has one keeps it: Xcode owns the file once it is open.
    func testAnExistingProjectIsNeverReplaced() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("Smoke")
        let document = try project(Self.tweak, in: root, files: ["Sources/Tweak.m": "x\n"])
        _ = try XcodeProject.write(document, name: "Smoke", root: root)
        let marker = root.appendingPathComponent("Smoke.xcodeproj/project.pbxproj")
        try Data("edited by Xcode\n".utf8).write(to: marker)
        XCTAssertThrowsError(try XcodeProject.write(document, name: "Smoke", root: root))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "edited by Xcode\n")
    }

    /// A project made through the store arrives with the file, and every
    /// template's does: the point of the feature is that nobody has to ask.
    func testCreatedProjectsCarryTheirXcodeProject() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("Documents/wiki.qaq.apelin"),
            withIntermediateDirectories: true,
        )
        let store = ProjectStore(dataFolder: DataFolder(home: scratch.path))
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.tweak/objc-hook",
            name: "Carried",
            values: [:],
            catalog: catalog,
            registry: sampleRegistry(),
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: created.root.appendingPathComponent("Carried.xcodeproj/project.pbxproj").path,
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: created.root.appendingPathComponent("Xcode/Support/support/include/substrate.h").path,
        ))
    }
}
