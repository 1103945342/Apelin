import Foundation

/// `/compact`: fold the conversation up now, rather than waiting for the agent
/// to reach the limit on its own.
struct CompactCommand: ComposerActionCommand {
    let name = "compact"
    let summary = String(localized: "Compact this conversation now.")
    let acceptsArguments = false

    func run(arguments _: String, in context: ComposerCommandContext) {
        context.compactConversation()
    }
}

/// `/usage`: what this conversation has cost so far, as a message in it.
struct UsageCommand: ComposerActionCommand {
    let name = "usage"
    let summary = String(localized: "Show what this conversation has used.")
    let acceptsArguments = false

    func run(arguments _: String, in context: ComposerCommandContext) {
        context.showUsage()
    }
}

/// `/init`: read the project and write or improve the rules file the agent is
/// given at the start of every session.
struct InitProjectCommand: ComposerActionCommand {
    let name = "init"
    let summary = String(localized: "Write or improve this project's rules file.")
    let acceptsArguments = true

    func run(arguments: String, in context: ComposerCommandContext) {
        let instruction = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = instruction.isEmpty
            ? """
            Read this project and write the rules file the agent is given at the start of \
            a session: what it builds, how it is built and verified, and the conventions to \
            keep. If the file already exists, improve it rather than replacing what is right.
            """
            : """
            Read this project and write or improve the rules file the agent is given at the \
            start of a session. \(instruction)
            """
        context.send(prompt: prompt)
    }
}
