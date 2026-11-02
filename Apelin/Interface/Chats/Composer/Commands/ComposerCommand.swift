import Foundation

/// The placeholder a prompt-shaped command writes its arguments into.
private let argumentsPlaceholder = "$ARGUMENTS"

/// Puts `arguments` where a template asks for them. A template with no
/// placeholder keeps them on a line of their own rather than dropping what was
/// typed.
func substituteArguments(_ template: String, with arguments: String) -> String {
    if template.contains(argumentsPlaceholder) {
        return template.replacingOccurrences(of: argumentsPlaceholder, with: arguments)
    }
    if arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return template
    }
    return template + "\n\nAdditional input: " + arguments
}

/// Where a command comes from: one the app runs itself, or a skill whose
/// instructions are handed to the agent as the turn's prompt.
enum ComposerCommandKind: Equatable, Sendable {
    case action
    case skill
}

/// One entry in the menu that opens on a leading slash.
struct ComposerCommand: Equatable, Sendable, Identifiable {
    /// Without the slash, as it is typed: `compact`, `pdf-report`.
    var name: String
    /// One line, in the reader's language where the app has one.
    var summary: String
    var kind: ComposerCommandKind
    /// Whether the menu may add a space and let the reader type arguments.
    var acceptsArguments: Bool

    var id: String { name }

    /// The line the menu draws, which is what a reader scans for.
    var display: String { "/" + name }
}

/// Runs a command the app does itself. Each one is a small type registered in
/// `ComposerCommandCatalog`, so adding one touches this file and its own, and
/// nothing else.
protocol ComposerActionCommand {
    var name: String { get }
    var summary: String { get }
    var acceptsArguments: Bool { get }
    func run(arguments: String, in context: ComposerCommandContext)
}

/// What a command may ask of the conversation. Deliberately small: a command
/// that needs more than this belongs in the agent, not in the composer.
protocol ComposerCommandContext: AnyObject {
    /// Ask the agent to compact this conversation now.
    func compactConversation()
    /// Turn this conversation's usage into a message the reader can read.
    func showUsage()
    /// Start a turn from `prompt`, as if it had been typed and sent.
    func send(prompt: String)
    /// Put `text` in the composer without sending it.
    func fillComposer(with text: String)
}

/// The commands on offer, and the answer to what was typed so far.
final class ComposerCommandCatalog {
    private(set) var commands: [ComposerCommand] = []
    private var actions: [String: ComposerActionCommand] = [:]

    /// Skill instructions by command name, filled when the list arrives.
    private var skills: [String: AgentSkill] = [:]

    init(actions: [ComposerActionCommand]) {
        for action in actions {
            self.actions[action.name] = action
        }
    }

    /// What can be run right now: the actions, then the skills the agent
    /// reported.
    func rebuild() {
        var built: [ComposerCommand] = actions.values
            .sorted { $0.name < $1.name }
            .map { action in
                ComposerCommand(
                    name: action.name,
                    summary: action.summary,
                    kind: .action,
                    acceptsArguments: action.acceptsArguments,
                )
            }
        built += skills.values
            .sorted { $0.name < $1.name }
            .map { skill in
                ComposerCommand(
                    name: skill.name,
                    summary: skill.description,
                    kind: .skill,
                    acceptsArguments: true,
                )
            }
        commands = built
    }

    func setSkills(_ listed: [AgentSkill]) {
        skills = Dictionary(
            listed.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first },
        )
        rebuild()
    }

    /// The commands matching what has been typed after the slash, in the order
    /// the menu shows them: a bare slash lists everything.
    func matching(_ query: String) -> [ComposerCommand] {
        guard !query.isEmpty else { return commands }
        let lowered = query.lowercased()
        return commands.filter { $0.name.lowercased().hasPrefix(lowered) }
    }

    /// The action behind `name`, when it is one.
    func action(named name: String) -> ComposerActionCommand? {
        actions[name]
    }

    /// The skill behind `name`, when it is one.
    func skill(named name: String) -> AgentSkill? {
        skills[name]
    }
}
