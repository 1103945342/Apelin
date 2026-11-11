import ApelinProtocol
import Foundation

/// What the reader chose for the app as a whole, kept in the device's
/// defaults beside the composer's own behaviour.
enum Preferences {
    /// A model used by an agent operation that is not the conversation's main turn.
    enum DefaultModelKind: String, CaseIterable {
        case promptRewrite
        case compression
        case title
        case vision
        case imageGeneration

        var title: String {
            switch self {
            case .promptRewrite: String(localized: "Prompt Optimization")
            case .compression: String(localized: "Conversation Compression")
            case .title: String(localized: "Title Generation")
            case .vision: String(localized: "Image Understanding")
            case .imageGeneration: String(localized: "Image Generation")
            }
        }
    }

    struct DefaultModelSelection: Equatable {
        let provider: AgentProvider
        let model: String
    }

    /// The model defaults used by agent operations. An unset value means that
    /// operation follows the conversation's selected model.
    enum DefaultModels {
        static let changed = Notification.Name("wiki.qaq.apelin.defaultModelsChanged")

        static func selection(for kind: DefaultModelKind, defaults: UserDefaults = .standard) -> DefaultModelSelection? {
            guard let provider = defaults.string(forKey: providerKey(kind)).flatMap(AgentProvider.init(rawValue:)),
                  let model = defaults.string(forKey: modelKey(kind)),
                  !model.isEmpty
            else { return nil }
            return DefaultModelSelection(provider: provider, model: model)
        }

        static func save(_ selection: DefaultModelSelection, for kind: DefaultModelKind, defaults: UserDefaults = .standard) {
            defaults.set(selection.provider.rawValue, forKey: providerKey(kind))
            defaults.set(selection.model, forKey: modelKey(kind))
            NotificationCenter.default.post(name: changed, object: kind)
        }

        static func remove(for kind: DefaultModelKind, defaults: UserDefaults = .standard) {
            defaults.removeObject(forKey: providerKey(kind))
            defaults.removeObject(forKey: modelKey(kind))
            NotificationCenter.default.post(name: changed, object: kind)
        }

        static func summary(for kind: DefaultModelKind, defaults: UserDefaults = .standard) -> String {
            guard let selection = selection(for: kind, defaults: defaults) else {
                return String(localized: "Use Conversation Model")
            }
            return "\(selection.provider.displayName) · \(selection.model)"
        }

        static var summary: String {
            let count = DefaultModelKind.allCases.count { selection(for: $0) != nil }
            guard count > 0 else { return String(localized: "Use Conversation Model") }
            return String(localized: "\(count) configured")
        }

        static var wire: AgentModelDefaults {
            func convert(_ kind: DefaultModelKind) -> AgentModelSelection? {
                guard let value = selection(for: kind) else { return nil }
                return AgentModelSelection(provider: value.provider, model: value.model)
            }
            return AgentModelDefaults(
                promptRewrite: convert(.promptRewrite),
                compression: convert(.compression),
                title: convert(.title),
                vision: convert(.vision),
                imageGeneration: convert(.imageGeneration)
            )
        }

        private static func providerKey(_ kind: DefaultModelKind) -> String {
            "agent.defaultModel.\(kind.rawValue).provider"
        }

        private static func modelKey(_ kind: DefaultModelKind) -> String {
            "agent.defaultModel.\(kind.rawValue).model"
        }
    }

    /// The text the reader wants every conversation to start under: what the
    /// agent's system prompt carries before anything else. Kept beside the
    /// other settings, and sent with each session as it opens — a
    /// conversation already running keeps the prompt it opened with.
    enum PromptInjection {
        /// What one prompt may carry, as project instructions are capped.
        static let maximumCharacters = 16 * 1024

        static var enabled: Bool {
            get { UserDefaults.standard.bool(forKey: "agent.promptInjection.enabled") }
            set { UserDefaults.standard.set(newValue, forKey: "agent.promptInjection.enabled") }
        }

        static var text: String {
            get { UserDefaults.standard.string(forKey: "agent.promptInjection.text") ?? "" }
            set {
                // Kept as typed: what the page shows must be what was written,
                // and the trim happens where the prompt is made.
                UserDefaults.standard.set(
                    String(newValue.prefix(maximumCharacters)),
                    forKey: "agent.promptInjection.text",
                )
            }
        }

        /// Whether there is anything to inject at all.
        static var isEmpty: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// What a session's open carries: the text while the switch is on and
        /// something is written, nil otherwise.
        static var wire: String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return enabled && !trimmed.isEmpty ? trimmed : nil
        }
    }

    /// What the next launch opens.
    enum Launch: String, CaseIterable {
        case lastConversation
        case newChat

        var title: String {
            switch self {
            case .lastConversation: String(localized: "Last Conversation")
            case .newChat: String(localized: "New Chat")
            }
        }
    }

    /// The share of a conversation's context that compacts it by itself.
    ///
    /// The agent compacts a conversation when what it holds reaches this
    /// share of the window the model reports, so a long one carries on
    /// without the reader asking.
    static var compressionThreshold: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: "chat.compressionThreshold") as? Double
            return (stored ?? 0.75).clamped(to: 0.5 ... 0.95)
        }
        set { UserDefaults.standard.set(newValue.clamped(to: 0.5 ... 0.95), forKey: "chat.compressionThreshold") }
    }

    /// The shares the threshold may be set to.
    static let compressionChoices: [Double] = [0.5, 0.6, 0.75, 0.85, 0.9, 0.95]

    /// `0.75` as "75%", in the reader's locale.
    static func percentText(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Whether the diff wraps its lines or scrolls them sideways.
    static var diffWraps: Bool {
        get { UserDefaults.standard.object(forKey: "git.diffWraps") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "git.diffWraps") }
    }

    static var launch: Launch {
        get {
            UserDefaults.standard.string(forKey: "chat.launch")
                .flatMap(Launch.init(rawValue:)) ?? .lastConversation
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "chat.launch") }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
