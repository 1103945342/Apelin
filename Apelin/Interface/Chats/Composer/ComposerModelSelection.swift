import ApelinProtocol
import Foundation

extension Notification.Name {
    static let composerModelSelectionChanged = Notification.Name("wiki.qaq.apelin.composerModelSelectionChanged")
}

/// The model every composer sends with, restored before the catalog loads.
/// Each control of the model row keeps a default of its own: this is the
/// model's, with the catalog's last word on what it offers; the reader's
/// effort and speed are `ComposerModelPreferences`, which only the reader's
/// pick changes. A model that does not offer them is sent the nearest it
/// does, and a later model that offers them gets them back.
struct ComposerModelSelection: Codable, Equatable {
    var provider: AgentProvider
    var model: String
    /// The last catalog snapshot, so the effort control also restores offline.
    var supportedEfforts: [AgentReasoningEffort]
    /// The tiers the model offers, from the same snapshot; absent in a
    /// selection saved before there were any.
    var supportedTiers: [AgentServiceTier]?

    /// A conversation keeps its own picks, including a preference its current
    /// model cannot offer. Absent only in the old, global default.
    var conversationScoped: Bool? = nil
    var preferredEffort: AgentReasoningEffort? = nil
    var preferredTier: AgentServiceTier? = nil

    /// The effort sent: the reader's where the model offers it, else High,
    /// else its strongest; nil for a model that offers none.
    var effort: AgentReasoningEffort? {
        let chosen = conversationScoped == true ? preferredEffort : ComposerModelPreferences.effort
        if let chosen, supportedEfforts.contains(chosen) {
            return chosen
        }
        return supportedEfforts.contains(.high) ? .high : supportedEfforts.last
    }

    /// The tier sent: the reader's where the model offers it, else the
    /// standard one (nil).
    var tier: AgentServiceTier? {
        let chosen = conversationScoped == true ? preferredTier : ComposerModelPreferences.tier
        return chosen.flatMap { (supportedTiers ?? []).contains($0) ? $0 : nil }
    }

    /// The model the last conversation used, written on every pick and read
    /// by the next new conversation, which starts on what the reader was
    /// last working with rather than on an older default. It carries no
    /// effort or speed of its own: those are `ComposerModelPreferences`.
    static func selection(for id: UUID, defaults: UserDefaults = .standard) -> Self? {
        let scopedKey = key + ".conversation." + id.uuidString
        if let data = defaults.data(forKey: scopedKey) {
            return try? JSONDecoder().decode(Self.self, from: data)
        }
        guard var seed = current else { return nil }
        seed.conversationScoped = true
        seed.preferredEffort = ComposerModelPreferences.effort
        seed.preferredTier = ComposerModelPreferences.tier
        save(seed, for: id, defaults: defaults)
        return seed
    }

    /// The model the reader picked for a conversation, kept for the next new
    /// conversation to start on: the app's last-known choice, without this
    /// conversation's own effort and speed, which the reader's picks keep.
    static func rememberSelection(_ selection: Self) {
        var stored = selection
        stored.conversationScoped = nil
        stored.preferredEffort = nil
        stored.preferredTier = nil
        current = stored
    }

    /// Changing models or refreshing the catalog keeps this chat's picks.
    static func choose(_ model: Self, for id: UUID, defaults: UserDefaults = .standard) {
        let previous = selection(for: id, defaults: defaults)
        var next = model
        next.conversationScoped = true
        next.preferredEffort = previous?.preferredEffort ?? ComposerModelPreferences.effort
        next.preferredTier = previous == nil ? ComposerModelPreferences.tier : previous?.preferredTier
        save(next, for: id, defaults: defaults)
    }

    static func setEffort(_ effort: AgentReasoningEffort, for id: UUID, defaults: UserDefaults = .standard) {
        guard var selected = selection(for: id, defaults: defaults) else { return }
        selected.preferredEffort = effort
        save(selected, for: id, defaults: defaults)
        // The reader's pick is the app's from now on: a conversation started
        // afterwards is seeded with it, as it is with the model.
        ComposerModelPreferences.effort = effort
    }

    static func setTier(_ tier: AgentServiceTier?, for id: UUID, defaults: UserDefaults = .standard) {
        guard var selected = selection(for: id, defaults: defaults) else { return }
        selected.preferredTier = tier
        save(selected, for: id, defaults: defaults)
        ComposerModelPreferences.tier = tier
    }

    /// A conversation an agent opened (`ChatAdoption`) starts on the model
    /// Settings ▸ Default Models names for delegated chats, where the reader
    /// named one: the session its opener opened already runs on it. Counts
    /// and speeds are left to `ensureModelSelection`, which fills them from
    /// the catalog as it refreshes the row. A conversation with a pick of its
    /// own is never seeded, nor is one whose settings name none.
    static func seedDelegated(for id: UUID, defaults: UserDefaults = .standard) {
        guard defaults.data(forKey: key + ".conversation." + id.uuidString) == nil,
              let chosen = Preferences.DefaultModels.selection(for: .derivedConversation, defaults: defaults)
        else { return }
        var seed = Self(
            provider: chosen.provider,
            model: chosen.model,
            supportedEfforts: [],
            supportedTiers: [],
        )
        seed.conversationScoped = true
        seed.preferredEffort = ComposerModelPreferences.effort
        seed.preferredTier = ComposerModelPreferences.tier
        save(seed, for: id, defaults: defaults)
    }

    /// A conversation shown but never written in keeps no pick of its own:
    /// started again, it is a new conversation and takes the model the
    /// reader last picked, not the one it was seeded with when it was first
    /// shown.
    static func forget(_ id: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key + ".conversation." + id.uuidString)
        NotificationCenter.default.post(name: .composerModelSelectionChanged, object: id)
    }

    /// A conversation made from another one keeps its picks: a branch of a
    /// chat is that chat continued, so it sends the same model, effort and
    /// speed instead of the defaults a new conversation is seeded with.
    static func inherit(from parent: UUID, into child: UUID, defaults: UserDefaults = .standard) {
        guard let selection = selection(for: parent, defaults: defaults) else { return }
        save(selection, for: child, defaults: defaults)
    }

    private static func save(_ selection: Self, for id: UUID, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: key + ".conversation." + id.uuidString)
        NotificationCenter.default.post(name: .composerModelSelectionChanged, object: id)
    }

    static var current: Self? {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
        set {
            ComposerModelPreferences.adoptLegacyPicks()
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
            NotificationCenter.default.post(name: .composerModelSelectionChanged, object: nil)
        }
    }

    fileprivate static let key = "composer.modelSelection"
}

/// The reader's own picks on the effort and Speed controls, each kept
/// under its own key whatever model is chosen and whatever its catalog
/// lists, so a model that lacks one, or a catalog that briefly says
/// nothing, never takes it away.
enum ComposerModelPreferences {
    private static let effortKey = "composer.reasoningEffort"
    private static let tierKey = "composer.serviceTier"
    /// What `tierKey` holds for a reader who picked Standard, so the pick
    /// is told apart from a key never written.
    private static let standardTier = "standard"

    /// Nil until the reader picks one.
    static var effort: AgentReasoningEffort? {
        get {
            UserDefaults.standard.string(forKey: effortKey).flatMap(AgentReasoningEffort.init(rawValue:))
                ?? legacy?.effort
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: effortKey)
            NotificationCenter.default.post(name: .composerModelSelectionChanged, object: nil)
        }
    }

    /// Nil is the standard tier.
    static var tier: AgentServiceTier? {
        get {
            guard let saved = UserDefaults.standard.string(forKey: tierKey) else { return legacy?.tier }
            return AgentServiceTier(rawValue: saved)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue ?? standardTier, forKey: tierKey)
            NotificationCenter.default.post(name: .composerModelSelectionChanged, object: nil)
        }
    }

    /// The picks a selection saved before these keys existed held itself;
    /// read until the selection is written again, which moves them here.
    private struct Legacy: Decodable {
        var effort: AgentReasoningEffort?
        var tier: AgentServiceTier?
    }

    private static var legacy: Legacy? {
        UserDefaults.standard.data(forKey: ComposerModelSelection.key)
            .flatMap { try? JSONDecoder().decode(Legacy.self, from: $0) }
    }

    /// Before a new selection replaces one that still holds the picks.
    fileprivate static func adoptLegacyPicks() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: effortKey) == nil || defaults.object(forKey: tierKey) == nil,
              let legacy
        else { return }
        if defaults.object(forKey: effortKey) == nil, let effort = legacy.effort {
            defaults.set(effort.rawValue, forKey: effortKey)
        }
        if defaults.object(forKey: tierKey) == nil {
            defaults.set(legacy.tier?.rawValue ?? standardTier, forKey: tierKey)
        }
    }
}
