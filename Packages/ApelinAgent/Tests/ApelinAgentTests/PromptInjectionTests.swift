@testable import ApelinAgent
import Foundation
import Testing

/// The reader's injected instructions (Settings ▸ Agent ▸ Prompt Injection)
/// for a conversation that is already open. A session's system prompt is the
/// bytes it opened with, so turning the switch on or off reaches the model as
/// a delta in the next message, as every other change to the prompt does.
@Suite("Injected instructions")
struct PromptInjectionTests {
    private static func state(_ home: TemporaryHome, injected: String) throws -> PromptState {
        var configuration = AgentSessionConfiguration(
            project: home.project,
            provider: .githubCopilot(model: "m"),
            approval: ApprovalPolicy(mode: .confirm),
            dataRoot: home.dataRoot,
        )
        configuration.promptInjection = injected
        return PromptState.read(configuration, root: try ScopedRoot(home.projectURL), skills: [])
    }

    @Test
    func `turning injection on reaches a session already open, and turning it off withdraws it`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let off = try Self.state(home, injected: "")
        let on = try Self.state(home, injected: "Always answer in Chinese.")

        let turnedOn = try #require(on.changes(since: off).first)
        #expect(turnedOn.contains("take precedence"), "\(turnedOn)")
        #expect(turnedOn.hasSuffix("Always answer in Chinese."), "\(turnedOn)")
        #expect(on.changes(since: off).count == 1, "nothing else changed with it")

        let turnedOff = try #require(off.changes(since: on).first)
        #expect(turnedOff.contains("no longer apply"), "\(turnedOff)")
        #expect(!turnedOff.contains("Always answer in Chinese."), "the withdrawn text is not quoted as in force")

        #expect(off.changes(since: off).isEmpty, "the same setting says nothing")
        #expect(on.changes(since: on).isEmpty, "and neither does a text it already has")
    }

    @Test
    func `whitespace alone is no change, and an edit names the new text`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let on = try Self.state(home, injected: "Always answer in Chinese.")
        let padded = try Self.state(home, injected: "\n  Always answer in Chinese.  \n")
        #expect(padded.changes(since: on).isEmpty, "the same instructions with spaces around them")

        let edited = try Self.state(home, injected: "Always answer in Chinese, and name the file.")
        let changed = try #require(edited.changes(since: on).first)
        #expect(changed.contains("changed"), "\(changed)")
        #expect(changed.hasSuffix("Always answer in Chinese, and name the file."), "\(changed)")
    }

    @Test
    func `instructions longer than the delta's budget are quoted whole`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let on = try Self.state(home, injected: "Be brief.")
        // The other sources are cut to `maximumDelta` and left to be read
        // again; these cannot be, since no tool reads them back.
        let long = String(repeating: "Follow the palette. ", count: 400)
        #expect(long.count > PromptState.maximumDelta)
        let changed = try Self.state(home, injected: long)
        let line = try #require(changed.changes(since: on).first)
        #expect(line.contains(long), "the delta carries every character")
    }
}
