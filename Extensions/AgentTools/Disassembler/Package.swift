// swift-tools-version:6.2
//
// Two agent-tool extensions from one source tree, shipped as two packages:
//
// - luros-disassembler (com.fluoxetine.luros.agent-tools.disassembler):
//   Capstone (BSD-3-Clause) and MachOReader (MIT). `disassemble`, `symbols`.
// - luros-assembler (com.fluoxetine.luros.agent-tools.assembler): Keystone
//   (GPL-2.0). `assemble`. Nothing else links Keystone, so the disassembler
//   package carries no GPL code.
//
// 6.2 because libcapstone-spm declares it.

import PackageDescription

let package = Package(
    name: "ApelinAgentToolsDisassembler",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .executable(name: "luros-disassembler", targets: ["luros-disassembler"]),
        .executable(name: "luros-assembler", targets: ["luros-assembler"]),
    ],
    dependencies: [
        .package(path: "../../../Packages/ApelinToolHost"),
        .package(url: "https://github.com/Lakr233/libcapstone-spm.git", exact: "0.1.3"),
        // Tag 0.1.2, pinned by revision: CoreKeystone carries `unsafeFlags`,
        // which SwiftPM refuses in a dependency required by version.
        .package(url: "https://github.com/Lakr233/libkeystone-spm.git", revision: "3ff184008e1ba49577b944579cd32d32c78451b5"),
    ],
    targets: [
        .target(name: "MachOReader"),
        .target(
            name: "DisassemblerTools",
            dependencies: [
                "MachOReader",
                .product(name: "Capstone", package: "libcapstone-spm"),
                .product(name: "ApelinToolExtension", package: "ApelinToolHost"),
            ],
        ),
        .executableTarget(name: "luros-disassembler", dependencies: ["DisassemblerTools"]),
        .target(
            name: "AssemblerTools",
            dependencies: [
                .product(name: "Keystone", package: "libkeystone-spm"),
                .product(name: "ApelinToolExtension", package: "ApelinToolHost"),
            ],
        ),
        .executableTarget(name: "luros-assembler", dependencies: ["AssemblerTools"]),
        .testTarget(
            name: "DisassemblerTests",
            dependencies: [
                "MachOReader",
                "luros-disassembler",
                "luros-assembler",
                .product(name: "ApelinToolHost", package: "ApelinToolHost"),
            ],
        ),
    ],
    swiftLanguageModes: [.v5],
)
