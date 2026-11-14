// swift-tools-version: 6.0
import PackageDescription

/// The iLink bot protocol (WeChat ClawBot) with no app around it: QR login,
/// the long-polled `getupdates` stream, text `sendmessage`, and a session file
/// that carries the credentials, the cursor and each peer's `context_token`.
///
/// Foundation and URLSession only — no Node, no onebots at run time. The
/// transport is a protocol so the checks drive the protocol without a network,
/// and so another process can put its own HTTP in front of it.
///
/// Nothing here knows Apelin's install root, the app or a worker; the package
/// builds and tests on a Mac with plain `swift test`, and `Scripts/test-wechat.sh`
/// compiles the same checks on the device.
let package = Package(
    name: "ApelinWeChat",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ApelinWeChat", targets: ["ApelinWeChat"]),
    ],
    targets: [
        .target(name: "ApelinWeChat"),
        .testTarget(name: "ApelinWeChatTests", dependencies: ["ApelinWeChat"]),
    ],
    swiftLanguageModes: [.v6],
)
