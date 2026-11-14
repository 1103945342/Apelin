import Foundation

/// The QR code a login starts with. `id` is the `qrcode` value the status call
/// asks about; `content` is what the server wants shown or shared.
public struct IlinkLoginQRCode: Sendable, Equatable {
    public let id: String
    public let content: String
    public let imageURL: URL?
    public let expiresAt: Date

    public init(id: String, content: String, imageURL: URL?, expiresAt: Date) {
        self.id = id
        self.content = content
        self.imageURL = imageURL
        self.expiresAt = expiresAt
    }
}

/// The IDC a scan moved the session to (`scaned_but_redirect`). The client has
/// already checked it against the trust policy and switched its base URL.
public struct IlinkIDCTarget: Sendable, Equatable {
    public let host: String

    public init(host: String) {
        self.host = host
    }
}

/// Why a login ended without a credential.
public enum IlinkLoginEnd: Sendable, Equatable {
    case cancelled
    /// The local QR lifetime ran out, or the three codes were used up.
    case qrExpired
    /// `verify_code_blocked`: the server refuses further codes.
    case verificationBlocked
    /// No code was entered within the local window.
    case verificationTimedOut
    /// `binded_redirect`: this WeChat account is bound to another channel.
    case boundToAnotherChannel
    /// A newer `beginLogin`, or `cancelLogin`, replaced this attempt.
    case superseded

    public var summary: String {
        switch self {
        case .cancelled:
            return "cancelled"
        case .qrExpired:
            return "qr-expired"
        case .verificationBlocked:
            return "verification-blocked"
        case .verificationTimedOut:
            return "verification-timed-out"
        case .boundToAnotherChannel:
            return "bound-to-another-channel"
        case .superseded:
            return "superseded"
        }
    }
}

/// One answer of `get_qrcode_status`.
public enum IlinkLoginStatus: Sendable, Equatable {
    /// `wait`, and any status this version does not know: poll again.
    case pending
    /// `scaned`.
    case scanned
    /// `need_verifycode`: the number shown on the phone is needed. `retry` is
    /// true when the previous number was refused.
    case needsVerification(retry: Bool)
    /// `scaned_but_redirect`: the client moved to this IDC; poll again.
    case redirecting(IlinkIDCTarget)
    /// `confirmed`: the credential, already in memory and in the session file.
    case confirmed(IlinkCredentials)
    /// `expired`: a replacement code was fetched, unless the login is over.
    case expired(newCode: IlinkLoginQRCode)
    /// The login is over; `pollLogin` throws this as `IlinkFailure.loginEnded`.
    case ended(IlinkLoginEnd)
}
