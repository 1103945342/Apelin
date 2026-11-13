import ApelinBuild
import ApelinCore
import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

/// What the native mixed-language build tests share: a CLI project made from
/// the development extension, one product described into it, a static library
/// beside it, and the real pipeline run without packaging.
enum NativeBuild {
    /// The Mac's Xcode and iPhoneOS SDK, or a skip: the pipeline tests run
    /// nowhere else.
    static func requireTools() throws -> StaticEnvironmentRegistry {
        guard let registry = macRegistry() else { throw XCTSkip("no iPhoneOS SDK on this Mac") }
        return registry
    }

    static func installRoot(of bootstrap: Bootstrap) -> String {
        switch bootstrap {
        case .rootless: "/var/jb"
        case .roothide: "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
        }
    }

    /// Writes a project file, making the folders above it.
    static func write(_ contents: String, to relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// The created project's description: one product, and the steps a build to
    /// a signed executable needs — compile, link, lipo, sign. Packaging never
    /// runs here, so the package's layout goes unbuilt.
    ///
    /// `cxxFlags`, `cxxStandard` and `bridgingHeader` are the project
    /// description's own fields; a document that names them still validates.
    static func describe(_ product: [String: Any], cxxFlags: [String]? = nil, in root: URL) throws {
        let manifest = root.appendingPathComponent("apelin-project.json")
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
            "\(manifest.path) is not a JSON object"
        )
        document["products"] = [product]
        var build = try XCTUnwrap(document["build"] as? [String: Any], "the description has no build")
        build["steps"] = [
            ["type": "compile", "product": "tool"],
            ["type": "link", "product": "tool"],
            ["type": "lipo", "product": "tool"],
            ["type": "sign", "product": "tool", "identity": "adhoc"],
        ]
        document["build"] = build
        if let cxxFlags, var configurations = document["configurations"] as? [String: Any] {
            for name in ["Debug", "Release"] {
                var configuration = configurations[name] as? [String: Any] ?? [:]
                configuration["cxxFlags"] = cxxFlags
                configurations[name] = configuration
            }
            document["configurations"] = configurations
        }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifest)
    }

    /// What one build reads, resolved the way the session host resolves it:
    /// the project's toolchain and SDK, and the bootstrap's layout.
    static func inputs(
        _ project: ProjectStore.Created,
        bootstrap: Bootstrap,
        label: String,
        store: ProjectStore,
        catalog: ExtensionCatalog,
        registry: StaticEnvironmentRegistry,
        home: URL
    ) throws -> BuildInputs {
        try BuildInputs.resolve(
            buildID: "\(label)-\(bootstrap.rawValue)",
            projectID: project.projectID,
            configuration: .debug,
            store: store,
            catalog: catalog,
            registry: registry,
            installRoot: installRoot(of: bootstrap),
            home: home.path,
            bootstrap: bootstrap
        )
    }

    /// The tool invocations the build logged (`$ <tool> <arguments…>`), the
    /// first one whose arguments contain every part.
    static func command(in reporter: Collector, _ parts: String...) -> String? {
        reporter.lines.first { line in
            line.hasPrefix("$ ") && parts.allSatisfy { line.contains($0) }
        }
    }

    /// A small static library with one slice per architecture: what a
    /// product's `librarySearchPaths`, `libraries` and a real call to one of
    /// its functions resolve to at link time.
    static func makeStaticLibrary(
        for architectures: [Architecture],
        deploymentTarget: String,
        in root: URL,
        scratch: URL
    ) throws {
        let source = root.appendingPathComponent("Fixture/fixture.c").path
        var thin: [String] = []
        for arch in architectures {
            let object = scratch.appendingPathComponent("fixture-\(arch.rawValue).o").path
            let compiled = try runTool("/usr/bin/xcrun", [
                "--sdk", "iphoneos", "clang",
                "-target", "\(arch.rawValue)-apple-ios\(deploymentTarget)",
                "-c", source, "-o", object,
            ])
            XCTAssertEqual(compiled.status, 0, compiled.output)
            let archive = scratch.appendingPathComponent("libmixedfixture-\(arch.rawValue).a").path
            try? FileManager.default.removeItem(atPath: archive)
            let archived = try runTool("/usr/bin/ar", ["rcs", archive, object])
            XCTAssertEqual(archived.status, 0, archived.output)
            thin.append(archive)
        }
        let library = root.appendingPathComponent("Fixture/lib/libmixedfixture.a")
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        let made = try runTool("/usr/bin/lipo", ["-create"] + thin + ["-output", library.path])
        XCTAssertEqual(made.status, 0, made.output)
    }
}
