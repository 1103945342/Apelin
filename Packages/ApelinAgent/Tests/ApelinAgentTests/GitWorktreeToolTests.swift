@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

extension MockBackend {
    func gitTag(_ request: GitTagToolRequest) -> GitTagToolResponse {
        calls.append(.other("gitTag \(request.action.rawValue) \(request.name)"))
        return GitTagToolResponse(name: request.name)
    }

    func gitStash(_ request: GitStashToolRequest) -> GitStashToolResponse {
        calls.append(.other("gitStash \(request.action.rawValue) \(request.index)"))
        return GitStashToolResponse()
    }

    func gitRestore(_ request: GitRestoreToolRequest) -> GitRestoreResponse {
        calls.append(.other("gitRestore \(request.source.rawValue) \(request.paths.joined(separator: ","))"))
        return GitRestoreResponse()
    }

    func gitClean(_ request: GitCleanToolRequest) -> GitDeletePathsResponse {
        calls.append(.other("gitClean \(request.paths.joined(separator: ","))"))
        return GitDeletePathsResponse()
    }
}

@Suite("Agent tags, stashes and discarded paths")
struct GitWorktreeToolTests {
    static let discarding: [(AgentToolName, JSONValue)] = [
        (.gitTag, ["action": "create", "name": "v1.0.0", "message": "First"]),
        (.gitTag, ["action": "delete", "name": "v1.0.0"]),
        (.gitStash, ["action": "save", "message": "wip"]),
        (.gitRestore, ["paths": ["Sources/Tweak.m"]]),
        (.gitClean, ["paths": ["build/output.o"]]),
    ]

    @Test
    func `they are project tools with the risk their work carries`() {
        for tool in [AgentToolName.gitTag, .gitStash, .gitRestore, .gitClean] {
            #expect(tool.isProjectOnly)
        }
        #expect(AgentToolName.gitTag.risk == .writeProject)
        #expect(AgentToolName.gitStash.risk == .writeProject)
        #expect(AgentToolName.gitRestore.risk == .system)
        #expect(AgentToolName.gitClean.risk == .system)
    }

    @Test
    func `Strict asks for every change, and a stash list changes nothing`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        for (tool, arguments) in Self.discarding {
            let (_, asked) = try await harness.run(tool, arguments)
            #expect(asked.count == 1)
            #expect(asked.first?.allowsSessionScope == false)
        }
        let (_, listed) = try await harness.run(.gitStash, ["action": "list"])
        #expect(listed.isEmpty)
        #expect(await harness.backend.calls.count == Self.discarding.count + 1)
    }

    @Test
    func `a discarded path asks in every mode`() async throws {
        for mode: ApprovalMode in [.relaxed, .full, .confirm] {
            let harness = try DigestApprovalTests.Harness(mode: mode)
            defer { harness.home.remove() }
            let (_, asked) = try await harness.run(.gitRestore, ["paths": ["Sources/Tweak.m"]])
            #expect(asked.count == 1)
            let reason = try #require(asked.first?.reason)
            #expect(reason.contains("Sources/Tweak.m"))
        }
    }

    @Test
    func `arguments reach the backend as written`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        _ = try await harness.run(.gitTag, ["action": "create", "name": "v2", "commit": "HEAD~1"])
        _ = try await harness.run(.gitStash, ["action": "apply", "index": 2, "pop": true])
        _ = try await harness.run(.gitRestore, ["paths": ["a.swift", "b.swift"], "source": "index"])
        _ = try await harness.run(.gitClean, ["paths": ["tmp"]])
        #expect(await harness.backend.calls == [
            .other("gitTag create v2"),
            .other("gitStash apply 2"),
            .other("gitRestore index a.swift,b.swift"),
            .other("gitClean tmp"),
        ])
    }

    @Test
    func `a tag on a remote asks in every mode and names it`() async throws {
        for mode: ApprovalMode in [.relaxed, .full, .confirm] {
            let harness = try DigestApprovalTests.Harness(mode: mode)
            defer { harness.home.remove() }
            let (_, asked) = try await harness.run(
                .gitTag,
                ["action": "create", "name": "v1.0.0", "remote": "origin"],
            )
            #expect(asked.count == 1)
            let reason = try #require(asked.first?.reason)
            #expect(reason.contains("v1.0.0") && reason.contains("origin"))
        }
    }

    @Test
    func `a tag deletion on a remote says it cannot be brought back`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (_, asked) = try await harness.run(.gitTag, ["action": "delete", "name": "v1", "remote": "origin"])
        let reason = try #require(asked.first?.reason)
        #expect(reason.contains("v1") && reason.contains("origin"))
        #expect(reason.contains("bring"))
    }

    @Test
    func `bad arguments stop before approval`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let invalid: [(AgentToolName, JSONValue)] = [
            (.gitTag, ["action": "rename", "name": "v1"]),
            (.gitTag, ["action": "create", "name": "../bad"]),
            (.gitStash, ["action": "list", "index": -1]),
            (.gitRestore, ["paths": []]),
            (.gitClean, ["paths": []]),
            (.gitRestore, ["paths": ["a.swift"], "source": "elsewhere"]),
        ]
        for (tool, arguments) in invalid {
            await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(tool, arguments) }
        }
        #expect(await harness.backend.calls.isEmpty)
    }
}
