import ApelinProtocol
import Foundation

extension Notification.Name {
    static let enabledModelsChanged = Notification.Name("wiki.qaq.apelin.enabledModelsChanged")
}

/// A device preference, separate from the provider's credentials and catalog.
enum EnabledModels {
    private static func key(_ provider: AgentProvider) -> String {
        "enabledModels.\(provider.rawValue)"
    }

    static func ids(for provider: AgentProvider) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(provider)) ?? [])
    }

    static func save(_ models: Set<String>, custom: Set<String>, hidden: Set<String>, for provider: AgentProvider) {
        UserDefaults.standard.set(models.sorted(), forKey: key(provider))
        UserDefaults.standard.set(custom.sorted(), forKey: "customModels.\(provider.rawValue)")
        UserDefaults.standard.set(hidden.sorted(), forKey: "hiddenModels.\(provider.rawValue)")
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    static func remove(for provider: AgentProvider) {
        UserDefaults.standard.removeObject(forKey: key(provider))
        UserDefaults.standard.removeObject(forKey: "customModels.\(provider.rawValue)")
        UserDefaults.standard.removeObject(forKey: "hiddenModels.\(provider.rawValue)")
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    static func customIDs(for provider: AgentProvider) -> [String] {
        UserDefaults.standard.stringArray(forKey: "customModels.\(provider.rawValue)") ?? []
    }

    static func hiddenIDs(for provider: AgentProvider) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "hiddenModels.\(provider.rawValue)") ?? [])
    }

    /// The model ids this device keeps for each provider, keyed by the
    /// provider's own id: handed to the account listing so the catalogs are
    /// read over the models the app shows — a custom endpoint's own — and not
    /// only the ones the agent can list for itself.
    static func knownModelIDs() -> [String: [String]] {
        var known: [String: [String]] = [:]
        for provider in AgentProvider.allCases {
            let models = ids(for: provider)
                .union(customIDs(for: provider))
                .subtracting(hiddenIDs(for: provider))
            if !models.isEmpty {
                known[provider.rawValue] = models.sorted()
            }
        }
        return known
    }

    static func accounts(from accounts: [AgentAccount]) -> [AgentAccount] {
        accounts.compactMap { account in
            guard account.signedIn else { return nil }
            var enabled = account
            let ids = ids(for: account.provider).subtracting(hiddenIDs(for: account.provider))
            enabled.models = account.isAPIKeyAccount ? ids.sorted() : (account.models ?? []).filter { ids.contains($0) }
            return enabled.models?.isEmpty == false ? enabled : nil
        }
    }
}
