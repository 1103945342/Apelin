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

    /// An Info.plist, written the way the build writes one.
    private func plist(_ info: [String: Any], at url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url)
    }

    /// `Hello.app` whose Info.plist names `identifier`, so an extension can be
    /// checked to be an identifier under it.
    private func makeApp(in scratch: URL, identifier: String) throws -> URL {
        let app = try makeApp(in: scratch)
        try plist(["CFBundleExecutable": "Hello", "CFBundleIdentifier": identifier],
                  at: app.appendingPathComponent("Info.plist"))
        return app
    }

    /// `HelloWidgets.appex` as the build leaves one: an Info.plist naming the
    /// executable, the widget point and an identifier the app hosts, with the
    /// executable and a resource beside it.
    private func makeAppex(
        in scratch: URL,
        name: String = "HelloWidgets",
        identifier: String = "com.example.hello.widgets",
        point: String? = "com.apple.widgetkit-extension",
    ) throws -> URL {
        let appex = scratch.appendingPathComponent("\(name).appex", isDirectory: true)
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleExecutable": name,
            "CFBundleIdentifier": identifier,
            "CFBundlePackageType": "XPC!",
        ]
        if let point {
            info["NSExtension"] = ["NSExtensionPointIdentifier": point]
        }
        try plist(info, at: appex.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: appex.appendingPathComponent(name))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appex.appendingPathComponent(name).path)
        try Data("widget".utf8).write(to: appex.appendingPathComponent("Assets.car"))
        return appex
    }

    /// The product record of an extension, as the pipeline writes it after
    /// `bundle-resources`: a directory rather than a file, with the executable
    /// named inside it.
    private func appexProduct(_ directory: URL, id: String = "widgets") -> String {
        let name = directory.lastPathComponent.replacingOccurrences(of: ".appex", with: "")
        return """
        , {"id": "\(id)", "type": "appex", "name": "\(name)", "path": "\(directory.path)",
        "executable": "\(directory.path)/\(name)", "digest": "sha256:\(String(repeating: "5", count: 64))",
        "uuids": {}}
        """
    }

    /// The widget an app carries goes in at the one place iOS looks for it,
    /// with the bytes the build signed, and the app on disk is left alone.
    func testAnAppCarriesItsWidget() throws {
        let scratch = try scratchDirectory("apelin-ipa")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputs = try makeInputs(scratch)
        let app = try makeApp(in: scratch, identifier: "com.example.hello")
        let appex = try makeAppex(in: scratch)
        let products = try products(app: app.path, extra: appexProduct(appex))

        let output = try IPAPackager(inputs: inputs, products: products).write()

        let names = IPAPackager.names(of: output.path)
        let inside = "Payload/Hello.app/PlugIns/HelloWidgets.appex"
        XCTAssertEqual(names.first, "Payload/Hello.app", "the bundle's own entry comes first")
        XCTAssertTrue(names.contains("Payload/Hello.app/PlugIns"), "\(names)")
        XCTAssertTrue(names.contains(inside), "\(names)")
        XCTAssertTrue(names.contains("\(inside)/Info.plist"), "\(names)")
        XCTAssertTrue(names.contains("\(inside)/HelloWidgets"), "\(names)")
        XCTAssertTrue(names.contains("\(inside)/Assets.car"), "\(names)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: app.appendingPathComponent("PlugIns").path),
            "the app on disk keeps what the build made",
        )
        XCTAssertEqual(try IPAPackager.verify(path: output.path, bundle: "Hello.app"), 6, "three files each, folders aside")
    }

    /// The widget's executable keeps the mode the build signed it with, which
    /// is the only reason iOS runs it.
    func testTheWidgetsExecutableStaysExecutable() throws {
        let scratch = try scratchDirectory("apelin-ipa")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputs = try makeInputs(scratch)
        let app = try makeApp(in: scratch, identifier: "com.example.hello")
        let appex = try makeAppex(in: scratch)
        let products = try products(app: app.path, extra: appexProduct(appex))

        let output = try IPAPackager(inputs: inputs, products: products).write()

        let modes = try IPAPackager.modes(of: output.path)
        XCTAssertEqual(modes["Payload/Hello.app/PlugIns/HelloWidgets.appex/HelloWidgets"], 0o755)
        XCTAssertEqual(modes["Payload/Hello.app/PlugIns/HelloWidgets.appex/Assets.car"], 0o644)
    }

    /// An app that already has a `PlugIns` folder of its own keeps it, and the
    /// widget joins it: the archive names each folder once, however the folder
    /// came to be. A zip with the same member twice is one unzip warns about.
    func testAFolderTheAppAlreadyHasIsNamedOnce() throws {
        let scratch = try scratchDirectory("apelin-ipa")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputs = try makeInputs(scratch)
        let app = try makeApp(in: scratch, identifier: "com.example.hello")
        let plugins = app.appendingPathComponent("PlugIns", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: plugins.appendingPathComponent("Notes.txt"))
        let appex = try makeAppex(in: scratch)

        let output = try IPAPackager(inputs: inputs, products: products(app: app.path, extra: appexProduct(appex))).write()

        let names = IPAPackager.names(of: output.path)
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
        XCTAssertTrue(names.contains("Payload/Hello.app/PlugIns/"), "\(names)")
        XCTAssertTrue(names.contains("Payload/Hello.app/PlugIns/Notes.txt"), "\(names)")
        XCTAssertTrue(names.contains("Payload/Hello.app/PlugIns/HelloWidgets.appex"), "\(names)")
        XCTAssertEqual(try IPAPackager.verify(path: output.path, bundle: "Hello.app"), 7)
    }

    /// An extension that is not one is refused before the archive is written:
    /// iOS would drop the whole app over it.
    func testAnExtensionThatIsNotOneIsRefused() throws {
        let scratch = try scratchDirectory("apelin-ipa")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let inputs = try makeInputs(scratch)
        let app = try makeApp(in: scratch, identifier: "com.example.hello")

        // An identifier the app does not host.
        let outside = try makeAppex(in: scratch, name: "OutsideWidgets", identifier: "com.example.other.widgets")
        XCTAssertThrowsError(try IPAPackager(inputs: inputs, products: products(app: app.path, extra: appexProduct(outside))).write()) {
            XCTAssertTrue("\($0)".contains("not under the app's"), "\($0)")
        }

        // No extension point.
        let pointless = try makeAppex(in: scratch, name: "PointlessWidgets", point: nil)
        XCTAssertThrowsError(try IPAPackager(inputs: inputs, products: products(app: app.path, extra: appexProduct(pointless))).write()) {
            XCTAssertTrue("\($0)".contains("NSExtensionPointIdentifier"), "\($0)")
        }

        // No executable where the Info.plist says it is.
        let gone = try makeAppex(in: scratch, name: "GoneWidgets")
        try FileManager.default.removeItem(at: gone.appendingPathComponent("GoneWidgets"))
        XCTAssertThrowsError(try IPAPackager(inputs: inputs, products: products(app: app.path, extra: appexProduct(gone))).write()) {
            XCTAssertTrue("\($0)".contains("CFBundleExecutable"), "\($0)")
        }

        // No Info.plist at all.
        let bare = try makeAppex(in: scratch, name: "BareWidgets")
        try FileManager.default.removeItem(at: bare.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try IPAPackager(inputs: inputs, products: products(app: app.path, extra: appexProduct(bare))).write()) {
            XCTAssertTrue("\($0)".contains("no Info.plist"), "\($0)")
        }
    }

    /// One spelling for the format, whatever spells it: the schema's enum
    /// value, the wire's, and the record's.
    func testTheIpaFormatIsSpelledOneWay() {
        XCTAssertEqual(ProjectDocument.Package.Format.ipa.rawValue, BuildArtifact.ipaFormat)
        XCTAssertEqual(ProjectDocument.Package.Format.deb.rawValue, "deb")
    }
}
