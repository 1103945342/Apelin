@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

extension MockBackend {
    func gitBranchDelete(_ request: GitBranchDeleteToolRequest) -> GitBranchDeleteResponse {
        let place = request.remote ?? "local"
        calls.append(.other("gitBranchDelete \(request.name) \(place) force=\(request.force)"))
        return GitBranchDeleteResponse()
    }
}

@Suite("Agent branch deletion")
struct GitBranchDeleteToolTests {
    static let tool = AgentToolName.gitBranchDelete

    @Test
    func `a deletion is a project tool that can lose refs`() {
        #expect(Self.tool.isProjectOnly)
        #expect(Self.tool.risk == .system)
    }

    @Test
    func `every mode asks, once per call, and offers no session grant`() async throws {
        for mode: ApprovalMode in [.relaxed, .confirm, .full] {
            let harness = try DigestApprovalTests.Harness(mode: mode)
            defer { harness.home.remove() }
            for _ in 0 ..< 2 {
                let (_, asked) = try await harness.run(Self.tool, ["name": "feature", "remote": "origin"])
                #expect(asked.count == 1)
                #expect(asked.first?.allowsSessionScope == false)
            }
            #expect(await harness.backend.calls.count == 2)
        }
    }

    @Test
    func `the card names the branch and the remote`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (_, asked) = try await harness.run(Self.tool, ["name": "feature", "remote": "origin"])
        let reason = try #require(asked.first?.reason)
        #expect(reason.contains("feature"))
        #expect(reason.contains("origin"))
    }

    @Test
    func `a forced local deletion says what goes with it`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (_, forced) = try await harness.run(Self.tool, ["name": "spike", "force": true])
        let forcedReason = try #require(forced.first?.reason)
        #expect(forcedReason.contains("spike"))
        #expect(forcedReason.contains("goes with it"))
        let (_, plain) = try await harness.run(Self.tool, ["name": "spike"])
        let plainReason = try #require(plain.first?.reason)
        #expect(!plainReason.contains("goes with it"))
    }

    @Test
    func `force and the remote reach the backend`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        _ = try await harness.run(Self.tool, ["name": "spike", "force": true])
        _ = try await harness.run(Self.tool, ["name": "old", "remote": "upstream"])
        #expect(await harness.backend.calls == [
            .other("gitBranchDelete spike local force=true"),
            .other("gitBranchDelete old upstream force=false"),
        ])
    }

    @Test
    func `denial never reaches the backend`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await #expect(throws: ToolDeniedError.self) {
            _ = try await harness.run(Self.tool, ["name": "feature"], answering: .deny(reason: "keep it"))
        }
        #expect(await harness.backend.calls.isEmpty)
    }

    @Test
    func `an invalid name or remote stops before approving`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let invalid: [JSONValue] = [
            ["name": "../bad"],
            ["name": "main", "remote": "https://example.com/repo"],
            ["name": "-bad"],
        ]
        for arguments in invalid {
            await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(Self.tool, arguments) }
        }
        #expect(await harness.backend.calls.isEmpty)
        #expect(await harness.events.events.isEmpty)
    }
}
