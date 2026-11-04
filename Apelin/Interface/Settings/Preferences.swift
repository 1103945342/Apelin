import Foundation

/// What the reader chose for the app as a whole, kept in the device's
/// defaults beside the composer's own behaviour.
enum Preferences {
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
