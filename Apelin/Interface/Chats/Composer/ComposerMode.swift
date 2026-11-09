import ApelinProtocol
import Foundation

/// What a run is allowed to do, as the pill under the composer sets it.
///
/// Not the same question the approval mode answers: that one says when the user
/// is asked before the agent acts, this one says whether it acts at all. A plan
/// run may read and search, and may not write, build or install; a build run may
/// do everything its approval mode allows; an automatic run is a build run that
/// stops asking. The two are read together, never one for the other.
enum ComposerMode: String, CaseIterable, Codable, Sendable {
    case plan
    case build
    case auto

    /// The order the pill cycles in.
    static let cycle: [ComposerMode] = [.build, .plan, .auto]

    var next: ComposerMode {
        switch self {
        case .build: .plan
        case .plan: .auto
        case .auto: .build
        }
    }

    /// What the agent is told the run may do. Sent with the turn, beside the
    /// approval mode, which still governs each step.
    var instruction: String? {
        switch self {
        case .plan:
            """
            This run is a plan: read what you need, and answer with what you would \
            change and why. Do not edit, create or delete a file, and do not build, \
            install or run anything that changes the device.
            """
        case .build, .auto:
            nil
        }
    }

    /// The same three, as the wire names them: what a prompt carries so the
    /// agent reads this run's mode in its `<system-state>`.
    var runMode: AgentRunMode {
        switch self {
        case .plan: .plan
        case .build: .build
        case .auto: .auto
        }
    }

    /// The approval mode a run starts in, for a mode that sets one. Automatic
    /// runs ask nothing; the other two keep whatever the reader chose.
    var impliedApprovalMode: ApelinProtocol.ApprovalMode? {
        switch self {
        case .auto: .full
        case .plan, .build: nil
        }
    }
}

/// Where the pill's setting is kept: one entry per conversation, read fresh by
/// each run so a change lands on the next message rather than the one being
/// answered, and never carried into another conversation.
///
/// The single key this had before was every conversation's at once — a plan set
/// in one turned the one opened beside it into a plan too. It stays only as a
/// seed: the first time a conversation is read, it takes the old value and
/// writes it down as its own, and nothing writes that key again.
enum ComposerModeStore {
    private static let seedKey = "composer.mode"

    private static func key(for id: UUID) -> String {
        "composer.mode.conversation." + id.uuidString
    }

    /// The mode a run in `id` goes out with. Nil — no conversation on screen
    /// yet — is only ever asked by the pill as it is built, and starts afresh.
    static func mode(for id: UUID?) -> ComposerMode {
        guard let id else { return .build }
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: key(for: id)),
           let mode = ComposerMode(rawValue: raw)
        {
            return mode
        }
        let seed = defaults.string(forKey: seedKey).flatMap(ComposerMode.init(rawValue:)) ?? .build
        defaults.set(seed.rawValue, forKey: key(for: id))
        return seed
    }

    static func set(_ mode: ComposerMode, for id: UUID?) {
        guard let id else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: key(for: id))
    }
}
