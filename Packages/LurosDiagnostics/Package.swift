// swift-tools-version: 5.10
import PackageDescription

/// Luros's diagnostics: what the mobile worker does through icli, what the
/// root log helper does with system libraries alone, crash symbolication and
/// blame, and the three-way "is the tweak loaded" check.
///
/// Everything except the IcliKit link builds and tests on a Mac with
/// `swift test`. IcliKit is an on-device library with no macOS platform, so it
/// is linked for iOS only and `IcliKitSurface` compiles to nothing elsewhere;
/// the tests drive `Diagnostics` through a fake `IcliSurface`.
let package = Package(
    name: "LurosDiagnostics",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // The mobile diagnostics worker: logs, crash reports, screenshot, UI
        // tree and actions, foreground app, running apps, respring fallback.
        .library(name: "LurosDiagnostics", targets: ["LurosDiagnosticsCore", "LurosDiagnostics"]),
        // The root log helper's core. System libraries only: no icli, nothing
        // third-party, so the root helper links nothing it does not need.
        .library(name: "LurosLogReader", targets: ["LurosDiagnosticsCore", "LurosLogReaderSPI", "LurosLogReader"]),
        // Crash parsing, symbolication from the project's dSYM, and blame.
        .library(name: "LurosCrash", targets: ["LurosCrashReport", "LurosCrashSymbols", "LurosCrashBlame"]),
        // Marker line and filter plist, each answered apart.
        .library(name: "ConfirmLoaded", targets: ["LurosDiagnosticsCore", "ConfirmLoaded"]),
        // What Workers/Diagnostics/main.swift calls: every product above
        // served over the worker channel.
        .library(name: "LurosDiagnosticsWorker", targets: ["LurosDiagnosticsWorker"]),
        // What Workers/LogReader/main.swift calls. System code only, like
        // everything luros-log-reader links: LurosLogReader, LurosCore,
        // LurosProtocol. `Scripts/check-system-only.py` holds it to that.
        .library(name: "LurosLogReaderWorker", targets: ["LurosLogReaderWorker"]),
    ],
    dependencies: [
        // owngoal-dev/icli, MIT. Any 1.x release; Package.resolved records the
        // reviewed version.
        .package(url: "https://github.com/owngoal-dev/icli.git", from: "1.0.0"),
        // Luros's own wire and worker channel. System code only.
        .package(path: "../LurosKit"),
    ],
    targets: [
        // Request and result types every product shares. Foundation only.
        .target(name: "LurosDiagnosticsCore"),

        .target(
            name: "LurosDiagnostics",
            dependencies: [
                "LurosDiagnosticsCore",
                .product(name: "IcliKit", package: "icli", condition: .when(platforms: [.iOS])),
            ],
        ),

        // LoggingSupport's live stream, driven from Objective-C. Foundation
        // and libobjc; the framework itself is opened at run time.
        .target(
            name: "LurosLogReaderSPI",
            linkerSettings: [.linkedFramework("Foundation")],
        ),
        .target(name: "LurosLogReader", dependencies: ["LurosDiagnosticsCore", "LurosLogReaderSPI"]),

        // Ported from Xrash (MIT); each folder keeps the upstream LICENSE.
        .target(name: "LurosCrashReport", exclude: ["LICENSE"]),
        .target(name: "LurosCrashSymbols", dependencies: ["LurosCrashReport"], exclude: ["LICENSE"]),
        .target(name: "LurosCrashBlame", dependencies: ["LurosCrashReport"], exclude: ["LICENSE"]),

        .target(name: "ConfirmLoaded", dependencies: ["LurosDiagnosticsCore"]),

        // luros-diagnostics (mobile): logStream, crashList, crashSymbolicate,
        // confirmLoaded, captureScreen, readUITree, uiAction.
        .target(
            name: "LurosDiagnosticsWorker",
            dependencies: [
                "LurosDiagnostics", "LurosCrashReport", "LurosCrashSymbols", "LurosCrashBlame", "ConfirmLoaded",
                // The stream pump both log workers share.
                "LurosLogReaderWorker",
                .product(name: "LurosCore", package: "LurosKit"),
                .product(name: "LurosProtocol", package: "LurosKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ConciseMagicFile")],
        ),
        // luros-log-reader (root): logStream through the root live stream.
        .target(
            name: "LurosLogReaderWorker",
            dependencies: [
                "LurosLogReader",
                .product(name: "LurosCore", package: "LurosKit"),
                .product(name: "LurosProtocol", package: "LurosKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ConciseMagicFile")],
        ),

        .testTarget(
            name: "LurosDiagnosticsTests",
            dependencies: ["LurosDiagnostics"],
            resources: [.copy("Fixtures")],
        ),
        .testTarget(name: "LurosLogReaderTests", dependencies: ["LurosLogReader"]),
        .testTarget(
            name: "LurosCrashReportTests",
            dependencies: ["LurosCrashReport"],
            exclude: ["LICENSE"],
            resources: [.copy("Fixtures")],
        ),
        .testTarget(
            name: "LurosCrashSymbolsTests",
            dependencies: ["LurosCrashSymbols", "LurosCrashBlame"],
            exclude: ["LICENSE"],
            resources: [.copy("Fixtures")],
        ),
        .testTarget(name: "LurosCrashBlameTests", dependencies: ["LurosCrashBlame"], exclude: ["LICENSE"]),
        .testTarget(name: "ConfirmLoadedTests", dependencies: ["ConfirmLoaded"]),
        .testTarget(
            name: "LurosDiagnosticsWorkerTests",
            dependencies: [
                "LurosDiagnosticsWorker", "LurosLogReaderWorker", "LurosDiagnostics", "ConfirmLoaded",
                .product(name: "LurosCore", package: "LurosKit"),
                .product(name: "LurosProtocol", package: "LurosKit"),
            ],
        ),
    ],
)
