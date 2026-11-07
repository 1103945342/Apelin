@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

extension MockBackend {
    func gitBranches(_: GitBranchesToolRequest) -> GitBranchesResponse {
        calls.append(.other("gitBranches"))
        return GitBranchesResponse(current: "main")
    }

    func gitBranchCreate(_ request: GitBranchCreateToolRequest) -> GitBranchCreateResponse {
        calls.append(.other("gitBranchCreate \(request.name)"))
        return GitBranchCreateResponse(name: request.name)
    }

    func gitBranchCheckout(_ request: GitBranchCheckoutToolRequest) -> GitBranchCheckoutResponse {
        calls.append(.other("gitBranchCheckout \(request.name)"))
        return GitBranchCheckoutResponse(branch: request.name)
    }

    func gitBranchRename(_ request: GitBranchRenameToolRequest) -> GitBranchRenameResponse {
        calls.append(.other("gitBranchRename \(request.from) \(request.to)"))
        return GitBranchRenameResponse(name: request.to)
    }

    func gitMerge(_ request: GitMergeToolRequest) -> GitMergeResponse {
        calls.append(.other("gitMerge \(request.branch)"))
        return GitMergeResponse(outcome: .conflict, conflicts: ["Sources/Tweak.m"])
    }

    func gitMergeAbort(_: GitMergeAbortToolRequest) -> GitMergeAbortResponse {
        calls.append(.other("gitMergeAbort"))
        return GitMergeAbortResponse()
    }

    func gitLog(_ request: GitLogToolRequest) -> GitLogResponse {
        calls.append(.other("gitLog \(request.limit) \(request.skip)"))
        return GitLogResponse()
    }

    func gitCommitDetail(_ request: GitCommitDetailToolRequest) -> GitCommitDetailResponse {
        calls.append(.other("gitCommitDetail \(request.commit)"))
        return GitCommitDetailResponse(id: request.commit, message: "test", authorName: "Ada", authorEmail: "ada@example.com", authoredAt: 0)
    }
}

@Suite("Agent branch and merge tools")
struct GitBranchToolTests {
    static let writes: [(AgentToolName, JSONValue)] = [
        (.gitBranchCreate, ["name": "feature", "start_point": "HEAD", "checkout": true]),
        (.gitBranchCheckout, ["name": "main"]),
        (.gitBranchRename, ["from": "feature", "to": "reviewed"]),
        (.gitMerge, ["branch": "reviewed", "no_fast_forward": true]),
        (.gitMergeAbort, [:]),
    ]

    @Test
    func `all eight tools are project only and reads are preset`() {
        for tool in [AgentToolName.gitBranches, .gitLog, .gitCommitDetail] {
            #expect(tool.isProjectOnly)
            #expect(tool.risk == .readOnly)
            #expect(ApprovalPresets.default.readTools.contains(tool))
        }
        for (tool, _) in Self.writes {
            #expect(tool.isProjectOnly)
            #expect(tool.risk == .writeProject)
        }
    }

    @Test
    func `Strict asks for every mutation and offers no session grant`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        for (tool, arguments) in Self.writes {
            for _ in 0 ..< 2 {
                let (_, asked) = try await harness.run(tool, arguments)
                #expect(asked.count == 1)
                #expect(asked.first?.allowsSessionScope == false)
            }
        }
        #expect(await harness.backend.calls.count == 10)
    }

    @Test
    func `denial never reaches a branch mutation`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        for (tool, arguments) in Self.writes {
            await #expect(throws: ToolDeniedError.self) {
                _ = try await harness.run(tool, arguments, answering: .deny(reason: "not now"))
            }
        }
        #expect(await harness.backend.calls.isEmpty)
    }

    @Test
    func `relaxed and full do not ask for branch mutations`() async throws {
        for mode: ApprovalMode in [.relaxed, .full] {
            let harness = try DigestApprovalTests.Harness(mode: mode)
            defer { harness.home.remove() }
            for (tool, arguments) in Self.writes {
                let (_, asked) = try await harness.run(tool, arguments)
                #expect(asked.isEmpty)
            }
        }
    }

    @Test
    func `history reads reach the backend without asking`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        #expect(try await harness.run(.gitBranches, [:]).1.isEmpty)
        #expect(try await harness.run(.gitLog, ["limit": 3, "skip": 2]).1.isEmpty)
        #expect(try await harness.run(.gitCommitDetail, ["commit": "HEAD~1"]).1.isEmpty)
        #expect(await harness.backend.calls == [.other("gitBranches"), .other("gitLog 3 2"), .other("gitCommitDetail HEAD~1")])
    }

    @Test
    func `invalid names revisions and pagination stop before approval`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let invalid: [(AgentToolName, JSONValue)] = [
            (.gitBranchCreate, ["name": "../bad"]),
            (.gitBranchCreate, ["name": "feature", "start_point": "--all"]),
            (.gitBranchCheckout, ["name": "main", "remote": "https://example.com/repo"]),
            (.gitBranchRename, ["from": "main", "to": "-bad"]),
            (.gitMerge, ["branch": "HEAD\nmain"]),
            (.gitCommitDetail, ["commit": "--all"]),
            (.gitLog, ["limit": 0]),
            (.gitLog, ["limit": 1001]),
            (.gitLog, ["skip": -1]),
        ]
        for (tool, arguments) in invalid {
            await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(tool, arguments) }
        }
        #expect(await harness.backend.calls.isEmpty)
        #expect(await harness.events.events.isEmpty)
    }
}
