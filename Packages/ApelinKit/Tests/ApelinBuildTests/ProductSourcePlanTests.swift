@testable import ApelinBuild
import ApelinProject
import Foundation
import XCTest

/// `ProductSourcePlan` decides what a product is really made of: every file's
/// extension names its compiler mode, never the template's main language. The
/// plan is made once at compile and kept for the link, so the two steps agree.
final class ProductSourcePlanTests: XCTestCase {
    func testEverySourceLanguageIsClassifiedByItsExtension() throws {
        let paths = [
            "Sources/tool.c",
            "Sources/tool.m",
            "Sources/tool.cpp",
            "Sources/tool.cc",
            "Sources/tool.cxx",
            // `.C` is C++ as clang reads it, and is kept apart from `.c`.
            "Sources/tool.C",
            "Sources/tool.mm",
            "Sources/main.swift",
        ]
        let plan = try ProductSourcePlan(paths: paths)
        XCTAssertEqual(plan.sources.map(\.language), [.c, .objc, .cxx, .cxx, .cxx, .cxx, .objcxx, .swift])
        XCTAssertEqual(plan.swift.map(\.path), ["Sources/main.swift"])
        XCTAssertEqual(plan.clang.map(\.path), Array(paths.dropLast()))
        XCTAssertTrue(plan.usesSwift)
        XCTAssertTrue(plan.usesObjC)
        XCTAssertTrue(plan.usesCXX)
    }

    /// A product with only C is not told it has a C++ or an Objective-C file,
    /// so neither `-lc++` nor ARC is asked for.
    func testAPureCPlanUsesNoOtherLanguage() throws {
        let plan = try ProductSourcePlan(paths: ["Sources/a.c", "Sources/sub/b.c"])
        XCTAssertFalse(plan.usesSwift)
        XCTAssertFalse(plan.usesObjC)
        XCTAssertFalse(plan.usesCXX)
        XCTAssertTrue(plan.swift.isEmpty)
        XCTAssertEqual(plan.clang.count, 2)
    }

    /// Objective-C++ counts as both: `cxxStandard` and ARC apply to it.
    func testObjCXXIsBothObjCAndCXX() throws {
        let plan = try ProductSourcePlan(paths: ["Sources/one.mm"])
        XCTAssertTrue(plan.usesObjC)
        XCTAssertTrue(plan.usesCXX)
        XCTAssertFalse(plan.usesSwift)
    }

    /// Paths are kept as the project spelled them, so two sources whose names
    /// collide once flattened stay two objects.
    func testPathsAreKeptAsWritten() throws {
        let plan = try ProductSourcePlan(paths: ["Sources/a/b.c", "Sources/a__b.c"])
        XCTAssertEqual(plan.clang.map(\.path), ["Sources/a/b.c", "Sources/a__b.c"])
    }

    func testASourceWithNoKnownLanguageIsRefusedByName() {
        for path in ["Sources/notes.txt", "Sources/header.h", "Sources/README", "Sources/main.s"] {
            XCTAssertThrowsError(try ProductSourcePlan(paths: [path])) { error in
                XCTAssertEqual(String(describing: error), "unsupported source language: \(path)")
            }
        }
        // One unknown file refuses the whole plan, even beside known sources.
        XCTAssertThrowsError(try ProductSourcePlan(paths: ["Sources/main.c", "Sources/notes.txt"])) { error in
            XCTAssertEqual(String(describing: error), "unsupported source language: Sources/notes.txt")
        }
    }

    /// clang is given the language explicitly, so no `clang++` alias is
    /// needed for a C++ file.
    func testClangLanguageNames() {
        XCTAssertEqual(ProductSourcePlan.clangLanguage(.c), "c")
        XCTAssertEqual(ProductSourcePlan.clangLanguage(.objc), "objective-c")
        XCTAssertEqual(ProductSourcePlan.clangLanguage(.cxx), "c++")
        XCTAssertEqual(ProductSourcePlan.clangLanguage(.objcxx), "objective-c++")
    }

    /// Swift compiles as a library when a native file holds the entry point;
    /// `main.swift` is what asks for Swift's top-level code instead, and a
    /// dylib, bundle or extension is always a library.
    func testSwiftParsesAsALibraryUnlessMainSwiftIsTheEntryPoint() throws {
        let mixed = try ProductSourcePlan(paths: ["Sources/Entry.swift", "Sources/bridge.c"])
        XCTAssertTrue(mixed.parsesSwiftAsLibrary(type: .executable))
        XCTAssertTrue(mixed.parsesSwiftAsLibrary(type: .dylib))
        XCTAssertTrue(mixed.parsesSwiftAsLibrary(type: .bundle))
        XCTAssertTrue(mixed.parsesSwiftAsLibrary(type: .appex))

        let topLevel = try ProductSourcePlan(paths: ["Sources/main.swift", "Sources/bridge.c"])
        XCTAssertFalse(topLevel.parsesSwiftAsLibrary(type: .executable))

        // Preserved: a pure Swift executable keeps its top-level code.
        let pure = try ProductSourcePlan(paths: ["Sources/main.swift"])
        XCTAssertFalse(pure.parsesSwiftAsLibrary(type: .executable))
    }

    /// A pattern classifies by the extension it spells; one that spells none
    /// answers nil, and the files it expands to are classified one by one.
    func testAPatternClassifiesLikeTheFilesItMatches() {
        XCTAssertEqual(SourceLanguage(path: "Sources/*.mm"), .objcxx)
        XCTAssertEqual(SourceLanguage(path: "Sources/*.C"), .cxx)
        XCTAssertNil(SourceLanguage(path: "Sources/*"))
        XCTAssertNil(SourceLanguage(path: "Sources/**"))
    }
}
