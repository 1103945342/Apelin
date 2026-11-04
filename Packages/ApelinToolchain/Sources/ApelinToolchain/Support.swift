import Darwin
import Foundation

/// The reviewed host requirements of one Swift compiler release.
public struct SwiftToolchainSupport: Codable, Sendable, Equatable {
    public let version: String
    public let minimumHost: String
    public let cpuFeatures: [String]
    public let minimumHostBasis: String
    public let verifiedHosts: [String]

    private enum CodingKeys: String, CodingKey {
        case version, minimumHost, cpuFeatures, minimumHostBasis, verifiedHosts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        minimumHost = try values.decode(String.self, forKey: .minimumHost)
        cpuFeatures = try values.decode([String].self, forKey: .cpuFeatures)
        minimumHostBasis = try values.decodeIfPresent(String.self, forKey: .minimumHostBasis) ?? "verified-policy"
        verifiedHosts = try values.decodeIfPresent([String].self, forKey: .verifiedHosts) ?? []
    }

    public init(
        version: String,
        minimumHost: String,
        cpuFeatures: [String],
        minimumHostBasis: String = "verified-policy",
        verifiedHosts: [String] = [],
    ) {
        self.version = version
        self.minimumHost = minimumHost
        self.cpuFeatures = cpuFeatures
        self.minimumHostBasis = minimumHostBasis
        self.verifiedHosts = verifiedHosts
    }

    public func refusal(hostVersion: String, hasFeature: (String) -> Bool) -> String? {
        if hostVersion.compare(minimumHost, options: .numeric) == .orderedAscending {
            return minimumHostBasis == "verified-policy"
                ? "Swift \(version) is supported on iOS \(minimumHost) or later; earlier hosts have not been verified."
                : "Swift \(version) requires iOS \(minimumHost) or later on this device."
        }
        let missing = cpuFeatures.filter { !hasFeature($0) }
        return missing.isEmpty ? nil : "Swift \(version) requires CPU features this device lacks: " + missing
            .joined(separator: ", ") + "."
    }

    public var hostRefusal: String? {
        #if os(iOS)
            return refusal(hostVersion: hostOSVersion, hasFeature: hostHasCPUFeature)
        #else
            return nil
        #endif
    }
}

/// One Command Line Tools release the retarget was reviewed against: its package
/// layout, what its tools load, and the SDKs its linker reads. A release is listed
/// here only after its setup and the C, C++ and Objective-C self-test passed on a
/// device; every other version is refused with the reason `refusal(for:)` gives.
public struct CommandLineToolsRelease: Sendable, Equatable {
    /// The CLT version as Apple's catalog names it, `16.4`.
    public let version: String
    /// The iPhoneOS SDK the matching Xcode shipped with, `18.5`. The release's
    /// linker and headers read that SDK and older ones; a newer SDK can use a
    /// text-stub architecture (`arm64e.x1`) or headers its tools do not know.
    /// A major alone (`27`) takes that major's point releases too, once one
    /// passed the self-test.
    public let newestSDK: String
    /// macOS system libraries the tools load that iOS does not have, each
    /// loaded weakly. Only a path Apelin never takes calls into them; see
    /// `CommandLineToolsSupport.weakSystemLibraryReasons`.
    public let weakSystemLibraries: Set<String>
    /// Whether its Swift tools were reviewed and passed the Swift self-test.
    public let swiftSupport: SwiftToolchainSupport?
    /// Why a release that ships Swift does not offer it, in a sentence a
    /// user reads; nil when it offers Swift or nobody has looked yet.
    public let swiftUnavailable: String?
    public var swift: Bool {
        swiftSupport != nil
    }

    /// Imports its Swift tools make that iOS does not export, each bound to the
    /// symbol that answers instead; empty for most releases.
    let swiftImportRenames: [String: String]
    public let clangModuleCPUFeatures: [String]
    public let recommendedSDK: String
    public let verifiedSDKs: [String]
    /// The SDKs its Swift self-test passed against; none without Swift.
    let verifiedSwiftSDKs: [String]
    public let sources: [String: String]
    public var sourceProductIDs: [String] {
        sources.keys.sorted()
    }

    public let staticInstructionFeatures: [String]
    public let requiredLibcxxSymbols: [String]
    public var systemSymbolSDK: String?
    public var systemSymbolCount: Int?

    public init(
        version: String,
        newestSDK: String,
        weakSystemLibraries: Set<String> = [],
        swift: SwiftToolchainSupport? = nil,
        swiftUnavailable: String? = nil,
        swiftImportRenames: [String: String] = [:],
        clangModuleCPUFeatures: [String] = ["FEAT_SHA3"],
        recommendedSDK: String? = nil,
        verifiedSDKs: [String] = [],
        verifiedSwiftSDKs: [String]? = nil,
        sources: [String: String] = [:],
        staticInstructionFeatures: [String] = [],
        requiredLibcxxSymbols: [String] = [],
        systemSymbolSDK: String? = nil,
        systemSymbolCount: Int? = nil,
    ) {
        self.version = version
        self.newestSDK = newestSDK
        self.weakSystemLibraries = weakSystemLibraries
        swiftSupport = swift
        self.swiftUnavailable = swiftUnavailable
        self.swiftImportRenames = swiftImportRenames
        self.clangModuleCPUFeatures = clangModuleCPUFeatures
        self.recommendedSDK = recommendedSDK ?? newestSDK
        self.verifiedSDKs = verifiedSDKs
        self.verifiedSwiftSDKs = swift == nil ? [] : verifiedSwiftSDKs ?? [self.recommendedSDK]
        self.sources = sources
        self.staticInstructionFeatures = staticInstructionFeatures
        self.requiredLibcxxSymbols = requiredLibcxxSymbols
        self.systemSymbolSDK = systemSymbolSDK
        self.systemSymbolCount = systemSymbolCount
    }

    /// Whether the release's tools read an SDK of this version: its major.minor
    /// is no newer than `newestSDK`'s, or its major no newer than a major
    /// alone.
    public func reads(sdkVersion: String) -> Bool {
        let sdk = CommandLineToolsSupport.majorMinor(sdkVersion)
        guard newestSDK.contains(".") else { return sdk[0] <= CommandLineToolsSupport.majorMinor(newestSDK)[0] }
        let newest = CommandLineToolsSupport.majorMinor(newestSDK)
        return sdk == newest || sdk.lexicographicallyPrecedes(newest)
    }
}

public enum CommandLineToolsSupport {
    static let libxar = "/usr/lib/libxar.1.dylib"
    static let libcodedirectory = "/usr/lib/libcodedirectory.dylib"

    /// Why a library may be loaded weakly: what in the tools calls it, and why
    /// Apelin never asks for that.
    public static let weakSystemLibraryReasons: [String: String] = [
        libxar: "ld64 reads and writes bitcode bundles with libxar; Apelin never embeds or links bitcode",
        libcodedirectory: "ld writes a linker ad-hoc signature with libcodedirectory, which it does for macOS "
            + "and simulator outputs or when asked with -adhoc_codesign; Apelin links for iOS devices, never asks, "
            + "and signs with ApelinCodeSign",
    ]

    /// Imports the Swift tools make that iOS's Swift runtime does not export,
    /// each bound instead to the iOS symbol that answers the same question.
    ///
    /// `_stdlib_isOSVersionAtLeastOrVariantVersion(major, minor, patch, variant…)`
    /// is macOS's zippered `#available` check: a macOS process compares the
    /// first triple, a macOS version, against the running system. iOS exports
    /// `_stdlib_isOSVersionAtLeast(major, minor, patch)`; called with the same
    /// registers it reads the first three and compares that triple against
    /// the running iOS. From iOS 26 the numbering is shared (macOS 26.x is
    /// iOS 26.x), and every macOS version before 26 is older than any iOS 26
    /// on both scales, so the answer is the same for every argument on an
    /// iOS 26 or later host. Only CLT 27.0 uses this rename.
    public static let swiftImportRenames: [String: String] = [
        "_$ss042_stdlib_isOSVersionAtLeastOrVariantVersiondE0yBi1_Bw_BwBwBwBwBwtF":
            "_$ss26_stdlib_isOSVersionAtLeastyBi1_Bw_BwBwtF",
    ]

    /// The reviewed releases, newest first.
    /// See `Documents/Research/2026-10-17-Toolchain-Retarget.md` ▸ Other releases.
    public static let releases: [CommandLineToolsRelease] = [
        .init(
            version: "27.0",
            newestSDK: "27",
            swift: .init(
                version: "6.4",
                minimumHost: "26.0",
                cpuFeatures: ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"],
                minimumHostBasis: "runtime-semantics",
                verifiedHosts: ["26.6.2", "27.0.1"],
            ),
            swiftImportRenames: swiftImportRenames,
            recommendedSDK: "27.0",
            verifiedSDKs: ["18.6", "26.0", "26.1", "26.2", "26.4", "26.5", "27.0", "27.1"],
            verifiedSwiftSDKs: ["27.0", "27.1"],
            sources: ["082-83364": "d1a517e663d7ba169296683255bcf5b498802b843603cee40ec4b6fb7c991bea"],
            staticInstructionFeatures: ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"],
            requiredLibcxxSymbols: ["_ZNSt3__122__libcpp_verbose_abortEPKcz"],
        ),
        .init(
            version: "16.4",
            newestSDK: "18.5",
            // Its swift-driver (Swift 6.1.2) and two SwiftSyntax libraries import macOS's
            // zippered availability check; iOS's runtime has no such symbol, so dyld stops
            // swiftc on iOS 17.3.1 (iPhone 15 Pro, 2026-10-21). The rename 27.0 uses is right
            // only from iOS 26, and swift-frontend carries 3,754 udot (DotProd) and 5 eor3.
            swiftUnavailable: "Swift 6.1.2 from Command Line Tools 16.4 is not offered: it would need iOS 26 or later "
                + "and an A13 or later CPU, where Command Line Tools 27.0's Swift 6.4 already runs, and it has not been "
                + "verified on such a device.",
            verifiedSDKs: ["18.4", "18.5"],
            sources: ["082-41241": "43c15c1f952c7a4c1a8f67c6b46350b83e217c610d7d3c14aa09e88bb251a4b6"],
            staticInstructionFeatures: ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"],
            requiredLibcxxSymbols: ["_ZNSt3__122__libcpp_verbose_abortEPKcz"],
        ),
        .init(
            version: "15.3",
            newestSDK: "17.4",
            weakSystemLibraries: [libcodedirectory],
            // swift-frontend's only SHA3 code is BLAKE3's hash_many (compile caching) and the
            // symbol-graph edge set (-emit-symbol-graph), neither on Apelin's build path; on an
            // A12Z (no SHA3) every Swift case, macros included, passed (2026-10-21).
            swift: .init(
                version: "5.10",
                minimumHost: "17.3.1",
                cpuFeatures: ["FEAT_LRCPC"],
                verifiedHosts: ["17.3.1", "26.0.1"],
            ),
            verifiedSDKs: ["17.2", "17.4"],
            sources: ["052-59890": "3812e6cce85d90f2a142440628a56ececd90d7fcb2ebfb35cc2faee3d81bd6ab"],
            staticInstructionFeatures: ["FEAT_LRCPC", "FEAT_SHA3"],
            systemSymbolSDK: "16.1",
            systemSymbolCount: 1667,
        ),
        .init(
            version: "15.0",
            newestSDK: "17.0",
            weakSystemLibraries: [libcodedirectory],
            // swift-frontend's only SHA3 code is BLAKE3's hash_many (compile caching) and the
            // symbol-graph edge set (-emit-symbol-graph), neither on Apelin's build path; on an
            // A12Z (no SHA3) every Swift case, macros included, passed (2026-10-21).
            swift: .init(
                version: "5.9",
                minimumHost: "17.3.1",
                cpuFeatures: ["FEAT_LRCPC"],
                verifiedHosts: ["17.3.1", "26.0.1", "26.6.2", "27.0.1"],
            ),
            verifiedSDKs: ["17.0"],
            sources: ["042-32697": "a5ec585bf89ce2e43aca1583b8a315b88725d53bc66dd0f2ba3fcf4580ec7b8f"],
            staticInstructionFeatures: ["FEAT_LRCPC", "FEAT_SHA3"],
            systemSymbolSDK: "16.1",
            systemSymbolCount: 1682,
        ),
        .init(
            version: "14.2",
            newestSDK: "16.2",
            weakSystemLibraries: [libxar],
            swift: .init(
                version: "5.7.2",
                minimumHost: "17.3.1",
                cpuFeatures: ["FEAT_LRCPC"],
                verifiedHosts: ["17.3.1", "26.0.1", "26.6.2", "27.0.1"],
            ),
            clangModuleCPUFeatures: [],
            verifiedSDKs: ["16.1", "16.2"],
            sources: ["012-92431": "81c4ed35ac9a2dcce106c9d26696653ceb9337b949206802886e25d13f9b3f1a"],
            staticInstructionFeatures: ["FEAT_LRCPC"],
            systemSymbolSDK: "16.1",
            systemSymbolCount: 949,
        ),
    ]

    /// Releases looked at and refused, with the reason a user reads.
    static let refused: [String: String] = [
        "12.4": "C++ programs it builds for arm64e stop on iOS as soon as they print output",
    ].merging(retired.map { ($0, retiredReason) }) { first, _ in first }

    /// Releases that passed on a device and were dropped (owner, 2026-10-21):
    /// every SDK each one reads, a kept release reads too, and 14.2 keeps
    /// Swift for A12 CPUs. Apple's catalog still lists them.
    static let retired = ["16.2", "14.3", "13.4", "13.2", "12.5"]
    static let retiredReason = "it is retired because a newer supported release works with all of its SDKs"

    /// The version a catalog package gets when its metadata names none.
    static let unknownVersion = "unknown"

    public static func release(_ version: String) -> CommandLineToolsRelease? {
        releases.first { $0.version == version }
    }

    /// Nil for a reviewed release; otherwise one sentence a user reads, naming
    /// the version and why setup does not take it.
    public static func refusal(for version: String, productID: String? = nil) -> String? {
        if let release = release(version) {
            if let productID, !release.sourceProductIDs.contains(productID) {
                return "Command Line Tools \(version) product \(productID) has not been reviewed; its binaries may differ from the supported release."
            }
            return nil
        }
        let supported = releases.map(\.version).joined(separator: ", ")
        if let reason = refused[version] {
            return "Command Line Tools \(version) cannot be set up: \(reason). Pick one of \(supported)."
        }
        if version == unknownVersion {
            return "This Command Line Tools package does not say which version it is, so Apelin cannot set it up. "
                + "Pick one of \(supported)."
        }
        return "Command Line Tools \(version) has not been tested on iOS, so Apelin does not set it up yet. "
            + "Pick one of \(supported)."
    }

    static func majorMinor(_ version: String) -> [Int] {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        return [parts.first ?? 0, parts.count > 1 ? parts[1] : 0]
    }
}
