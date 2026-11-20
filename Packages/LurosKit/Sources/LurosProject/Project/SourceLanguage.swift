import Foundation

/// The language one source file is compiled as, decided by its extension
/// exactly as clang decides it. A product mixes languages freely: each file
/// names its own compiler mode, so `.c`, `.m`, `.cpp`, `.cc`, `.cxx`, `.C`,
/// `.mm` and `.swift` may sit beside each other in one product.
///
/// `init?(path:)` answers the extension as written, so a glob pattern such
/// as `Sources/*.mm` classifies too; a pattern with no extension
/// (`Sources/**`) answers nil and the files it expands to are classified
/// one by one by `projectCheck`.
public enum SourceLanguage: String, Sendable, CaseIterable, Hashable {
    case c
    case objc
    case cxx
    case objcxx
    case swift

    public init?(path: String) {
        let suffix = (path as NSString).lastPathComponent
        let extension_ = (suffix as NSString).pathExtension
        switch extension_ {
        case "c": self = .c
        case "m": self = .objc
        // `.C` is what clang compiles as C++, and is kept with the rest.
        case "cpp", "cc", "cxx", "C": self = .cxx
        case "mm": self = .objcxx
        case "swift": self = .swift
        default: return nil
        }
    }

    /// C++ or Objective-C++: the files `cxxStandard` and `cxxFlags` apply to.
    public var isCXX: Bool {
        self == .cxx || self == .objcxx
    }

    /// Objective-C or Objective-C++: the files `objcARC` applies to.
    public var isObjC: Bool {
        self == .objc || self == .objcxx
    }
}
