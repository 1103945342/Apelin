import Foundation

/// What Swift's direct C++ interop needs for one product or one Swift module:
/// whether it is on, the C++ headers its Swift sources import, and the one
/// standard the importer and native C++ must agree on. Resolved from the
/// project description — never from a build flag — so `projectCheck`, the
/// build and a reader of the file all see the same answer.
public struct CXXInteropSettings: Sendable, Equatable {
    /// `-cxx-interoperability-mode=default` when true; no flag when false.
    public var enabled: Bool
    /// Directories, as the project spells them, that hold the C++ headers the
    /// Swift sources import: those of the `swiftModules` entries in the
    /// closure that turn interop on — a module's own first and then the ones
    /// it imports when the module itself is resolved, and in the order the
    /// modules are built for a product. A product's own `headerSearchPaths`
    /// are not here — the build passes those already, to Swift and to clang
    /// alike.
    public var headerSearchPaths: [String]
    /// The `-std=` the importer and the product's C++ files are compiled
    /// with: what the closure names, or `c++17` when it names none. Nil when
    /// interop is off.
    public var standard: String?

    /// What the importer and clang assume when nothing in the closure names a
    /// standard.
    public static let defaultStandard = "c++17"

    /// The oldest standards Swift's C++ interop takes: the importer is built
    /// on C++14. A project's own C++ files may keep `c++11` while interop is
    /// off; nothing in an interop closure may.
    public static let minimumStandards: Set<String> = ["c++14", "c++17", "c++20", "c++23", "gnu++14", "gnu++17", "gnu++20", "gnu++23"]

    /// Interop off: no flags, no include paths, no standard.
    public static let disabled = CXXInteropSettings(enabled: false, headerSearchPaths: [], standard: nil)

    public init(enabled: Bool, headerSearchPaths: [String] = [], standard: String? = nil) {
        self.enabled = enabled
        self.headerSearchPaths = headerSearchPaths
        self.standard = standard
    }
}

/// A project whose C++ interop members contradict each other: a product or a
/// module says no while something it builds with says yes, or the closure
/// names two standards. `field` is the member to fix, spelled as
/// `projectCheck` names it, such as `/products/0/cxxInterop`.
public struct CXXInteropError: Error, CustomStringConvertible, Sendable, Equatable {
    public var field: String?
    public var reason: String

    public var description: String {
        field.map { "\($0): \(reason)" } ?? reason
    }

    public init(field: String?, reason: String) {
        self.field = field
        self.reason = reason
    }
}

extension ProjectDocument {
    /// The interop `product` builds with. Off — the everyday answer — unless
    /// the product names `cxxInterop: true` or a `swiftModules` entry in its
    /// closure does, which turns it on for the product too. Throws when the
    /// members disagree: a `false` beside an enabled module, a standard below
    /// C++14, or two standards in one closure.
    public func cxxInteropSettings(for product: Product) throws -> CXXInteropSettings {
        let resolution = CXXInteropResolution(self)
        let index = products.firstIndex(of: product)
        let field = index.map { "/products/\($0)" } ?? "/products"
        let closure = try resolution.closure(from: product.swiftModules ?? [], field: "\(field)/swiftModules")
        let enabled = resolution.enabled(in: closure)
        if product.cxxInterop == false, let name = closure.first(where: enabled.contains) {
            throw CXXInteropError(
                field: "\(field)/cxxInterop",
                reason: "\(product.id) sets cxxInterop to false, but swift module \(name) in its closure turns it on: "
                    + "remove the false or the module's cxxInterop"
            )
        }
        try resolution.checkModuleConflicts(closure)
        guard product.cxxInterop == true || !enabled.isEmpty else { return .disabled }
        let named = closure.filter(enabled.contains)
        let own = product.cxxStandard.map {
            CXXInteropResolution.Standard($0, "product \(product.id)", "\(field)/cxxStandard")
        }
        let standard = try resolution.standard(own, modules: named, field: "\(field)/cxxStandard")
        var paths: [String] = []
        for name in named {
            paths += resolution.module(name)?.headerSearchPaths ?? []
        }
        return CXXInteropSettings(enabled: true, headerSearchPaths: resolution.unique(paths), standard: standard)
    }

    /// The interop `module` compiles its Swift sources with: its own
    /// `cxxInterop`, or any module it imports. Its own header search paths
    /// come first, then those of the modules it imports. Throws on the same
    /// disagreements `cxxInteropSettings(for: product)` does.
    public func cxxInteropSettings(for module: SwiftModule) throws -> CXXInteropSettings {
        let resolution = CXXInteropResolution(self)
        let index = (swiftModules ?? []).firstIndex(of: module)
        let field = index.map { "/swiftModules/\($0)" } ?? "/swiftModules"
        let closure = try resolution.closure(from: [module.name], field: "\(field)/dependencies")
        let enabled = resolution.enabled(in: closure)
        if module.cxxInterop == false, enabled.contains(module.name),
           let dependency = resolution.firstEnabledDependency(of: module)
        {
            throw CXXInteropError(
                field: "\(field)/cxxInterop",
                reason: "\(module.name) sets cxxInterop to false, but swift module \(dependency) it depends on turns it on: "
                    + "remove the false or the dependency's cxxInterop"
            )
        }
        try resolution.checkModuleConflicts(closure)
        guard enabled.contains(module.name) else { return .disabled }
        let named = closure.filter { enabled.contains($0) && $0 != module.name }
        let own = module.cxxStandard.map {
            CXXInteropResolution.Standard($0, "swift module \(module.name)", "\(field)/cxxStandard")
        }
        let standard = try resolution.standard(own, modules: named, field: "\(field)/cxxStandard")
        let order = [module.name] + named
        var paths: [String] = []
        for name in order {
            paths += resolution.module(name)?.headerSearchPaths ?? []
        }
        return CXXInteropSettings(enabled: true, headerSearchPaths: resolution.unique(paths), standard: standard)
    }
}

/// The module index and closure walk behind `cxxInteropSettings`: written
/// once so both entry points agree on cycles, on what a module's closure is,
/// and on which members turn interop on.
struct CXXInteropResolution {
    struct Standard {
        var value: String
        var origin: String
        var field: String

        init(_ value: String, _ origin: String, _ field: String) {
            self.value = value
            self.origin = origin
            self.field = field
        }
    }

    private let positions: [String: Int]
    private let byName: [String: ProjectDocument.SwiftModule]

    init(_ project: ProjectDocument) {
        var positions: [String: Int] = [:]
        var byName: [String: ProjectDocument.SwiftModule] = [:]
        for (index, module) in (project.swiftModules ?? []).enumerated() where positions[module.name] == nil {
            positions[module.name] = index
            byName[module.name] = module
        }
        self.positions = positions
        self.byName = byName
    }

    func module(_ name: String) -> ProjectDocument.SwiftModule? {
        byName[name]
    }

    func index(of name: String) -> Int {
        positions[name] ?? 0
    }

    /// `names` and everything they import, each once, a module after the
    /// modules it imports. A cycle stops at the name already on the stack
    /// instead of looping; `ProjectValidation` refuses such a project, and a
    /// build that reached the resolver anyway still answers.
    func closure(from names: [String], field: String) throws -> [String] {
        var visited: Set<String> = []
        var order: [String] = []
        func add(_ name: String) throws {
            guard visited.insert(name).inserted else { return }
            guard let module = byName[name] else {
                throw CXXInteropError(field: field, reason: "the project declares no swift module \(name)")
            }
            for dependency in module.dependencies ?? [] {
                try add(dependency)
            }
            order.append(name)
        }
        for name in names {
            try add(name)
        }
        return order
    }

    /// The members of `closure` that turn interop on, directly or through
    /// anything they import: the least fixed point, so a cycle that holds a
    /// `true` is on and one that does not is off.
    func enabled(in closure: [String]) -> Set<String> {
        var memo: [String: Bool] = [:]
        var stack: Set<String> = []
        var on: Set<String> = []
        for name in closure where enables(name, &memo, &stack) {
            on.insert(name)
        }
        return on
    }

    private func enables(_ name: String, _ memo: inout [String: Bool], _ stack: inout Set<String>) -> Bool {
        if let known = memo[name] {
            return known
        }
        guard let module = byName[name] else { return false }
        if module.cxxInterop == true {
            memo[name] = true
            return true
        }
        guard stack.insert(name).inserted else { return false }
        var result = false
        for dependency in module.dependencies ?? [] where !result {
            result = enables(dependency, &memo, &stack)
        }
        stack.remove(name)
        memo[name] = result
        return result
    }

    /// A module that says `false` while a module it imports says yes is a
    /// contradiction wherever it is reached from, so any closure that holds
    /// one is refused before a build gets to it.
    func checkModuleConflicts(_ closure: [String]) throws {
        var memo: [String: Bool] = [:]
        var stack: Set<String> = []
        for name in closure where enables(name, &memo, &stack) {
            guard let module = byName[name], module.cxxInterop == false,
                  let dependency = firstEnabledDependency(of: module)
            else { continue }
            throw CXXInteropError(
                field: "/swiftModules/\(index(of: name))/cxxInterop",
                reason: "\(name) sets cxxInterop to false, but swift module \(dependency) it depends on turns it on: "
                    + "remove the false or the dependency's cxxInterop"
            )
        }
    }

    func firstEnabledDependency(of module: ProjectDocument.SwiftModule) -> String? {
        var memo: [String: Bool] = [:]
        var stack: Set<String> = []
        return (module.dependencies ?? []).first { enables($0, &memo, &stack) }
    }

    /// The one standard the importer and native C++ see. Nothing named is
    /// `c++17`; a closure that names two is refused, and so is one that
    /// names a standard older than the importer supports, even though the
    /// project's own C++ files may keep it while interop is off.
    ///
    /// A module is compiled on its own, so it only ever sees what its own
    /// closure names: one that names nothing is built as `c++17` and must not
    /// sit under a product or module that compiles as something else, or the
    /// two would import the same C++ headers with different layouts. That is
    /// what makes a product inherit a dependency's `c++20` everywhere while
    /// refusing a product's own `c++20` beside a module that never says so.
    func standard(_ node: Standard?, modules: [String], field fallback: String) throws -> String {
        var declared: [Standard] = []
        if let node {
            declared.append(node)
        }
        for name in modules {
            guard let module = byName[name], let value = module.cxxStandard else { continue }
            declared.append(.init(value, "swift module \(name)", "/swiftModules/\(index(of: name))/cxxStandard"))
        }
        for entry in declared where !CXXInteropSettings.minimumStandards.contains(entry.value) {
            throw CXXInteropError(
                field: entry.field,
                reason: "\(entry.value) is older than Swift's C++ interop supports: the importer needs c++14 or newer "
                    + "(a project's own C++ files may keep c++11 while cxxInterop is off)"
            )
        }
        let values = declared.map(\.value)
        if let first = values.first, Set(values).count > 1 {
            let detail = declared.map { "\($0.value) (\($0.origin))" }.joined(separator: ", ")
            throw CXXInteropError(
                field: declared.first { $0.value != first }?.field ?? fallback,
                reason: "the C++ interop closure names more than one standard (\(detail)): "
                    + "the Swift importer and native C++ must see one -std"
            )
        }
        let standard = values.first ?? CXXInteropSettings.defaultStandard
        guard standard != CXXInteropSettings.defaultStandard else { return standard }
        for name in modules {
            let own = try closure(from: [name], field: fallback)
            let named = enabled(in: own).compactMap { byName[$0]?.cxxStandard }
            if named.isEmpty {
                throw CXXInteropError(
                    field: "/swiftModules/\(index(of: name))/cxxStandard",
                    reason: "\(name) names no cxxStandard and is built as \(CXXInteropSettings.defaultStandard) on its own, "
                        + "while this closure compiles as \(standard): name \(standard) on the module "
                        + "(the importer and native C++ must see one -std)"
                )
            }
        }
        return standard
    }

    /// The paths each once, in the order they are met.
    func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }
}
