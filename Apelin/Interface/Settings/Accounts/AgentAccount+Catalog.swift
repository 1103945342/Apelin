import ApelinProtocol

/// How a model is written on screen.
///
/// The provider's own id is what a conversation sends and what every row would
/// otherwise show — `cn:deepseek-v4.1-flash` for the model the catalogs call
/// DeepSeek V4.1 Flash. Where a catalog knows the model, its name is the one a
/// reader sees and the id sits under it, unchanged: nothing is renamed on the
/// wire, and a model no catalog names keeps its id alone.
extension AgentModelCapabilities {
    /// The catalog's name for `model`, unless it only spells the id again.
    func displayName(for model: String) -> String? {
        guard let name = catalogName, !name.isEmpty,
              name.caseInsensitiveCompare(model) != .orderedSame
        else { return nil }
        return name
    }
}

extension AgentAccount {
    /// The name a catalog gives `model`, when one knows it.
    func catalogName(for model: String) -> String? {
        capabilities?[model]?.displayName(for: model)
    }

    /// The model as a reader reads it: the catalog's name, or its own id.
    func displayName(for model: String) -> String {
        catalogName(for: model) ?? model
    }
}
