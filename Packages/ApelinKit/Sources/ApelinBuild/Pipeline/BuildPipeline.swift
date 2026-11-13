import ApelinCodeSign
import ApelinCore
import ApelinMachO
import ApelinProject
import ApelinProtocol
import Foundation

/// The typed step executor (Milestone 1 §8): `compile` (every source, every
/// architecture, one object each, kept), `link` (one Mach-O per
/// architecture, of the product type's kind), `bundle-resources`, `lipo`,
/// `dsym` (while the objects exist), `strip`, `sign` — last — and `script`,
/// in the order the project lists them. Every tool is the registered
/// toolchain's, run by argv through `ToolRunner`; nothing is a shell string.
public final class BuildPipeline: @unchecked Sendable {
    public let inputs: BuildInputs
    private let reporter: BuildReporter
    private let cancellation: BuildCancellation

    private var objects: [String: [Architecture: [String]]] = [:]
    private var sourcePlans: [String: ProductSourcePlan] = [:]
    private var slices: [String: [Architecture: String]] = [:]
    /// The project's own Swift modules, built once per architecture.
    private var moduleCache: [Architecture: [String: BuiltModule]] = [:]
    @objc private dynamic var bundles: [String: String] = [:]
    @objc private dynamic var merged: [String: String] = [:]
    private var dsyms: [BuildProducts.DSYM] = []
    @objc private dynamic var logHandle: FileHandle?

    public init(inputs: BuildInputs, reporter: BuildReporter, cancellation: BuildCancellation) {
        self.inputs = inputs
        self.reporter = reporter
        self.cancellation = cancellation
    }

    private var project: ProjectDocument {
        inputs.project
    }

    private var configuration: ProjectDocument.Configuration {
        project.configuration(inputs.configuration)
    }

    private var architectures: [Architecture] {
        project.architectures[inputs.bootstrap] ?? []
    }

    @objc private dynamic var work: URL {
        inputs.workDirectory
    }

    @objc private dynamic var root: String {
        inputs.projectRoot.path
    }

    @objc public dynamic var logURL: URL {
        work.appendingPathComponent("build.log")
    }

    public func run() throws -> BuildProducts {
        try FileManager.default.createDirectory(
            at: work.appendingPathComponent("tmp"),
            withIntermediateDirectories: true,
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle?.close() }
        log("apelin-build \(inputs.buildID): \(project.package.id) \(project.package.version), \(inputs.configuration.rawValue), \(inputs.bootstrap.rawValue) [\(architectures.map(\.rawValue).joined(separator: " "))]")
        log("toolchain \(inputs.toolchain.id), SDK \(inputs.sdk.id) at \(inputs.sdk.path)")
        if let line = ManifestFormatting.run(projectRoot: inputs.projectRoot, checkedFiles: inputs.checkedFiles) {
            log(line)
        }

        for step in project.build.steps {
            if cancellation.isCancelled {
                throw BuildCancelled()
            }
            reporter.stage(step.typeName, product: step.product)
            switch step {
            case let .compile(id, flags): try compile(product(id), flags: flags)
            case let .link(id, flags): try link(product(id), flags: flags)
            case let .bundleResources(id): try bundleResources(product(id))
            case let .lipo(id): try lipo(product(id))
            case let .dsym(id): try dsym(product(id))
            case let .strip(id, style): try strip(product(id), style: style)
            case let .sign(id): try sign(product(id))
            case let .script(id, interpreter, file, arguments, _, _):
                try script(id: id, interpreter: interpreter, file: file, arguments: arguments)
            }
        }
        return try collect()
    }

    private func product(_ id: String) throws -> ProjectDocument.Product {
        guard let product = project.product(id) else { throw BuildFailure("no product \(id)") }
        return product
    }

    // MARK: Tools

    @objc private dynamic func tool(_ name: String) throws -> String {
        let path = inputs.toolchain.tool(name).path
        guard access(path, X_OK) == 0 else {
            throw BuildFailure("toolchain \(inputs.toolchain.id) has no runnable \(name)")
        }
        return path
    }

    @objc private dynamic var environment: [String: String] {
        let bin = inputs.toolchain.tool("").deletingLastPathComponent().path
        let bootstrapBin = inputs.installRoot == "/"
            ? ""
            : inputs.installRoot + "/usr/bin:" + inputs.installRoot + "/bin:"
        return [
            "PATH": "\(bin):\(bootstrapBin)/usr/bin:/bin",
            "HOME": inputs.home,
            "TMPDIR": work.appendingPathComponent("tmp").path + "/",
            "LANG": "C",
            "LC_ALL": "C",
        ]
    }

    /// Runs a tool; its output goes to the log, its diagnostics to the
    /// reporter, and a non-zero exit is a failure carrying them.
    @discardableResult
    private func execute(
        _ executable: String,
        _ arguments: [String],
        label: String,
        workingDirectory: String? = nil,
    ) throws -> ToolResult {
        let invocation = ToolInvocation(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory ?? root,
            environment: environment,
        )
        log("$ " + invocation.displayLine)
        let result = try ToolRunner.run(invocation, cancellation: cancellation) { [self] line in log(line) }
        let diagnostics = ToolDiagnostics.parse(result.output, tool: label, projectRoot: root)
        diagnostics.forEach(reporter.diagnostic)
        guard result.succeeded else {
            throw BuildFailure("\(label) failed with status \(result.status)", diagnostics: diagnostics)
        }
        return result
    }

    @objc private dynamic func log(_ line: String) {
        reporter.log(line)
        logHandle?.write(Data((line + "\n").utf8))
    }

    @objc private dynamic func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    // MARK: What the build always adds

    @objc private dynamic var bootstrapDefine: String {
        "APELIN_BOOTSTRAP_\(inputs.bootstrap.rawValue.uppercased())"
    }

    @objc private dynamic var configurationDefine: String {
        "APELIN_CONFIGURATION_\(inputs.configuration == .debug ? "DEBUG" : "RELEASE")"
    }

    private var defines: [(String, String)] {
        var out: [(String, String)] = [
            ("APELIN_BUILD_ID", "\"\(inputs.buildID)\""),
            ("APELIN_PACKAGE_ID", "\"\(project.package.id)\""),
            ("APELIN_VERSION", "\"\(project.package.version)\""),
            (bootstrapDefine, "1"),
            (configurationDefine, "1"),
        ]
        out += (configuration.defines ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return out
    }

    private struct Support {
        var includes: [String] = []
        var libraryDirectories: [String] = []
        var rpaths: [String] = []
    }

    /// The extension support components a product uses, for this bootstrap.
    private func support(for product: ProjectDocument.Product) throws -> Support {
        var out = Support()
        for reference in product.extensionSupport ?? [] {
            guard let found = inputs.catalog.usableExtension(reference.extension),
                  let component = found.manifest?.support?[reference.component]
            else {
                throw BuildFailure("\(reference.extension) (\(reference.component)) is not installed")
            }
            for directory in component.includeDirectories ?? [] {
                try out.includes.append(ProjectFiles.resolve(directory, in: found.root))
            }
            if let stubs = component.linkStubDirectories?[inputs.bootstrap] {
                try out.libraryDirectories.append(ProjectFiles.resolve(stubs, in: found.root))
            } else if component.linkStubDirectories != nil {
                throw BuildFailure(
                    "\(reference.extension) (\(reference.component)) has no link stubs for \(inputs.bootstrap.rawValue)",
                )
            }
            let prefix = inputs.bootstrap == .rootless ? "/var/jb" : ""
            out.rpaths += (component.rpaths?[inputs.bootstrap] ?? [])
                .map { $0.replacingOccurrences(of: "@PREFIX@", with: prefix) }
        }
        return out
    }

    private func targetFlags(_ arch: Architecture) -> [String] {
        ["-target", swiftTarget(arch), "-isysroot", inputs.sdk.path, "-arch", arch.rawValue,
         "-mios-version-min=\(project.deploymentTarget)"]
    }

    /// The SDK's Swift interfaces are built once per toolchain and SDK, into a
    /// cache beside the builds (`Builds/.swift-module-cache/`), not again for
    /// every build. A retargeted toolchain has no libSwiftScan: the driver is
    /// told so rather than warning on every run before it falls back the same.
    @objc private dynamic var swiftToolFlags: [String] {
        let cache = work.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".swift-module-cache/\(inputs.toolchain.id)-\(inputs.sdk.id)")
        var flags = ["-module-cache-path", cache.path]
        if inputs.toolchain.version.compare("15.0", options: .numeric) != .orderedAscending {
            flags.append("-nonlib-dependency-scanner")
        }
        return flags
    }

    private func swiftTarget(_ arch: Architecture) -> String {
        "\(arch.rawValue)-apple-ios\(project.deploymentTarget)"
    }

    // MARK: Swift modules a project carries

    /// A module the project's sources make, built for one architecture: the
    /// folder its `.swiftmodule` sits in, which a product imports it with
    /// (`-I`), and the object the product links.
    private struct BuiltModule {
        var include: String
        var object: String
    }

    /// Every declared module, each after the modules it depends on and in the
    /// project's order otherwise. A cycle is refused here too, so a project
    /// that reached a build without a check still stops with a reason.
    private func orderedModules() throws -> [ProjectDocument.SwiftModule] {
        let declared = project.swiftModules ?? []
        var byName: [String: ProjectDocument.SwiftModule] = [:]
        for module in declared where byName[module.name] == nil {
            byName[module.name] = module
        }
        var ordered: [ProjectDocument.SwiftModule] = []
        var done: Set<String> = []
        var visiting: Set<String> = []
        func add(_ module: ProjectDocument.SwiftModule, after dependents: [String]) throws {
            if done.contains(module.name) {
                return
            }
            guard visiting.insert(module.name).inserted else {
                let cycle = (dependents + [module.name]).joined(separator: " → ")
                throw BuildFailure("swift modules depend on each other in a cycle: \(cycle)")
            }
            for dependency in module.dependencies ?? [] {
                guard let found = byName[dependency] else {
                    throw BuildFailure("swift module \(module.name) depends on \(dependency), which the project does not declare")
                }
                try add(found, after: dependents + [module.name])
            }
            visiting.remove(module.name)
            done.insert(module.name)
            ordered.append(module)
        }
        for module in declared {
            try add(module, after: [])
        }
        return ordered
    }

    /// The modules a product compiles against and links, in the order they are
    /// built, built for `arch` the first time one asks: each is compiled from
    /// the project's own files with `swiftc`, into one `.swiftmodule` and one
    /// object. Nothing is resolved, fetched or downloaded — a vendored package
    /// is a folder of the project like any other, and its own `Package.swift`
    /// is never read.
    private func builtModules(of product: ProjectDocument.Product, for arch: Architecture) throws -> [BuiltModule] {
        guard !(product.swiftModules ?? []).isEmpty else { return [] }
        let built = try buildModules(for: arch)
        return try moduleClosure(of: product).map { name in
            guard let module = built[name] else {
                throw BuildFailure("\(product.id): swift module \(name) was not built")
            }
            return module
        }
    }

    /// The names a product links, each once and a module before the modules
    /// that depend on it: a module a module imports is linked although the
    /// product never names it.
    private func moduleClosure(of product: ProjectDocument.Product) throws -> [String] {
        var byName: [String: ProjectDocument.SwiftModule] = [:]
        for module in project.swiftModules ?? [] where byName[module.name] == nil {
            byName[module.name] = module
        }
        var reached: Set<String> = []
        var order: [String] = []
        func add(_ name: String) throws {
            guard reached.insert(name).inserted else { return }
            guard let module = byName[name] else {
                throw BuildFailure("\(product.id): the project declares no swift module \(name)")
            }
            for dependency in module.dependencies ?? [] {
                try add(dependency)
            }
            order.append(name)
        }
        for name in product.swiftModules ?? [] {
            try add(name)
        }
        return order
    }

    /// Builds each declared module for `arch`, once per build. The project's
    /// defines are not passed: a package's own configuration is its own, and
    /// `APELIN_BUILD_ID` is not something it reads.
    private func buildModules(for arch: Architecture) throws -> [String: BuiltModule] {
        if let built = moduleCache[arch] {
            return built
        }
        var built: [String: BuiltModule] = [:]
        for module in try orderedModules() {
            let directory = work.appendingPathComponent("modules/\(arch.rawValue)/\(module.name)").path
            try makeDirectory(directory)
            let sources = try ProjectGlob.expand(module.sources, in: inputs.projectRoot)
            guard !sources.isEmpty else {
                throw BuildFailure("swift module \(module.name): the sources match no file")
            }
            let object = directory + "/\(module.name).o"
            var argv = [
                "-sdk", inputs.sdk.path, "-target", swiftTarget(arch), "-wmo", "-c", "-parse-as-library",
                "-module-name", module.name,
            ] + swiftToolFlags
            argv.append(configuration.optimization == "0" ? "-Onone" : "-O")
            argv += ["-debug-prefix-map", "\(root)=."]
            if configuration.debugInfo {
                argv.append("-g")
            }
            for dependency in module.dependencies ?? [] {
                guard let found = built[dependency] else {
                    throw BuildFailure("swift module \(module.name) is built before \(dependency)")
                }
                argv += ["-I", found.include]
            }
            argv += ["-emit-module", "-emit-module-path", directory + "/\(module.name).swiftmodule"]
            argv += sources.map(\.relative)
            argv += ["-o", object]
            try execute(tool("swiftc"), argv, label: "swiftc")
            log("swift module \(module.name): \(sources.count) source(s), \(arch.rawValue)")
            built[module.name] = BuiltModule(include: directory, object: object)
        }
        moduleCache[arch] = built
        return built
    }

    // MARK: Steps

    private func sources(of product: ProjectDocument.Product) throws -> [ProjectGlob.Match] {
        let found = try ProjectGlob.expand(product.sources, in: inputs.projectRoot)
        guard !found.isEmpty else { throw BuildFailure("\(product.id): the sources match no file") }
        return found
    }

    private func compile(_ product: ProjectDocument.Product, flags: [String]) throws {
        let plan = try ProductSourcePlan(paths: sources(of: product).map(\.relative))
        let support = try support(for: product)
        let includes = try (product.headerSearchPaths ?? [])
            .map { try ProjectFiles.resolve($0, in: inputs.projectRoot) } + support.includes
        let frameworks = try (product.frameworkSearchPaths ?? [])
            .map { try ProjectFiles.resolve($0, in: inputs.projectRoot) }
        let bridge: String?
        if let path = product.bridgingHeader {
            guard plan.usesSwift else {
                throw BuildFailure("\(product.id): bridgingHeader requires Swift sources in this product")
            }
            _ = try ProjectFiles.read(path, in: inputs.projectRoot)
            bridge = try ProjectFiles.resolve(path, in: inputs.projectRoot)
        } else {
            bridge = nil
        }
        var produced: [Architecture: [String]] = [:]
        for arch in architectures {
            let directory = work.appendingPathComponent("obj/\(product.id)/\(arch.rawValue)").path
            let swiftDirectory = directory + "/swift"
            try makeDirectory(directory)
            var list: [String] = []
            // Swift emits its Objective-C interface before native compilation,
            // so .m/.mm may import <ProductName-Swift.h> without a script step.
            if plan.usesSwift {
                try makeDirectory(swiftDirectory)
                let object = swiftDirectory + "/\(product.name).o"
                var argv = [
                    "-sdk", inputs.sdk.path, "-target", swiftTarget(arch), "-wmo", "-c", "-module-name", product.name,
                ] + swiftToolFlags
                if plan.parsesSwiftAsLibrary(type: product.type) {
                    argv.append("-parse-as-library")
                }
                argv.append(configuration.optimization == "0" ? "-Onone" : "-O")
                argv += ["-debug-prefix-map", "\(root)=."]
                if configuration.debugInfo {
                    argv.append("-g")
                }
                argv += ["-D", bootstrapDefine, "-D", configurationDefine]
                argv += includes.flatMap { ["-I", $0, "-Xcc", "-I" + $0] }
                argv += frameworks.flatMap { ["-F", $0] }
                if let bridge {
                    argv += ["-import-objc-header", bridge]
                    argv += defines.flatMap { ["-Xcc", "-D\($0.0)=\($0.1)"] }
                    argv += ["-Xcc", "-DAPELIN_PRODUCT_NAME=\"\(product.name)\""]
                }
                if plan.usesObjC {
                    argv += ["-emit-objc-header", "-emit-objc-header-path", swiftDirectory + "/\(product.name)-Swift.h"]
                }
                argv += try builtModules(of: product, for: arch).flatMap { ["-I", $0.include] }
                argv += configuration.swiftFlags ?? []
                argv += flags
                argv += plan.swift.map(\.path)
                argv += ["-o", object]
                try execute(tool("swiftc"), argv, label: "swiftc")
                list.append(object)
            }
            for source in plan.clang {
                // Preserve the relative directory: a/b.c and a__b.c must not
                // overwrite each other, nor collide with the Swift object.
                let object = directory + "/clang/" + source.path + ".o"
                try makeDirectory(URL(fileURLWithPath: object).deletingLastPathComponent().path)
                var argv = targetFlags(arch)
                argv += [
                    "-O\(configuration.optimization)", "-Wall", "-Wextra", "-Werror=unguarded-availability-new",
                    "-fvisibility=hidden", "-ffile-prefix-map=\(root)=.", "-fno-color-diagnostics",
                ]
                if configuration.debugInfo {
                    argv.append("-g")
                }
                if product.objcARC == true, source.language.isObjC {
                    argv.append("-fobjc-arc")
                }
                argv += defines.map { "-D\($0.0)=\($0.1)" }
                argv.append("-DAPELIN_PRODUCT_NAME=\"\(product.name)\"")
                argv += includes.map { "-I" + $0 }
                argv += frameworks.map { "-F" + $0 }
                if plan.usesSwift, source.language.isObjC {
                    argv += ["-I" + swiftDirectory]
                }
                argv += configuration.cFlags ?? []
                if source.language.isCXX {
                    if let standard = product.cxxStandard { argv.append("-std=" + standard) }
                    argv += configuration.cxxFlags ?? []
                }
                argv += flags
                argv += ["-x", ProductSourcePlan.clangLanguage(source.language), "-c", source.path, "-o", object]
                try execute(tool("clang"), argv, label: "clang")
                list.append(object)
            }
            produced[arch] = list
        }
        sourcePlans[product.id] = plan
        objects[product.id] = produced
    }

    private func link(_ product: ProjectDocument.Product, flags: [String]) throws {
        guard let produced = objects[product.id], let plan = sourcePlans[product.id] else {
            throw BuildFailure("\(product.id): link before compile")
        }
        let support = try support(for: product)
        let usesSwift = plan.usesSwift || !(product.swiftModules ?? []).isEmpty
        let libraries = try (product.librarySearchPaths ?? [])
            .map { try ProjectFiles.resolve($0, in: inputs.projectRoot) } + support.libraryDirectories
        let frameworks = try (product.frameworkSearchPaths ?? [])
            .map { try ProjectFiles.resolve($0, in: inputs.projectRoot) } + support.libraryDirectories
        var out: [Architecture: String] = [:]
        for arch in architectures {
            let directory = work.appendingPathComponent("link/\(product.id)/\(arch.rawValue)").path
            try makeDirectory(directory)
            let binary = directory + "/" + fileName(of: product)
            var argv: [String]
            let executable: String
            if usesSwift {
                executable = try tool("swiftc")
                argv = ["-sdk", inputs.sdk.path, "-target", swiftTarget(arch)] + swiftToolFlags
                switch product.type {
                case .dylib:
                    argv += ["-emit-library", "-Xlinker", "-install_name", "-Xlinker", product.effectiveInstallName]
                case .bundle: argv += ["-Xlinker", "-bundle"]
                case .appex: argv += extensionEntryPoint
                case .app, .executable: break
                }
            } else {
                executable = try tool("clang")
                argv = targetFlags(arch)
                switch product.type {
                case .dylib: argv += ["-dynamiclib", "-install_name", product.effectiveInstallName]
                case .bundle: argv += ["-bundle"]
                case .appex: argv += extensionEntryPoint
                case .app, .executable: break
                }
                if product.objcARC == true, plan.usesObjC {
                    argv.append("-fobjc-arc")
                }
            }
            // Both drivers receive the same search paths and link inputs.
            argv += libraries.flatMap { ["-L", $0] }
            argv += frameworks.flatMap { ["-F", $0] }
            argv += support.rpaths.flatMap { ["-Xlinker", "-rpath", "-Xlinker", $0] }
            argv += (product.frameworks ?? []).flatMap { ["-framework", $0] }
            argv += (product.weakFrameworks ?? []).flatMap { ["-Xlinker", "-weak_framework", "-Xlinker", $0] }
            argv += (product.libraries ?? []).map { "-l" + $0 }
            if plan.usesCXX, !(product.libraries ?? []).contains("c++") {
                argv.append("-lc++")
            }
            argv += configuration.linkFlags ?? []
            argv += flags
            argv += produced[arch] ?? []
            argv += try builtModules(of: product, for: arch).map(\.object)
            argv += ["-o", binary]
            try execute(executable, argv, label: "ld")
            if arch == .arm64e {
                try requirePointerSignatures(binary, product: product)
            }
            out[arch] = binary
        }
        slices[product.id] = out
    }

    /// An arm64e slice linked with plain dyld opcodes — CLT 15.0's linker
    /// writes one under `-undefined dynamic_lookup` or `suppress` — has every
    /// signed pointer bound unsigned and dies on the first it uses, a
    /// constant string's class or an imported call. Refused at its link
    /// rather than found on the device.
    private func requirePointerSignatures(_ binary: String, product: ProjectDocument.Product) throws {
        let image = try MachOImage(contentsOfFile: binary)
        for slice in image.slices {
            guard try image.inspect(slice).dyldInfo?.dropsPointerSignatures == true else { continue }
            throw BuildFailure(
                "\(product.id): the linker bound the \(slice.architecture) slice without pointer authentication, "
                    + "so it would crash when it runs. CLT 15.0's linker does this with -undefined dynamic_lookup "
                    + "or suppress: name each symbol left to load time with -Wl,-U,_symbol instead, or link with "
                    + "another toolchain.",
            )
        }
    }

    /// What an `.appex` is linked with: an extension is MH_EXECUTE whose entry
    /// point is Foundation's `NSExtensionMain` — the host's own way in, which
    /// is what Xcode's `LD_ENTRY_POINT` sets — with Foundation linked so the
    /// entry has somewhere to resolve from. The product's own `main` stays in
    /// the image; `NSExtensionMain` is what starts it.
    private var extensionEntryPoint: [String] {
        ["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-framework", "Foundation"]
    }

    /// The directory a product's resources are assembled in: `<name>.app`,
    /// `<name>.appex` or `<name>.bundle`.
    private func bundleSuffix(of product: ProjectDocument.Product) -> String {
        switch product.type {
        case .app: ".app"
        case .appex: ".appex"
        default: ".bundle"
        }
    }

    /// The product's file: `<name>.dylib` for a library, `<name>` otherwise.
    private func fileName(of product: ProjectDocument.Product) -> String {
        product.type == .dylib && !product.name.hasSuffix(".dylib") ? product.name + ".dylib" : product.name
    }

    private func bundleResources(_ product: ProjectDocument.Product) throws {
        guard let infoPlist = product.infoPlist else { throw BuildFailure("\(product.id) has no infoPlist") }
        let suffix = bundleSuffix(of: product)
        let bundle = work.appendingPathComponent("products/\(product.name)\(suffix)").path
        try? FileManager.default.removeItem(atPath: bundle)
        try makeDirectory(bundle)
        let source = try ProjectFiles.read(infoPlist, in: inputs.projectRoot)
        guard var info = try PropertyListSerialization.propertyList(from: source, format: nil) as? [String: Any] else {
            throw BuildFailure("\(infoPlist) is not a dictionary property list")
        }
        if product.type == .appex {
            // What makes the directory an extension and not a bundle: the
            // point it plugs into, and an identifier an app can host.
            guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
                throw BuildFailure("\(infoPlist) has no CFBundleIdentifier, which an .appex needs")
            }
            guard let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                  !point.isEmpty
            else {
                throw BuildFailure("\(infoPlist) has no NSExtension.NSExtensionPointIdentifier, which an .appex needs")
            }
            info["CFBundlePackageType"] = info["CFBundlePackageType"] ?? "XPC!"
            info["CFBundleSupportedPlatforms"] = info["CFBundleSupportedPlatforms"] ?? ["iPhoneOS"]
        }
        info["CFBundleExecutable"] = product.name
        info["CFBundleShortVersionString"] = project.package.version
        info["CFBundleVersion"] = project.package.version
        info["MinimumOSVersion"] = project.deploymentTarget
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: bundle + "/Info.plist"))
        var names: Set<String> = ["Info.plist", product.name]
        for resource in try ProjectGlob.expand(product.resources ?? [], in: inputs.projectRoot) {
            let name = (resource.relative as NSString).lastPathComponent
            guard names.insert(name).inserted else {
                throw BuildFailure("two resources of \(product.id) are named \(name)")
            }
            let target = bundle + "/" + name
            if name.hasSuffix(".plist") {
                let data = try Data(contentsOf: URL(fileURLWithPath: resource.path))
                guard let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                    throw BuildFailure(
                        "\(resource.relative) is not a property list",
                        diagnostics: [
                            ProjectDiagnostic(
                                code: "plist.invalid",
                                severity: .error,
                                message: "not a property list",
                                file: resource.relative,
                            ),
                        ],
                    )
                }
                try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
                    .write(to: URL(fileURLWithPath: target))
            } else {
                try FileManager.default.copyItem(atPath: resource.path, toPath: target)
            }
        }
        log("bundled \(product.name)\(suffix) with \(names.count - 2) resource(s)")
        bundles[product.id] = bundle
    }

    private func lipo(_ product: ProjectDocument.Product) throws {
        guard let built = slices[product.id] else { throw BuildFailure("\(product.id): lipo before link") }
        let destination: String
        if let bundle = bundles[product.id] {
            destination = bundle + "/" + product.name
        } else {
            try makeDirectory(work.appendingPathComponent("products").path)
            destination = work.appendingPathComponent("products/\(fileName(of: product))").path
        }
        try? FileManager.default.removeItem(atPath: destination)
        let inputsInOrder = architectures.compactMap { built[$0] }
        if inputsInOrder.count == 1 {
            try FileManager.default.copyItem(atPath: inputsInOrder[0], toPath: destination)
            log("one architecture: \(fileName(of: product)) is its slice")
        } else {
            try execute(tool("lipo"), ["-create"] + inputsInOrder + ["-output", destination], label: "lipo")
        }
        merged[product.id] = destination
    }

    private func dsym(_ product: ProjectDocument.Product) throws {
        guard let binary = merged[product.id] else { throw BuildFailure("\(product.id): dsym before lipo") }
        let output = work.appendingPathComponent("products/\((binary as NSString).lastPathComponent).dSYM").path
        try? FileManager.default.removeItem(atPath: output)
        let result = try execute(tool("dsymutil"), [binary, "-o", output], label: "dsymutil")
        if result.output.contains("warning:") || result.output.contains("error:") {
            throw BuildFailure("dsymutil warned; the dSYM would not symbolicate: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let dwarfDirectory = output + "/Contents/Resources/DWARF"
        guard let dwarfName = try FileManager.default.contentsOfDirectory(atPath: dwarfDirectory).first else {
            throw BuildFailure("dsymutil made no DWARF file")
        }
        let dwarf = dwarfDirectory + "/" + dwarfName
        let image = try MachOImage(contentsOfFile: dwarf)
        for slice in image.slices {
            let inspection = try image.inspect(slice)
            guard inspection.segments.contains(where: { $0.name == "__DWARF" && $0.sections.contains("__debug_info") }) else {
                throw BuildFailure(
                    "the dSYM of \(product.id) has no __debug_info for \(slice.architecture): build with debugInfo",
                )
            }
        }
        let productUUIDs = try uuids(of: binary)
        let dsymUUIDs = try uuids(of: dwarf)
        guard productUUIDs == dsymUUIDs, !productUUIDs.isEmpty else {
            throw BuildFailure("the dSYM's UUIDs \(dsymUUIDs) differ from the product's \(productUUIDs)")
        }
        log(
            "dSYM \((output as NSString).lastPathComponent): "
                + productUUIDs.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "),
        )
        dsyms.append(BuildProducts.DSYM(product: product.id, path: output, uuids: dsymUUIDs))
    }

    private func strip(_ product: ProjectDocument.Product, style: ProjectDocument.StripStyle) throws {
        guard let binary = merged[product.id] else { throw BuildFailure("\(product.id): strip before lipo") }
        try execute(tool("strip"), [style == .debug ? "-S" : "-x", binary], label: "strip")
    }

    private func sign(_ product: ProjectDocument.Product) throws {
        guard let binary = merged[product.id] else { throw BuildFailure("\(product.id): sign before lipo") }
        let entitlements = try product.entitlements.map { try inputs.readChecked($0) }
        let identifier = (binary as NSString).lastPathComponent
        do {
            try CodeSigner.sign(
                fileAt: URL(fileURLWithPath: binary),
                options: .init(identifier: identifier, entitlements: entitlements),
            )
        } catch {
            throw BuildFailure("signing \(identifier) failed: \(error)")
        }
        log("signed \(identifier) ad hoc (SHA-256)" + (entitlements == nil ? "" : " with \(product.entitlements!)"))
    }

    private func script(
        id: String,
        interpreter: ProjectDocument.ScriptInterpreter,
        file: String,
        arguments: [String],
    ) throws {
        let base = inputs.installRoot == "/" ? "" : inputs.installRoot
        let candidates = [base + "/usr/bin/" + interpreter.rawValue, base + "/bin/" + interpreter.rawValue]
        guard let executable = candidates.first(where: { access($0, X_OK) == 0 }) else {
            throw BuildFailure("script \(id): no \(interpreter.rawValue) in the bootstrap")
        }
        // The script the build digest approved, checked just before it runs.
        // The interpreter opens `file` again by path, as the step's argv
        // promises, so a replacement landing in between is not caught.
        _ = try inputs.readChecked(file)
        try execute(executable, [file] + arguments, label: "script.\(id)")
    }

    // MARK: Results

    @objc private dynamic func uuids(of path: String) throws -> [String: String] {
        let image = try MachOImage(contentsOfFile: path)
        var out: [String: String] = [:]
        for slice in image.slices {
            if let uuid = slice.uuid {
                out[slice.architecture] = uuid.uuidString
            }
        }
        return out
    }

    private func collect() throws -> BuildProducts {
        var products: [BuildProducts.Product] = []
        for product in project.products {
            guard let binary = merged[product.id] else { continue }
            let image = try MachOImage(contentsOfFile: binary)
            let built = Set(image.slices.map(\.architecture))
            let expected = Set(architectures.map(\.rawValue))
            guard built == expected else {
                throw BuildFailure("\(product.id) has slices \(built.sorted()), not \(expected.sorted())")
            }
            guard image.slices.allSatisfy(\.isCodeSigned) else { throw BuildFailure("\(product.id) is not signed") }
            try products.append(BuildProducts.Product(
                id: product.id,
                type: product.type,
                path: bundles[product.id] ?? binary,
                executable: binary,
                digest: CanonicalJSON.sha256Tag(Data(contentsOf: URL(fileURLWithPath: binary))),
                uuids: uuids(of: binary),
            ))
        }
        return BuildProducts(products: products, dsyms: dsyms, log: logURL.path)
    }
}
