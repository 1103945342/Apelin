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

    /// The approval mode a run starts in, for a mode that sets one. Automatic
    /// runs ask nothing; the other two keep whatever the reader chose.
    var impliedApprovalMode: ApelinProtocol.ApprovalMode? {
        switch self {
        case .auto: .full
        case .plan, .build: nil
        }
    }
}

/// Where the pill's setting is kept, read fresh by each run so a change lands on
/// the next message rather than the one being answered.
enum ComposerModeStore {
    private static let key = "composer.mode"

    static var mode: ComposerMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let mode = ComposerMode(rawValue: raw)
            else { return .build }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
