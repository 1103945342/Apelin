import ApelinCore
import Foundation
import KWWKAI

/// Kimi's device fingerprint without kwwk's `~/.kwwk/kimi-device-id`, which
/// Apelin never reads or writes (nothing is shared with `~/.kwwk`).
///
/// Kimi binds a grant to the device id it was approved on. kwwk writes that
/// id into the credential as its `deviceId` extra at sign-in and again on
/// every refresh, and a refresh sends the recorded id whatever identity it
/// was given. So the id lives in the credential, in the keychain: a sign-in
/// again reuses the one the stored credential recorded, and a first one
/// makes a new id in kwwk's format. Every identity Apelin hands kwwk names
/// its id, so kwwk never falls back to its own file.
public enum KimiIdentity {
    public static let deviceIDExtra = "deviceId"

    /// The identity a sign-in or a refresh sends: the recorded id, else a
    /// new one. Only local system information is read: kwwk's `.host()`
    /// calls ProcessInfo.hostName, which can block on name resolution.
    public static func identity(recordedIn credentials: OAuthCredentials?) -> KimiDeviceIdentity {
        let deviceID: String
        if case let .string(recorded)? = credentials?.extras[deviceIDExtra], !recorded.isEmpty {
            deviceID = recorded
        } else {
            deviceID = newDeviceID()
        }
        #if os(iOS)
            let system = "iOS"
        #elseif os(macOS)
            let system = "macOS"
        #else
            let system = "unknown"
        #endif
        #if arch(arm64)
            let architecture = "arm64"
        #elseif arch(x86_64)
            let architecture = "x86_64"
        #else
            let architecture = "unknown"
        #endif
        return KimiDeviceIdentity(
            deviceId: deviceID,
            deviceName: PrivateShapes.currentHostName() ?? "Apelin",
            deviceModel: "\(system) \(architecture)",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    /// 32 lowercase hex digits, as kwwk makes its own.
    public static func newDeviceID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Only the selected account's refresher. Constructing every provider
    /// also constructed Kimi's device identity for API keys such as OpenAI.
    /// Devin renews nothing but OAuthManager still needs to know its id.
    public static func refreshers(for providerID: String) -> [any OAuthProvider] {
        if providerID == "devin" {
            return [DevinOAuthProvider()]
        }
        let kimiIdentity = KimiSite.site(id: providerID) == nil ? nil : identity(recordedIn: nil)
        guard let refresher = OAuthSubscriptions.refresher(providerId: providerID, kimiIdentity: kimiIdentity) else {
            return []
        }
        return [refresher]
    }
}
