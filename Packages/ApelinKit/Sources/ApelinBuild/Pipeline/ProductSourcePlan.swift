import ApelinProject
import Foundation

/// One product's actual inputs, not the template's main language. Keep this
/// plan from compile through link: a glob must not choose a different linker
/// if a source is added or removed between the two steps.
struct ProductSourcePlan {
    struct Source {
        var path: String
        var language: SourceLanguage
    }

    var sources: [Source]
    var swift: [Source] { sources.filter { $0.language == .swift } }
    var clang: [Source] { sources.filter { $0.language != .swift } }
    var usesCXX: Bool { sources.contains { $0.language.isCXX } }
    var usesObjC: Bool { sources.contains { $0.language.isObjC } }
    var usesSwift: Bool { !swift.isEmpty }

    init(paths: [String]) throws {
        sources = try paths.map { path in
            guard let language = SourceLanguage(path: path) else {
                throw BuildFailure("unsupported source language: \(path)")
            }
            return Source(path: path, language: language)
        }
    }

    /// clang accepts an explicit language with no need for a clang++ alias.
    static func clangLanguage(_ language: SourceLanguage) -> String {
        switch language {
        case .c: "c"
        case .objc: "objective-c"
        case .cxx: "c++"
        case .objcxx: "objective-c++"
        case .swift: preconditionFailure("Swift is compiled with swiftc")
        }
    }

    /// A mixed executable normally has a native entry point or Swift @main;
    /// main.swift explicitly opts into Swift's top-level entry point. Preserve
    /// the previous implicit-top-level behavior for pure Swift executables.
    func parsesSwiftAsLibrary(type: ProductType) -> Bool {
        if type == .dylib || type == .bundle || type == .appex { return true }
        return !clang.isEmpty && !swift.contains { ($0.path as NSString).lastPathComponent == "main.swift" }
    }
}
