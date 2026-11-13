import Foundation

/// `apelin-project.json` against its schema, then the rules the schema
/// cannot say (Documents/Schemas/README.md, "beyond the schema"). Ported
/// from the reference implementation's `validate_project` and
/// `project_semantic_errors`, messages included.
public enum ProjectValidation {
    public static let schema = SchemaValidator(schema: try! StrictJSON.parse(Data(EmbeddedSchemas.project.utf8)))

    /// The schema as written, for a reader: the agent's apelin-project-description
    /// skill hands it to a model that asks.
    public static let schemaText = EmbeddedSchemas.project

    public static func errors(_ document: JSONDocument) -> [String] {
        let errors = schema.errors(document)
        guard errors.isEmpty else { return errors }
        do {
            return try semanticErrors(ProjectDocument(document: document))
        } catch {
            return ["/: \(error)"]
        }
    }

    /// Parses and validates; the typed document, or every error.
    public static func load(_ data: Data) throws -> (document: JSONDocument, project: ProjectDocument) {
        let document = try StrictJSON.parse(data)
        let problems = errors(document)
        guard problems.isEmpty else { throw ProjectInvalid(errors: problems) }
        return try (document, ProjectDocument(document: document))
    }

    private static let stepOrder = [
        "compile": 0, "link": 1, "bundle-resources": 2, "lipo": 3, "dsym": 4, "strip": 5, "sign": 6,
    ]

    public static func semanticErrors(_ project: ProjectDocument) -> [String] {
        var errors: [String] = []
        var products: [String: ProjectDocument.Product] = [:]
        for product in project.products where products[product.id] == nil {
            products[product.id] = product
        }
        if products.count != project.products.count {
            errors.append("/products: product ids must be unique")
        }
        let names = project.products.map(\.name)
        if Set(names).count != names.count {
            errors.append("/products: product names must be unique")
        }
        var seen: [String: [String]] = [:]
        var order: [String] = []
        for product in project.products where seen[product.id] == nil {
            seen[product.id] = []
            order.append(product.id)
        }
        var scriptIDs: Set<String> = []
        for (index, step) in project.build.steps.enumerated() {
            let location = "/build/steps/\(index)"
            if case let .script(id, _, _, _, _, _) = step {
                if scriptIDs.contains(id) {
                    errors.append("\(location): script id \(id) is used twice")
                }
                scriptIDs.insert(id)
                continue
            }
            let pid = step.product!
            guard let product = products[pid] else {
                errors.append("\(location): unknown product \(pid)")
                continue
            }
            let type = step.typeName
            let done = seen[pid]!
            if done.contains(type) {
                errors.append("\(location): \(type) appears twice for \(pid)")
            }
            if let last = done.last, stepOrder[type]! < stepOrder[last]! {
                errors.append("\(location): \(type) cannot follow \(last) for \(pid)")
            }
            if type == "bundle-resources", product.type != .app, product.type != .appex, product.type != .bundle {
                errors.append("\(location): bundle-resources is only for app, appex and bundle products")
            }
            seen[pid]!.append(type)
        }
        for pid in order {
            let done = seen[pid]!
            for required in ["compile", "link", "lipo", "sign"] where !done.contains(required) {
                errors.append("/build/steps: \(pid) has no \(required) step")
            }
            if let type = products[pid]?.type,
               type == .app || type == .appex || type == .bundle,
               !done.contains("bundle-resources")
            {
                errors.append("/build/steps: \(pid) has no bundle-resources step")
            }
            if let last = done.last, last != "sign" {
                errors.append("/build/steps: sign must be the last step for \(pid)")
            }
        }
        let package = project.package
        if package.effectiveFormat == .ipa {
            if project.kind != .app {
                errors.append("/package/format: an .ipa is built from an app project")
            }
            let apps = project.products.filter { $0.type == .app }
            if apps.count != 1 {
                errors.append("/package/format: an .ipa carries exactly one app product, and this project has \(apps.count)")
            }
        }
        for (index, entry) in package.layout.enumerated() {
            if let product = entry.product, products[product] == nil {
                errors.append("/package/layout/\(index): unknown product \(product)")
            }
        }
        let paths = package.layout.map(\.path)
        if Set(paths).count != paths.count {
            errors.append("/package/layout: two entries install to the same path")
        }
        for relation in package.depends ?? []
            where relation.split(separator: " ", omittingEmptySubsequences: false).first == "firmware"
        {
            errors.append("/package/depends: firmware is added from deploymentTarget by the packager")
        }
        if let filter = package.tweakFilter {
            if products[filter.dylib]?.type != .dylib {
                errors.append("/package/tweakFilter/dylib: must name a dylib product")
            } else if !package.layout.contains(where: {
                $0.product == filter.dylib && $0.path.hasPrefix(TweakFilterPlist.directory + "/")
            }) {
                errors.append("/package/tweakFilter: the dylib must be installed under /Library/MobileSubstrate/DynamicLibraries/")
            }
        }
        let bootstraps = Set(project.architectures.bootstraps)
        if let byBootstrap = package.dependsByBootstrap {
            for bootstrap in Bootstrap.allCases where byBootstrap[bootstrap] != nil && !bootstraps.contains(bootstrap) {
                errors.append("/package/dependsByBootstrap/\(bootstrap.rawValue): the project does not build for \(bootstrap.rawValue)")
            }
        }
        for (index, product) in project.products.enumerated() {
            for source in product.sources {
                if let problem = unsupportedSourceError(source) {
                    errors.append("/products/\(index)/sources: \(problem)")
                }
            }
        }
        errors += swiftModuleErrors(project)
        errors += cxxInteropErrors(project)
        return errors
    }

    /// Swift's C++ interop, resolved exactly as the build resolves it, so a
    /// file that contradicts itself never reaches a compiler: a `false` on a
    /// product or module beside an enabled one in its closure, a standard the
    /// importer cannot take, or two standards in one closure. Each error is
    /// the resolver's, field path included, reported once.
    private static func cxxInteropErrors(_ project: ProjectDocument) -> [String] {
        var errors: [String] = []
        var seen: Set<String> = []
        func take(_ work: () throws -> CXXInteropSettings) {
            do {
                _ = try work()
            } catch let error as CXXInteropError {
                if seen.insert(error.description).inserted {
                    errors.append(error.description)
                }
            } catch {
                errors.append(String(describing: error))
            }
        }
        for (index, product) in project.products.enumerated() {
            take {
                let settings = try project.cxxInteropSettings(for: product)
                // Swift's ClangImporter does not import a bridging header at
                // all while -cxx-interoperability-mode is on, and says
                // nothing about it: every declaration it holds would simply be
                // missing from Swift. A parse failure above is left to speak
                // for itself rather than be replaced by this.
                if settings.enabled, let header = product.bridgingHeader {
                    throw CXXInteropError(
                        field: "/products/\(index)/bridgingHeader",
                        reason: "\(header) cannot be combined with C++ interop: Swift's importer drops the bridging header "
                            + "when -cxx-interoperability-mode is on; declare those C declarations in a module of a "
                            + "module.modulemap under headerSearchPaths instead"
                    )
                }
                return settings
            }
        }
        for module in project.swiftModules ?? [] {
            take { try project.cxxInteropSettings(for: module) }
        }
        return errors
    }

    /// A product's `sources` entry names files this project can compile. A
    /// definite extension must be one of the languages `SourceLanguage`
    /// knows; a pattern may spell one (`Sources/*.mm`) or none at all
    /// (`Sources/*`), and the files it expands to are classified by
    /// `projectCheck`, which is the only place an actual file is seen.
    static func unsupportedSourceError(_ source: String) -> String? {
        if SourceLanguage(path: source) != nil {
            return nil
        }
        let suffix = pathExtension(source)
        let isPattern = source.contains("*") || source.contains("?")
        guard !isPattern || (!suffix.isEmpty && !suffix.contains("*") && !suffix.contains("?")) else {
            return nil
        }
        return "\(source) is not a .c, .m, .cpp, .cc, .cxx, .mm or .swift source"
    }

    /// A Swift module is Swift only, under the same pattern rule: what a
    /// pattern expands to is checked once the files are known.
    static func unsupportedModuleSourceError(_ source: String) -> String? {
        if SourceLanguage(path: source) == .swift {
            return nil
        }
        let suffix = pathExtension(source)
        let isPattern = source.contains("*") || source.contains("?")
        guard !isPattern || (!suffix.isEmpty && !suffix.contains("*") && !suffix.contains("?")) else {
            return nil
        }
        return "\(source) is not a .swift source"
    }

    /// The modules a project carries, and the ones its products name: each an
    /// identifier the schema already checked, built before what depends on it,
    /// and never a product's own name. Any project may carry them — a module
    /// is Swift whatever the project's main language is.
    private static func swiftModuleErrors(_ project: ProjectDocument) -> [String] {
        let modules = project.swiftModules ?? []
        var errors: [String] = []
        var byName: [String: ProjectDocument.SwiftModule] = [:]
        for (index, module) in modules.enumerated() {
            if byName[module.name] == nil {
                byName[module.name] = module
            } else {
                errors.append("/swiftModules/\(index): module \(module.name) is declared twice")
            }
            for source in module.sources {
                if let problem = unsupportedModuleSourceError(source) {
                    errors.append("/swiftModules/\(index)/sources: \(problem)")
                }
            }
        }
        let productNames = Set(project.products.map(\.name))
        for (index, module) in modules.enumerated() {
            if productNames.contains(module.name) {
                errors.append("/swiftModules/\(index)/name: \(module.name) is also a product name")
            }
            for dependency in module.dependencies ?? [] {
                if dependency == module.name {
                    errors.append("/swiftModules/\(index)/dependencies: \(module.name) depends on itself")
                } else if byName[dependency] == nil {
                    errors.append("/swiftModules/\(index)/dependencies: unknown swift module \(dependency)")
                }
            }
        }
        // A module is built before the modules that depend on it, so the
        // modules may not wait for each other.
        var state: [String: Int] = [:]
        var cyclic: Set<String> = []
        func visit(_ name: String) {
            if state[name] != nil {
                if state[name] == 1 {
                    cyclic.insert(name)
                }
                return
            }
            state[name] = 1
            for dependency in byName[name]?.dependencies ?? [] where byName[dependency] != nil {
                visit(dependency)
            }
            state[name] = 2
        }
        for module in modules {
            visit(module.name)
        }
        var reported: Set<String> = []
        for (index, module) in modules.enumerated() where cyclic.contains(module.name) && reported.insert(module.name).inserted {
            errors.append("/swiftModules/\(index)/dependencies: \(module.name) is in a dependency cycle")
        }
        for (index, product) in project.products.enumerated() {
            for name in product.swiftModules ?? [] where byName[name] == nil {
                errors.append("/products/\(index)/swiftModules: unknown swift module \(name)")
            }
        }
        return errors
    }

    /// `os.path.splitext(path)[1]`: the last component's extension with its
    /// dot, empty for none or for a leading-dot name.
    static func pathExtension(_ path: String) -> String {
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        let trimmed = name.drop { $0 == "." }
        guard let dot = trimmed.lastIndex(of: ".") else { return "" }
        return String(trimmed[dot...])
    }
}

/// A project that failed validation, with every error.
public struct ProjectInvalid: Error, CustomStringConvertible, Sendable {
    public var errors: [String]
    public var description: String {
        errors.joined(separator: "; ")
    }
}

/// Where a tweak's filter plist goes and what it holds.
public enum TweakFilterPlist {
    public static let directory = "/Library/MobileSubstrate/DynamicLibraries"
}
