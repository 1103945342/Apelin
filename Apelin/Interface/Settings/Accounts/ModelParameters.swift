import ApelinProtocol
import Foundation

extension Notification.Name {
    /// A model's figures were saved; an open conversation reads them with
    /// its next message.
    static let modelParametersChanged = Notification.Name("wiki.qaq.apelin.modelParametersChanged")
}

/// What one model is read as, as the user set it in Settings ▸ Models: a
/// device preference, separate from the provider's credentials and its
/// catalog, kept per provider and model.
///
/// Absent is never the same as `false` here: a figure left alone is what the
/// catalog entry says, and one set is the user's answer in its place.
enum ModelParameters {
    /// One model's figures: nil is what its catalog entry, or its own record,
    /// says.
    struct Values: Equatable {
        var contextWindow: Int?
        var maxTokens: Int?
        /// Whether the model takes images; `false` is a relay that serves it
        /// as text only, `true` one whose record does not say so.
        var acceptsImages: Bool?
        /// Whether it thinks before it answers.
        var reasoning: Bool?
        /// Whether the catalog's figures apply at all: an endpoint that
        /// refuses a figure it does not honour. Absent is on.
        var followsCatalog: Bool?

        var isEmpty: Bool {
            contextWindow == nil && maxTokens == nil && acceptsImages == nil
                && reasoning == nil && followsCatalog == nil
        }

        var wire: AgentModelParameters? {
            isEmpty ? nil : AgentModelParameters(
                contextWindow: contextWindow,
                maxTokens: maxTokens,
                acceptsImages: acceptsImages,
                reasoning: reasoning,
                followsCatalog: followsCatalog,
            )
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
            maxTokens: stored["maxTokens"] as? Int,
            acceptsImages: stored["acceptsImages"] as? Bool,
            reasoning: stored["reasoning"] as? Bool,
            followsCatalog: stored["followsCatalog"] as? Bool,
        )
    }

    static func save(_ values: Values, for provider: AgentProvider, model: String) {
        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(provider, model))
        } else {
            // Only what the user set is stored: a plist cannot hold an
            // optional, and an absent key is what the catalog or the record
            // says.
            var stored: [String: Any] = [:]
            if let contextWindow = values.contextWindow { stored["contextWindow"] = contextWindow }
            if let maxTokens = values.maxTokens { stored["maxTokens"] = maxTokens }
            if let acceptsImages = values.acceptsImages { stored["acceptsImages"] = acceptsImages }
            if let reasoning = values.reasoning { stored["reasoning"] = reasoning }
            if let followsCatalog = values.followsCatalog { stored["followsCatalog"] = followsCatalog }
            UserDefaults.standard.set(stored, forKey: key(provider, model))
        }
        NotificationCenter.default.post(name: .modelParametersChanged, object: nil)
    }
}
