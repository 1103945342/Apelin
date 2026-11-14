import Foundation

/// What a WeChat message can ask of the channel itself (2026-11-15).
///
/// The commands are handled here — by the host, not by the agent — because
/// they change where the next message goes: which conversation, which
/// project, which model. A message that does not begin with `/` is a
/// message for the conversation.
public enum ChannelCommand: Equatable, Sendable {
    /// `/sessions` — every conversation, numbered, most recent first.
    case sessions
    /// `/use <number|id|new>` — talk in that conversation from now on.
    case use(String)
    /// `/current` — which conversation this phone talks in.
    case current
    /// `/workspace` — the projects, numbered; `/workspace <number|name>`
    /// picks the one a new conversation is opened in.
    case workspace(String?)
    /// `/model` — the models this device can use, numbered; `/model <n>`
    /// picks one, `/model <n> <effort>` picks one and its effort.
    case model(String?, String?)
    /// `/effort` — the effort now; `/effort <lo|mid|hi|…>` sets it.
    case effort(String?)
    /// `/send <path>` — sends a file of the device to WeChat: a path inside
    /// the conversation's project, or a full path inside the project.
    case send(String)
    case help
}

public enum ChannelCommands {
    /// The command `text` asks for, or nil when it is a message.
    public static func parse(_ text: String) -> ChannelCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        // Only the first line is the command: a pasted prompt often carries
        // a newline of its own.
        let line = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let head = parts.first else { return nil }
        let command = head.lowercased()
        let first = parts.count > 1 ? parts[1] : ""
        let rest = parts.count > 2 ? parts[2...].joined(separator: " ") : ""
        switch command {
        case "/sessions", "/ls":
            return .sessions
        case "/use", "/switch":
            return .use(first)
        case "/current", "/now":
            return .current
        case "/workspace", "/ws":
            return .workspace(first.isEmpty ? nil : first)
        case "/model", "/m":
            return .model(first.isEmpty ? nil : first, rest.isEmpty ? nil : rest)
        case "/effort":
            return .effort(first.isEmpty ? nil : first)
        case "/send", "/file":
            // A path may hold spaces: take the rest of the line as it is.
            let path = line.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
            return .send(path)
        case "/help", "/?":
            return .help
        default:
            // An unknown slash word is a message: a prompt can start that way.
            return nil
        }
    }

    /// The effort an argument names, in the short spellings a phone types.
    public static func effort(_ argument: String) -> AgentReasoningEffort? {
        switch argument.lowercased() {
        case "off", "none": .off
        case "min", "minimal": .minimal
        case "lo", "low": .low
        case "mid", "medium", "med": .medium
        case "hi", "high": .high
        case "xhi", "xhigh": .xhigh
        case "max": .max
        default: nil
        }
    }

    /// The spelling the channel shows for an effort.
    public static func effortName(_ effort: AgentReasoningEffort) -> String {
        switch effort {
        case .off: "off"
        case .minimal: "min"
        case .low: "lo"
        case .medium: "mid"
        case .high: "hi"
        case .xhigh: "xhi"
        case .max: "max"
        }
    }

    /// The number `argument` is, 1-based as the lists print them.
    public static func index(_ argument: String) -> Int? {
        guard let number = Int(argument.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
        return number
    }
}

/// One model the channel can put a conversation on.
public struct ChannelModel: Codable, Sendable, Equatable, Hashable {
    public var provider: AgentProvider
    public var model: String
    /// Same as `model` when the provider names it that way; kept apart so a
    /// list can show `provider · model` and still send the pair.
    public var label: String

    public init(provider: AgentProvider, model: String, label: String? = nil) {
        self.provider = provider
        self.model = model
        self.label = label ?? model
    }
}
