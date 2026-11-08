import ApelinAgent
import Foundation
import KWWKAI
import Testing

@Suite("Provider startup identities")
struct ProviderStartupTests {
    @Test(arguments: [
        "openai-api-key", "google-api-key", CredentialProviderID.anthropicAPIKey,
        CredentialProviderID.openAICompatible, CredentialProviderID.deepSeek,
        OpenCodePlan.go.id, OpenCodePlan.zen.id,
    ])
    func `API keys construct no OAuth refreshers`(providerID: String) {
        #expect(KimiIdentity.refreshers(for: providerID).isEmpty)
    }

    @Test(arguments: Array(OAuthSubscriptions.refreshedIds).sorted() + ["devin"])
    func `a session constructs only the selected account's refresher`(providerID: String) {
        #expect(KimiIdentity.refreshers(for: providerID).map(\.id) == [providerID])
    }

    @Test
    func `a local Kimi identity includes device metadata`() {
        let identity = KimiIdentity.identity(recordedIn: nil)
        #expect(identity.deviceId.count == 32)
        #expect(identity.deviceId.allSatisfy(\.isHexDigit))
        #expect(!identity.deviceName.isEmpty)
        #expect(!identity.deviceModel.isEmpty)
        #expect(!identity.osVersion.isEmpty)
    }

    @Test
    func `a recorded Kimi device id survives local identity construction`() {
        let id = "0123456789abcdef0123456789abcdef"
        let credentials = OAuthCredentials(access: "test-key", refresh: "", expires: .max, extras: [
            KimiIdentity.deviceIDExtra: .string(id),
        ])
        #expect(KimiIdentity.identity(recordedIn: credentials).deviceId == id)
    }

    @Test
    func `a missing or empty Kimi id gets a fresh lowercase id`() {
        let empty = OAuthCredentials(access: "test-key", refresh: "", expires: .max, extras: [
            KimiIdentity.deviceIDExtra: .string(""),
        ])
        let first = KimiIdentity.identity(recordedIn: nil).deviceId
        let second = KimiIdentity.identity(recordedIn: empty).deviceId
        for id in [first, second] {
            #expect(id.count == 32 && id.allSatisfy(\.isHexDigit) && id == id.lowercased())
        }
        #expect(first != second)
    }
}
