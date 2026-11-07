import ApelinBuild
import ApelinCore
import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

/// A project's build handing back an `.ipa`: the app inside `Payload/`, read
/// back before it is recorded.
final class IPAPackagerTests: XCTestCase {
    /// The inputs a project of the tweak template gives, with the format
    /// this file is about, and a scratch `Builds/<id>/` to write into.
    private func makeInputs(_ scratch: URL) throws -> BuildInputs {
        let (home, store) = try makeHome(in: scratch)
        let toolchain = RegisteredToolchain(
            id: "clt-27.0-sample",
            digest: "sha256:" + String(repeating: "1", count: 64),
            version: "27.0",
            path: "/nonexistent",
            components: ["c-family"],
        )
        let sdk = RegisteredSDK(
            id: "iPhoneOS27.0-00000000",
            digest: "sha256:" + String(repeating: "2", count: 64),
            version: "27.0",
            path: "/nonexistent",
        )
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.tweak/objc-hook",
            name: "Hello App",
            values: [:],
            catalog: catalog,
            registry: StaticEnvironmentRegistry(toolchains: [toolchain], sdks: [sdk]),
        )
        var inputs = try BuildInputs(
            buildID: "ipa",
            projectRoot: created.root,
            project: store.locate(created.projectID).project,
            configuration: .release,
            bootstrap: .rootless,
            toolchain: toolchain,
            sdk: sdk,
            catalog: catalog,
            workDirectory: scratch.appendingPathComponent("work"),
            installRoot: "/var/jb",
            home: home.path,
        )
        inputs.project.package.format = .ipa
        try FileManager.default.createDirectory(at: inputs.workDirectory, withIntermediateDirectories: true)
        return inputs
    }

    /// `Hello.app` with an `Info.plist`, an executable, a folder and a file
    /// in it.
    private func makeApp(in scratch: URL) throws -> URL {
        let app = scratch.appendingPathComponent("Hello.app", isDirectory: true)
        let resources = app.appendingPathComponent("Base.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: app.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: app.appendingPathComponent("Hello"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Hello").path)
        try Data("hello".utf8).write(to: resources.appendingPathComponent("text.txt"))
        return app
    }

    private func products(app: String, extra: String = "") throws -> BuildProducts {
        let json = """
        {"products": [{"id": "app", "type": "app", "name": "Hello", "path": "\(app)",
        "executable": "\(app)/Hello", "digest": "sha256:\(String(repeating: "3", count: 64))",
        "uuids": {}}\(extra)], "dsyms": [], "log": ""}
        """
        return try JSONDecoder().decode(BuildProducts.self, from: Data(json.utf8))
    }

    func testTheAppGoesIntoPayloadAndTheArchiveReadsBack() throws {
        let scratch = try scratchDirectory("apelin-ipa")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputs = try makeInputs(scratch)
        let app = try makeApp(in: scratch)
        let products = try products(app: app.path)

        let output = try IPAPackager(inputs: inputs, products: products).write()

        XCTAssertEqual(
            (output.path as NSString).lastPathComponent,
            "\(inputs.project.package.id)_\(inputs.project.package.version).ipa",
        )
        XCTAssertGreaterThan(output.byteCount, 0)
        XCTAssertEqual(output.digest, CanonicalJSON.sha256Tag(try Data(contentsOf: URL(fileURLWithPath: output.path))))
        XCTAssertNil(output.loadCheck, "an .ipa has no filter and nothing to confirm loaded")

        let names = IPAPackager.names(of: output.path)
        XCTAssertEqual(names.first, "Payload/Hello.app", "the bundle's own entry comes first")
        XCTAssertTrue(names.contains("Payload/Hello.app/Info.plist"), "\(names)")
        XCTAssertTrue(names.contains("Payload/Hello.app/Hello"), "\(names)")
        XCTAssertTrue(names.contains("Payload/Hello.app/Base.lproj/text.txt"), "\(names)")
        XCTAssertEqual(try IPAPackager.verify(path: output.path, bundle: "Hello.app"), 3, "three files, folders aside")
    }

    /// Two writes of the same app with the same timestamp are the same bytes.
    func testTheSameBytesWriteTheSameArchive() throws {
        let scratch = try scratchDirectory("apelin-ipa")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputs = try makeInputs(scratch)
        let products = try products(app: try makeApp(in: scratch).path)

        let first = try IPAPackager(inputs: inputs, products: products).write()
        let second = try IPAPackager(inputs: inputs, products: products).write()

        XCTAssertEqual(first.digest, second.digest)
        XCTAssertEqual(first.byteCount, second.byteCount)
    }

    func testAnArchiveIsCheckedBeforeItIsRecorded() throws {
        let root = "Payload/Hello.app"
        XCTAssertEqual(try IPAPackager.check(["\(root)", "\(root)/Info.plist", "\(root)/Hello"], bundle: "Hello.app"), 2)

        for entries in [
            ["Payload/Hello.app/Info.plist", "Payload/Other.app/Info.plist"],
            ["Hello.app/Info.plist"],
            ["/Payload/Hello.app/Info.plist"],
            ["Payload/Hello.app/../Other.app/Info.plist"],
            ["Payload/Hello.app/Hello"],
            ["Payload/Hello.app/"],
            [""],
        ] {
            XCTAssertThrowsError(try IPAPackager.check(entries, bundle: "Hello.app"), "\(entries)")
        }
    }

    func testExactlyOneAppIsPackaged() throws {
        let scratch = try scratchDirectory("apelin-ipa")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputs = try makeInputs(scratch)
        let app = try makeApp(in: scratch)

        XCTAssertThrowsError(try IPAPackager(inputs: inputs, products: products(app: app.path, extra: """
        , {"id": "app2", "type": "app", "name": "Hello2", "path": "\(app.path)",
        "executable": "\(app.path)/Hello", "digest": "sha256:\(String(repeating: "4", count: 64))", "uuids": {}}
        """)).write())

        let without = try JSONDecoder().decode(BuildProducts.self, from: Data(#"{"products": [], "dsyms": [], "log": ""}"#.utf8))
        XCTAssertThrowsError(try IPAPackager(inputs: inputs, products: without).write())
    }

    /// One spelling for the format, whatever spells it: the schema's enum
    /// value, the wire's, and the record's.
    func testTheIpaFormatIsSpelledOneWay() {
        XCTAssertEqual(ProjectDocument.Package.Format.ipa.rawValue, BuildArtifact.ipaFormat)
        XCTAssertEqual(ProjectDocument.Package.Format.deb.rawValue, "deb")
    }
}
