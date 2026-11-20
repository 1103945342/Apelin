// swift-tools-version: 5.9
//
// Luros's own shared code, linked into the app, lurosd and the workers by
// Luros.xcodeproj and tested on the Mac with `swift test` (`make harness`).
//
// Which binary links what is decided in the xcodeproj and written down in
// AGENTS.md ▸ Decisions ▸ Process layout. The rule this manifest carries:
// LurosCore and LurosProtocol link into the root processes (lurosd, its
// session host and luros-log-reader), so they depend on nothing but the
// system — no package dependency, ever. `make harness` checks it. A
// third-party library is added to the one target that needs it, which links
// only into a mobile worker.
//
// The third-party code here is reached only by luros-environment: libgit2
// (GitKit) for the git service and SDK fetching, libarchive (ArchiveKit, the
// pin LurosFormats uses) for SDK archives, and LurosFormats for Mach-O type
// checks and the local toolchain deb. Licenses/review.json records each one.

import PackageDescription

/// `#file` is `Module/File.swift`, never the build machine's path: the
/// packager greps every shipped binary for the repository root. Package
/// targets do not inherit Configuration/Base.xcconfig, so it is set here.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ConciseMagicFile"),
]

let package = Package(
    name: "LurosKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LurosCore", targets: ["LurosCore"]),
        .library(name: "LurosProtocol", targets: ["LurosProtocol"]),
        .library(name: "LurosEnvironment", targets: ["LurosEnvironment"]),
        .library(name: "LurosBuild", targets: ["LurosBuild"]),
        .library(name: "LurosProject", targets: ["LurosProject"]),
        .library(name: "LurosGit", targets: ["LurosGit"]),
        .library(name: "LurosConsole", targets: ["LurosConsole"]),
        .library(name: "LurosReplay", targets: ["LurosReplay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libgit2.xcframework.git", from: "1.0.0"),
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", from: "1.0.0"),
        // Mach-O reading, signing and the .deb writer (luros-build), the
        // .deb reader and writer (luros-environment).
        .package(path: "../LurosFormats"),
        // The device-side Command Line Tools download, retarget and
        // self-test (luros-environment's RetargetToolchainBackend).
        .package(path: "../LurosToolchain"),
    ],
    targets: [
        // System only: paths, the data folder, project naming, JSON.
        .target(name: "LurosCore", swiftSettings: swiftSettings),
        // System only: the wire, the task model, the worker channel and the
        // typed LurosService facade.
        .target(name: "LurosProtocol", dependencies: ["LurosCore"], swiftSettings: swiftSettings),
        // luros-environment: the toolchain registry and setup, the SDK
        // manager, the project-scoped git service, transfer files, and the
        // worker's handler.
        .target(
            name: "LurosEnvironment",
            dependencies: [
                // LurosProject: a project transfer file's description,
                // read strictly and given a new project ID on import.
                "LurosCore", "LurosProtocol", "LurosGit", "LurosProject",
                .product(name: "ArchiveKit", package: "libarchive.xcframework"),
                .product(name: "LurosMachO", package: "LurosFormats"),
                .product(name: "LurosDebian", package: "LurosFormats"),
                .product(name: "LurosDebArchive", package: "LurosFormats"),
                .product(name: "LurosToolchain", package: "LurosToolchain"),
            ],
            swiftSettings: swiftSettings,
        ),
        // luros-build: compile, link, lipo, dSYM, strip, sign, package.
        .target(
            name: "LurosBuild",
            dependencies: [
                "LurosCore", "LurosProtocol", "LurosProject",
                .product(name: "LurosMachO", package: "LurosFormats"),
                .product(name: "LurosCodeSign", package: "LurosFormats"),
                .product(name: "LurosDebian", package: "LurosFormats"),
                .product(name: "LurosDebArchive", package: "LurosFormats"),
            ],
            swiftSettings: swiftSettings,
        ),
        // luros-project.json, extension manifests, templates, project checks.
        .target(name: "LurosProject", dependencies: ["LurosCore", "LurosProtocol"], swiftSettings: swiftSettings),
        // libgit2 behind typed calls: a shallow clone of one branch, status,
        // diff, stage, unstage, a local commit. No libgit2 type is public.
        .target(
            name: "LurosGit",
            dependencies: [
                "LurosCore",
                "LurosGitOptions",
                .product(name: "GitKit", package: "libgit2.xcframework"),
            ],
            swiftSettings: swiftSettings,
        ),
        // libgit2's variadic option call, which Swift cannot make: two C
        // functions, for LurosGit alone.
        .target(name: "LurosGitOptions"),

        // Never shipped: the real EnvironmentWorker with a fake toolchain
        // backend, spawned by the session host's end-to-end toolchain test
        // (Tests/SessionHost, `make harness`), and the fake irisind's unpacker.
        .executableTarget(
            name: "luros-environment-harness",
            dependencies: [
                "LurosCore", "LurosProtocol", "LurosEnvironment",
                .product(name: "LurosDebArchive", package: "LurosFormats"),
            ],
            path: "Tests/EnvironmentHarness",
            swiftSettings: swiftSettings,
        ),

        // The app's console: scripts, `${…}`, expect, follow, the inbox and
        // resuming a run after the app went away. Parameterised on an
        // LurosService, a DataFolder and a log sink; the app binds them.
        .target(name: "LurosConsole", dependencies: ["LurosCore", "LurosProtocol"], swiftSettings: swiftSettings),

        // An LurosTransport that answers from event streams captured on a
        // device (Fixtures/, written by Documents/Console/demo/
        // make-replay-fixtures.py), for working on the UI where no lurosd
        // runs. Never linked into lurosd or a worker.
        .target(
            name: "LurosReplay",
            dependencies: ["LurosCore", "LurosProtocol"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings,
        ),

        .testTarget(name: "LurosCoreTests", dependencies: ["LurosCore"]),
        .testTarget(name: "LurosProtocolTests", dependencies: ["LurosProtocol"]),
        .testTarget(
            name: "LurosEnvironmentTests",
            dependencies: [
                "LurosEnvironment", "LurosGit", "LurosProject", "LurosProtocol",
                .product(name: "ArchiveKit", package: "libarchive.xcframework"),
                .product(name: "LurosDebArchive", package: "LurosFormats"),
                .product(name: "LurosDebian", package: "LurosFormats"),
            ],
        ),
        .testTarget(name: "LurosBuildTests", dependencies: [
            "LurosBuild", "LurosProject",
            .product(name: "LurosMachO", package: "LurosFormats"),
            .product(name: "LurosDebArchive", package: "LurosFormats"),
        ]),
        .testTarget(name: "LurosProjectTests", dependencies: ["LurosProject"]),
        .testTarget(name: "LurosGitTests", dependencies: ["LurosGit"]),
        .testTarget(name: "LurosConsoleTests", dependencies: ["LurosConsole", "LurosCore", "LurosProtocol"]),
        .testTarget(name: "LurosReplayTests", dependencies: ["LurosReplay", "LurosCore", "LurosProtocol"]),
    ],
    swiftLanguageVersions: [.v5],
)
