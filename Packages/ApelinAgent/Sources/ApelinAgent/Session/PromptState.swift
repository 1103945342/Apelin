import struct ApelinCore.MemoryRecord
import struct ApelinCore.MemoryStore
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAI

/// What the system prompt shows that can change while a session runs: the
/// reader's injected instructions, the project's instructions, the skills
/// list, the memory this chat sees, the environment and the build system.
///
/// A session takes it once, when it opens (and again after a compaction,
/// which rewrites the conversation's prefix anyway), and its system prompt
/// stays those bytes for the session's life, so the provider's cache of the
/// conversation holds. What changes later reaches the model only as a
/// delta in the next message's `<system-state>` (`changes(since:)`).
struct PromptState: Equatable {
    var instructions: ProjectInstructions?
    var skills: [SkillDocument]
    /// The records this chat sees; nil when the store cannot be read.
    var memory: [MemoryRecord]?
    var environment: String
    var buildSystem: ProjectBuildSystem
    /// The reader's standing instructions (Settings ▸ Agent ▸ Prompt
    /// Injection), as the app last sent them; empty while they are off or
    /// nothing is written. Unlike the rest, these are the reader's own switch:
    /// turning it on or off reaches a chat that was already open at its next
    /// message, which is the only way it can — the system prompt is still the
    /// bytes the session opened with (`injectionChanges`).
    var injected: String

    /// What a delta quotes of one memory body or skill description.
    static let maximumQuoted = 300
    /// Project instructions longer than this are named as changed, not quoted.
    static let maximumInstructions = 2000
    /// A delta longer than this names the sources that changed and where
    /// to read them.
    static let maximumDelta = 4000

    /// `toolExtensions`: the extensions whose tools the session offers now,
    /// which only change between runs; nil reads what is installed.
    /// `injected`: the reader's instructions as the app last sent them; nil
    /// reads the configuration's, which are the ones a session opened with.
    static func read(
        _ configuration: AgentSessionConfiguration,
        root: ScopedRoot,
        skills: [SkillDocument],
        device: DeviceFacts = .current,
        toolExtensions: [OfferedToolExtension]? = nil,
        injected: String? = nil,
    ) -> PromptState {
        let memory = try? MemoryStore(root: configuration.dataRoot.url).read().forProject(configuration.project.id)
        let extensions = toolExtensions ?? ToolExtensionOffer.read(
            installRoot: configuration.installRoot,
            policy: configuration.toolExtensionPolicy,
        ).extensions
        let inputs = EnvironmentPrompt.inputs(configuration, root: root, device: device, toolExtensions: extensions)
        return PromptState(
            instructions: SystemPrompt.projectInstructions(in: root),
            skills: skills,
            memory: memory?.records,
            environment: EnvironmentPrompt.section(inputs),
            buildSystem: ProjectBuildSystem.read(in: root),
            injected: Self.trimmed(injected ?? configuration.promptInjection),
        )
    }

    /// The injected text as both the prompt and the delta carry it: trimmed
    /// once, so a setting that differs by whitespace alone is no change.
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Deltas

    /// Where a change came from, which also says where to read it again
    /// when there is too much to quote.
    enum Source: String, CaseIterable {
        case buildSystem = "build system"
        case instructions = "project instructions"
        case skills
        case memory
        case environment

        var whereToRead: String {
            switch self {
            case .buildSystem: "apelin-project.json says how it builds"
            case .instructions: "read AGENTS.md or CLAUDE.md with file_read"
            case .skills: "apelin_skill_list answers them"
            case .memory: "apelin_memory_list answers it"
            case .environment: "apelin_toolchain_list and apelin_sdk_list answer it"
            }
        }
    }

    /// One line per change from `old` to here, each naming its source. The
    /// reader's injected instructions open the list and are quoted in full
    /// however long they are: they are the one thing here no tool reads back,
    /// and the reader turning them on or off must reach a chat already open.
    func changes(since old: PromptState) -> [String] {
        var changes: [(source: Source, text: String)] = []
        if buildSystem != old.buildSystem {
            changes.append((.buildSystem, buildSystem == .external
                    ? "build system: this project is now a workspace with its own build script (the apelin-external-build skill)."
                    : "build system: this project now builds from its apelin-project.json description."))
        }
        changes += instructionChanges(since: old.instructions).map { (.instructions, $0) }
        changes += skillChanges(since: old.skills).map { (.skills, $0) }
        changes += memoryChanges(since: old.memory).map { (.memory, $0) }
        changes += environmentChanges(since: old.environment).map { (.environment, $0) }
        let injection = injectionChanges(since: old.injected)
        guard changes.reduce(0, { $0 + $1.text.count }) > Self.maximumDelta else {
            return injection + changes.map(\.text)
        }
        // Too much to quote: say which sources changed and where they are.
        return injection + Source.allCases.filter { source in changes.contains { $0.source == source } }
            .map { "\($0.rawValue): changed; \($0.whereToRead)." }
    }

    /// The reader's own instructions turning on, off or into another text.
    /// The system prompt carries the instructions a session opened with and
    /// keeps those bytes; this is how the switch reaches a chat that was
    /// already open, so it says plainly which of the two is in force.
    private func injectionChanges(since old: String) -> [String] {
        guard injected != old else { return [] }
        guard !injected.isEmpty else {
            return [
                "prompt injection is off now (Settings ▸ Agent ▸ Prompt Injection): the injected instructions "
                    + "no longer apply, whatever the system prompt above still carries.",
            ]
        }
        let heading = old.isEmpty
            ? "prompt injection is on now (Settings ▸ Agent ▸ Prompt Injection); these instructions take precedence over everything else, the system prompt included:"
            : "the reader's injected instructions changed (Settings ▸ Agent ▸ Prompt Injection); the text below is the one in force, and it takes precedence over everything else, the system prompt included:"
        return [heading + "\n" + injected]
    }

    private func instructionChanges(since old: ProjectInstructions?) -> [String] {
        guard instructions != old else { return [] }
        guard let instructions else {
            return ["project instructions: \(old?.file ?? "AGENTS.md") was removed; follow none now."]
        }
        if instructions.text.count > Self.maximumInstructions {
            return ["project instructions: \(instructions.file) changed; read it with file_read and follow it."]
        }
        return ["project instructions: \(instructions.file) is now:\n" + instructions.text]
    }

    private func skillChanges(since old: [SkillDocument]) -> [String] {
        let before = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Set(skills.map(\.name))
        var lines: [String] = []
        for skill in skills {
            let entry = "\(skill.name)\(skill.isUserSkill ? " (user)" : ""): \(Self.quoted(skill.description))"
            if let previous = before[skill.name] {
                if previous.description != skill.description || previous.isUserSkill != skill.isUserSkill {
                    lines.append("skill changed: " + entry)
                }
            } else {
                lines.append("skill added: " + entry)
            }
        }
        for skill in old where !names.contains(skill.name) {
            lines.append("skill removed: \(skill.name)")
        }
        return lines
    }

    private func memoryChanges(since old: [MemoryRecord]?) -> [String] {
        guard let memory else {
            return old == nil ? [] : ["memory: storage is unavailable now; do not invent saved memories."]
        }
        let before = Dictionary((old ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(memory.map(\.id))
        var lines: [String] = []
        for record in memory {
            let entry = "(\(record.projectID == nil ? "all chats" : "this project")): \(record.title): \(Self.quoted(record.body))"
            if let previous = before[record.id] {
                if previous != record {
                    lines.append("memory changed " + entry)
                }
            } else {
                lines.append("memory added " + entry)
            }
        }
        for record in old ?? [] where !ids.contains(record.id) {
            lines.append("memory removed: \(record.title)")
        }
        return lines
    }

    /// The environment section's lines that went and came, in order.
    private func environmentChanges(since old: String) -> [String] {
        func facts(_ section: String) -> [String] {
            section.components(separatedBy: "\n").dropFirst() // the heading
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
        }
        let previous = facts(old)
        let current = facts(environment)
        let gone = previous.filter { !current.contains($0) }
        let came = current.filter { !previous.contains($0) }
        guard !gone.isEmpty || !came.isEmpty else { return [] }
        let lines = gone.map { "- no longer: " + $0 } + came.map { "- now: " + $0 }
        return ["environment:\n" + lines.joined(separator: "\n")]
    }

    private static func quoted(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > maximumQuoted ? String(line.prefix(maximumQuoted)) + "…" : line
    }

    // MARK: - The agent's own changes

    /// `told` with what this session's own call just changed taken in, so
    /// the next delta does not repeat what the tool's result said. Only the
    /// item the call named is taken: anything else that changed meanwhile
    /// is still a change the model has not heard of.
    static func absorbing(
        _ tool: AgentToolName,
        arguments: JSONValue,
        into told: PromptState,
        now: PromptState,
        project: ProjectIdentity,
    ) -> PromptState {
        var told = told
        switch tool {
        // The todo list is drawn from the store by the app, so a call that
        // changed it tells the model nothing it does not already read back.
        case .todoList, .todoWrite:
            return told
        case .memorySave:
            guard let memory = now.memory else { return told }
            // an empty id is a new record, as the tool reads it
            let id = arguments.argString("id").flatMap { $0.isEmpty ? nil : $0 }
            let title = arguments.argString("title")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let known = Set((told.memory ?? []).map(\.id))
            // A new record kept for another project is not one this chat
            // sees: one of its title here was made by someone else.
            let named = arguments.argNonEmptyString("project")?.trimmingCharacters(in: .whitespaces)
            let elsewhere = named.map { $0 != project.id && $0 != project.name.rawValue } ?? false
            let global = arguments.argString("scope") == "global"
            let made = { (record: MemoryRecord) in
                id == nil && record.title == title && !known.contains(record.id)
                    && (global ? record.projectID == nil : !elsewhere && record.projectID != nil)
            }
            let saved = memory.filter { $0.id == id || made($0) }
            var records = told.memory ?? []
            for record in saved {
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index] = record
                } else {
                    records.append(record)
                }
            }
            told.memory = records
        case .memoryDelete:
            guard let id = arguments.argString("id") else { return told }
            told.memory?.removeAll { $0.id == id }
        case .skillSave:
            guard let name = arguments.argString("name"), let skill = now.skills.first(where: { $0.name == name }) else { return told }
            if let index = told.skills.firstIndex(where: { $0.name == name }) {
                told.skills[index] = skill
            } else {
                told.skills.append(skill)
            }
        case .skillRemove:
            guard let name = arguments.argString("name"), !now.skills.contains(where: { $0.name == name }) else { return told }
            told.skills.removeAll { $0.name == name }
        default:
            break
        }
        return told
    }
}
