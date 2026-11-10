import ApelinProtocol
import Foundation
import KWWKAI

/// How a catalog entry becomes the model a conversation talks to.
///
/// An endpoint that serves models of its own invention describes every one of
/// them the same way — kwwk's OpenAI-compatible login writes `[.text]`,
/// 131 072 tokens and 32 000 of reply into each — so `cn:deepseek-v4.1-flash`
/// arrives as a text-only model with a 32k reply ceiling. The entry the
/// catalogs hold for the same name knows better, and this is the one place it
/// is written into the model.
extension ModelCatalogIndex.Entry {
    /// The model with this entry's figures written into it. Its own name, API,
    /// provider, address and headers are the endpoint's and stay: only what the
    /// entry knows better changes.
    public func adopting(into model: Model) -> Model {
        var adopted = model
        if contextWindow > 0 {
            adopted.contextWindow = contextWindow
        }
        if maxTokens > 0 {
            adopted.maxTokens = maxTokens
        }
        var input: [InputModality] = [.text]
        if acceptsImages {
            input.append(.image)
        }
        adopted.input = input
        adopted.reasoning = reasoning
        if let thinkingLevelMap, !thinkingLevelMap.isEmpty {
            adopted.thinkingLevelMap = thinkingLevelMap
        }
        return adopted
    }

    /// What the entry says, for the settings page to show beside the app's own
    /// figures.
    public var capabilities: AgentModelCapabilities {
        AgentModelCapabilities(
            contextWindow: contextWindow > 0 ? contextWindow : nil,
            maxTokens: maxTokens > 0 ? maxTokens : nil,
            acceptsImages: acceptsImages,
            reasoning: reasoning,
            catalogName: id,
            catalogProvider: provider,
            source: source,
        )
    }

    /// The levels Apelin offers for the model this entry describes: those the
    /// catalog lists, and `off` for a model that thinks before it answers. A
    /// model that does not reason is offered none.
    public var reasoningEfforts: [AgentReasoningEffort] {
        guard reasoning else { return [] }
        var levels: [AgentReasoningEffort] = []
        for effort in efforts {
            switch effort.lowercased() {
            case "none": if !levels.contains(.off) { levels.append(.off) }
            default:
                guard let level = AgentReasoningEffort(rawValue: effort.lowercased()),
                      !levels.contains(level)
                else { continue }
                levels.append(level)
            }
        }
        if !levels.isEmpty, !levels.contains(.off) {
            levels.insert(.off, at: 0)
        }
        return levels
    }
}

/// Reads a model against the catalogs, then what the app's settings say over
/// it.
public enum ModelResolver {
    /// The model a conversation talks to: the catalog entry its name finds,
    /// unless the settings refuse the catalog, and then every figure the
    /// settings give explicitly.
    public static func resolving(
        _ model: Model,
        catalogKey: String? = nil,
        parameters: AgentModelParameters? = nil,
        index: ModelCatalogIndex = ModelCatalogIndex(),
    ) -> Model {
        var resolved = model
        if parameters?.followsCatalog ?? true,
           let entry = index.entry(for: model.id, catalogKey: catalogKey) {
            resolved = entry.adopting(into: model)
            // An endpoint the catalogs do not key, serving a model under the
            // catalog's own exact name, keeps what it says about images: a
            // stranger serving `deepseek-flash` is not DeepSeek, and an entry
            // found only by that name does not make it one. A name the endpoint
            // composed itself (`cn:deepseek-v4.1-flash`) does denote the model
            // it names, and takes the entry's images with the rest.
            if catalogKey == nil, entry.id.lowercased() == model.id.lowercased() {
                resolved.input = model.input
            }
        }
        if let window = parameters?.contextWindow, window > 0 {
            resolved.contextWindow = window
        }
        if let tokens = parameters?.maxTokens, tokens > 0 {
            resolved.maxTokens = tokens
        }
        if let acceptsImages = parameters?.acceptsImages {
            resolved.input = acceptsImages ? [.text, .image] : [.text]
        }
        if let reasoning = parameters?.reasoning {
            resolved.reasoning = reasoning
        }
        return resolved
    }

    /// The entry a model was read as, for the settings page to name.
    public static func entry(
        for id: String,
        catalogKey: String? = nil,
        index: ModelCatalogIndex = ModelCatalogIndex(),
    ) -> ModelCatalogIndex.Entry? {
        index.entry(for: id, catalogKey: catalogKey)
    }
}
