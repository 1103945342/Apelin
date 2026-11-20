// swift-tools-version:5.9
//
// The agent-tool-extension protocol: both ends of it, and nothing else.
//
// - LurosToolCore: the frames, the manifest and its validation, the
//   attachment channel. Imported by both sides.
// - LurosToolHost: `ToolHostClient`, which spawns one extension process and
//   talks to it. The session host links this.
// - LurosToolExtension: `ToolExtensionServer`, which an extension executable
//   links to implement its tools.
//
// System libraries only: the session host links this, and nothing
// third-party links into the host side.

import PackageDescription

let package = Package(
    name: "LurosToolHost",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "LurosToolCore", targets: ["LurosToolCore"]),
        .library(name: "LurosToolHost", targets: ["LurosToolHost"]),
        .library(name: "LurosToolExtension", targets: ["LurosToolExtension"]),
    ],
    targets: [
        .target(name: "LurosToolCore"),
        .target(name: "LurosToolHost", dependencies: ["LurosToolCore"]),
        .target(name: "LurosToolExtension", dependencies: ["LurosToolCore"]),
        // A test double: an extension that misbehaves on request. Built for
        // the tests only; no product names it.
        .executableTarget(name: "FakeToolExtension", dependencies: ["LurosToolExtension"]),
        .testTarget(
            name: "LurosToolHostTests",
            dependencies: ["LurosToolHost", "LurosToolExtension", "FakeToolExtension"],
        ),
    ],
)
