import Foundation

/// What a call can fail with.
///
/// A failure carries a status, a host or a short reason, never a token, a
/// header value or a request body, so one can be logged or shown as it is.
public enum IlinkFailure: Error, Sendable, Equatable {
    /// A URL outside the trust policy: another scheme, another port, a host
    /// that is not the API root or under `weixin.qq.com`.
    case untrustedURL(URL)
    /// A redirect, or an IDC hop, the policy refused.
    case redirectRefused(to: URL, reason: IlinkRedirectDecision)
    /// The request ran into its read timeout; on `getupdates` that is an
    /// ordinary empty round.
    case timedOut
    /// The server answered outside 200..<300.
    case http(status: Int)
    /// `ret != 0` — the only field that marks a `getupdates` round as failed;
    /// `errcode` in a normal reply may be non-zero.
    case rejected(ret: Int, errcode: Int?, message: String?)
    /// A reply this protocol cannot read.
    case invalidResponse(String)
    /// The transport failed without a status.
    case transport(String)
    case notLoggedIn
    case credentialExpired
    /// The session file is there and does not read. It is left as it is;
    /// only `IlinkClient.discardSession()` may clear it.
    case sessionUnreadable(path: String, reason: String)
    case sessionUnwritable(path: String)
    /// The login ended before a credential arrived.
    case loginEnded(IlinkLoginEnd)
    /// `getupdates` failed this many rounds in a row; polling stopped.
    case tooManyFailures(attempts: Int)
    case cancelled

    /// A line for a log: no URL, no query, no token.
    public var summary: String {
        switch self {
        case .untrustedURL:
            return "untrusted-url"
        case .redirectRefused:
            return "redirect-refused"
        case .timedOut:
            return "timeout"
        case .http(let status):
            return "http-\(status)"
        case .rejected(let ret, _, _):
            return "rejected-ret-\(ret)"
        case .invalidResponse(let what):
            return "invalid-\(what)"
        case .transport:
            return "transport"
        case .notLoggedIn:
            return "not-logged-in"
        case .credentialExpired:
            return "credential-expired"
        case .sessionUnreadable:
            return "session-unreadable"
        case .sessionUnwritable:
            return "session-unwritable"
        case .loginEnded(let end):
            return "login-ended-\(end.summary)"
        case .tooManyFailures(let attempts):
            return "too-many-failures-\(attempts)"
        case .cancelled:
            return "cancelled"
        }
    }
}
