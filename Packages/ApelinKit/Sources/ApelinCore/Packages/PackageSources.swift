import Foundation

/// The repositories a device already has configured, read from APT's own
/// files, and the two names each one needs: the file name its `Packages`
/// index has under `<install root>/var/lib/apt/lists`, and the URL to fetch a
/// package from. Pure text in, values out, so the rules are testable off a
/// device.
///
/// Both spellings APT accepts are read: one line per repository
/// (`deb [arch=…] URI suite component…`), and the deb822 paragraph
/// (`Types:`, `URIs:`, `Suites:`, `Components:`).
public struct PackageRepository: Hashable, Sendable {
    /// Without a trailing slash: `https://apt.procurs.us`.
    public var uri: String
    public var suite: String
    public var component: String
    public var architecture: String

    public init(uri: String, suite: String, component: String, architecture: String) {
        var trimmed = uri.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.uri = trimmed
        self.suite = suite
        self.component = component
        self.architecture = architecture
    }

    /// The name APT gives this index in `/var/lib/apt/lists`: the URI without
    /// its scheme, its slashes turned into underscores, then the suite, the
    /// component and the architecture.
    public var indexName: String {
        var host = uri
        for scheme in ["https://", "http://", "file:"] where host.hasPrefix(scheme) {
            host.removeFirst(scheme.count)
            break
        }
        while host.hasPrefix("/") { host.removeFirst() }
        let flat = host.replacingOccurrences(of: "/", with: "_")
        return "\(flat)_dists_\(suite)_\(component)_binary-\(architecture)_Packages"
    }

    /// Where the index is fetched from when the device does not have it.
    public var packagesURL: String {
        "\(uri)/dists/\(suite)/\(component)/binary-\(architecture)/Packages"
    }

    /// Where a package the index names is fetched from. APT spells the
    /// `Filename` from the repository root, sometimes with a leading `./`.
    public func url(for filename: String) -> String {
        var path = filename.trimmingCharacters(in: .whitespaces)
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasPrefix("./") { path.removeFirst(2) }
        return "\(uri)/\(path)"
    }
}

public enum PackageSources {
    /// The one-line spelling: `deb [arch=iphoneos-arm64] https://host suite main`.
    /// A line that is not a `deb` line, or is commented out, is skipped.
    public static func parse(list text: String, architecture: String) -> [PackageRepository] {
        var repositories: [PackageRepository] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var words = line.split(separator: " ").map(String.init)
            guard words.first == "deb" else { continue }
            words.removeFirst()
            if let options = words.first, options.hasPrefix("[") {
                words.removeFirst()
                // `[arch=…]` narrows the repository to one architecture;
                // another one's is not this device's repository.
                if let arch = option("arch", in: options), arch != architecture, arch != "all" { continue }
            }
            guard words.count >= 3 else { continue }
            let uri = words[0]
            let suite = words[1]
            for component in words[2...] {
                repositories.append(
                    PackageRepository(uri: uri, suite: suite, component: component, architecture: architecture)
                )
            }
        }
        return repositories
    }

    /// The deb822 spelling, a paragraph at a time.
    public static func parse(deb822 text: String, architecture: String) -> [PackageRepository] {
        var repositories: [PackageRepository] = []
        for stanza in IndexedPackage.stanzas(text) {
            guard let types = stanza["Types"] ?? stanza["Type"], types.contains("deb") else { continue }
            guard let uris = stanza["URIs"], let suites = stanza["Suites"] else { continue }
            let components = (stanza["Components"] ?? "").split(separator: " ").map(String.init)
            guard !components.isEmpty else { continue }
            var architectures = (stanza["Architectures"] ?? "").split(separator: " ").map(String.init)
            if architectures.isEmpty { architectures = [architecture] }
            guard architectures.contains(architecture) || architectures.contains("all") else { continue }
            for uri in uris.split(separator: " ").map(String.init) {
                for suite in suites.split(separator: " ").map(String.init) {
                    for component in components {
                        repositories.append(
                            PackageRepository(uri: uri, suite: suite, component: component, architecture: architecture)
                        )
                    }
                }
            }
        }
        return repositories
    }

    /// `arch=iphoneos-arm64` inside `[…]`, when it is there at all.
    private static func option(_ name: String, in options: String) -> String? {
        let inside = options.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        for part in inside.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0] == name else { continue }
            return pair[1]
        }
        return nil
    }
}
