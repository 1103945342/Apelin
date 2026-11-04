import ApelinProtocol
import Foundation

extension Notification.Name {
    /// A model's figures were saved; an open conversation reads them with
    /// its next message.
    static let modelParametersChanged = Notification.Name("wiki.qaq.apelin.modelParametersChanged")
}

/// The two figures a model is read against, as the user set them in
/// Settings ▸ Models: a device preference, separate from the provider's
/// credentials and its catalog, kept per provider and model.
enum ModelParameters {
    /// One model's numbers: nil is what its own record says.
    struct Values: Equatable {
        var contextWindow: Int?
        var maxTokens: Int?

        var isEmpty: Bool { contextWindow == nil && maxTokens == nil }

        var wire: AgentModelParameters? {
            isEmpty ? nil : AgentModelParameters(contextWindow: contextWindow, maxTokens: maxTokens)
        }
    }

    private static func key(_ provider: AgentProvider, _ model: String) -> String {
        "modelParameters.\(provider.rawValue).\(model)"
    }

    static func values(for provider: AgentProvider?, model: String?) -> Values {
        guard let provider, let model, !model.isEmpty,
              let stored = UserDefaults.standard.dictionary(forKey: key(provider, model))
        else { return Values() }
        return Values(
            contextWindow: stored["contextWindow"] as? Int,
            maxTokens: stored["maxTokens"] as? Int
        )
    }

    static func save(_ values: Values, for provider: AgentProvider, model: String) {
        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(provider, model))
        } else {
            var stored: [String: Int] = [:]
            stored["contextWindow"] = values.contextWindow
            stored["maxTokens"] = values.maxTokens
            UserDefaults.standard.set(stored, forKey: key(provider, model))
        }
        NotificationCenter.default.post(name: .modelParametersChanged, object: nil)
    }
}
