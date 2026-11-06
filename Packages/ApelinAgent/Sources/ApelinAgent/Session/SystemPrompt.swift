import Foundation
import KWWKAgent

enum SystemPrompt {
    /// Project instructions are read from the first of these at the
    /// project's root, as pi and kwwk read them from the working directory.
    static let instructionFiles = ["AGENTS.md", "CLAUDE.md"]
    static let maxInstructionBytes = 16 * 1024

    static func make(
        project: ProjectIdentity,
        projectRoot: String,
        skills: [SkillDocument],
        mcpServers: [MCPServerConfiguration],
        projectInstructions: ProjectInstructions? = nil,
        buildSystem: ProjectBuildSystem = .apelin,
        memory: String = "",
        environment: String = "",
    ) -> String {
        // The text is Prompts/*.md, compiled in as SystemPromptText by
        // Scripts/embed-prompts.py; the order here is the prompt's.
        var sections = [
            SystemPromptText.identity(projectName: project.name.rawValue, projectRoot: projectRoot),
            SystemPromptText.responses,
            SystemPromptText.working(
                parallelToolCalls: parallelToolCallsGuideline.trimmingCharacters(in: .whitespacesAndNewlines),
                renamedTools: renamedToolsNote,
            ),
            SystemPromptText.device,
        ]
        if project.isTemporary {
            sections.append(SystemPromptText.generalChat)
        }
        sections.append(conversationsSection)
        if buildSystem == .external {
            sections.append(SystemPromptText.workspace)
        }
        sections.append(approvalModesSection)
        if !environment.isEmpty {
            sections.append(environment)
        }
        if let projectInstructions {
            sections.append(SystemPromptText.projectInstructions(
                file: projectInstructions.file,
                text: projectInstructions.text,
            ))
        }
        if !mcpServers.isEmpty {
            let list = mcpServers.map { "- \($0.name)\($0.description.map { ": \($0)" } ?? "")" }
                .joined(separator: "\n")
            sections.append("# MCP servers\nTools named mcp__<server>__<tool> come from these servers and always ask in Strict mode:\n\(list)")
        }
        let skillSection = SkillCatalog.promptSection(skills)
        if !skillSection.isEmpty {
            sections.append(skillSection)
        }
        if !memory.isEmpty {
            sections.append(memory)
        }
        return sections.joined(separator: "\n\n")
    }

    /// Project instructions, memories and skills written before the tools
    /// were renamed (`AgentToolName.legacyNames`) still name them the old
    /// way; nothing rewrites them.
    static let renamedToolsNote = "Notes written before Apelin renamed its tools (project instructions, memories, skills) may use the old names, such as run_code, write_file or build: use the tool of the same purpose here."

    /// How a chat works with other conversations, of its project or another.
    static let conversationsSection = SystemPromptText.conversations

    /// What each approval mode lets through. Which one is on is a fact of
    /// the message (`SystemState`), so a switch changes no byte of the
    /// prompt; the host enforces the mode whatever the model reads.
    static let approvalModesSection = SystemPromptText.approvalModes

    /// The project's own instructions, read again for every prompt so an
    /// edit applies to the next one. Only a regular file inside the project
    /// counts; a link out of it is not followed.
    static func projectInstructions(in root: ScopedRoot) -> ProjectInstructions? {
        for file in instructionFiles {
            guard let path = try? root.resolveExisting(file),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: maxInstructionBytes + 1)) ?? Data()
            var text = String(decoding: data.prefix(maxInstructionBytes), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if data.count > maxInstructionBytes {
                text += "\n… (truncated)"
            }
            return ProjectInstructions(file: file, text: text)
        }
        return nil
    }
}

struct ProjectInstructions: Sendable, Equatable {
    var file: String
    var text: String
}
