import Foundation

/// What a redirect is refused for.
public enum IlinkRedirectDecision: Sendable, Equatable {
    case follow
    case insecureScheme
    case untrustedHost
    /// A request carrying the bot token tried to leave the host it was sent
    /// to; the credential never follows a redirect.
    case crossHostCredential
    case tooManyRedirects
}

/// Which addresses the token may be sent to.
///
/// The API root is `https://ilinkai.weixin.qq.com`. After a scan the server may
/// move the session to another IDC through `baseurl` or `redirect_host`; those
/// are accepted only when they are HTTPS on the default port and their host is
/// the API root or ends in `.weixin.qq.com`. Anything else is refused, so a
/// reply can never point the token at an arbitrary server.
public struct IlinkTrustPolicy: Sendable, Equatable {
    public static let wechat = IlinkTrustPolicy(
        apiHost: "ilinkai.weixin.qq.com",
        allowedSuffixes: ["weixin.qq.com"]
    )

    public let apiHost: String
    public let allowedSuffixes: [String]

    public init(apiHost: String, allowedSuffixes: [String]) {
        self.apiHost = apiHost.lowercased()
        self.allowedSuffixes = allowedSuffixes.map { $0.lowercased() }
    }

    /// Whether a host may receive a request at all.
    public func isPermittedHost(_ host: String) -> Bool {
        let name = host.lowercased()
        guard !name.isEmpty else { return false }
        // A literal address is never one of ours; it also never matches a
        // suffix, but say so before the suffix walk.
        if name.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" || $0 == "[" || $0 == "]" }) {
            return false
        }
        if name == apiHost { return true }
        return allowedSuffixes.contains { suffix in
            name.hasSuffix("." + suffix)
        }
    }

    /// Whether a URL may be requested: HTTPS, the default port, no user or
    /// password in it, and a permitted host.
    public func permits(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard url.user == nil, url.password == nil else { return false }
        guard url.port == nil || url.port == 443 else { return false }
        guard let host = url.host, isPermittedHost(host) else { return false }
        return true
    }

    /// The base URL a `baseurl` or `redirect_host` reply asks for, or nil when
    /// it is outside the policy. The path is dropped: endpoints are spelled
    /// against the host.
    public func baseURL(from string: String) -> URL? {
        guard let candidate = URL(string: string) else { return nil }
        guard permits(candidate) else { return nil }
        return hostURL(candidate.host ?? "")
    }

    /// `https://<host>` when the host is permitted.
    public func hostURL(_ host: String) -> URL? {
        guard isPermittedHost(host) else { return nil }
        guard let url = URL(string: "https://\(host.lowercased())") else { return nil }
        guard permits(url) else { return nil }
        return url
    }

    /// How one redirect hop is judged. The token never leaves the host it was
    /// sent to, so a credential-bearing request refuses a cross-host hop even
    /// to a permitted host; a body-level IDC move (`baseurl`) is what changes
    /// the host, and that is a decision of its own.
    public func redirectDecision(
        from origin: URL,
        to target: URL,
        carriesCredential: Bool,
        hop: Int,
        maximum: Int
    ) -> IlinkRedirectDecision {
        if hop > maximum { return .tooManyRedirects }
        guard target.scheme?.lowercased() == "https" else { return .insecureScheme }
        guard permits(target) else { return .untrustedHost }
        if carriesCredential, target.host?.lowercased() != origin.host?.lowercased() {
            return .crossHostCredential
        }
        return .follow
    }
}
