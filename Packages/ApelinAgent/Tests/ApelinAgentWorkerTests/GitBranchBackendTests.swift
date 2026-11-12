import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("ChannelHostBackend's branches and merges")
struct GitBranchBackendTests {
    @Test
    func `all calls use the worker project and preserve their arguments`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitBranches, reply: GitBranchesResponse(current: "main"))
        fixture.host.on(.gitBranchCreate, reply: GitBranchCreateResponse(name: "feature"))
        fixture.host.on(.gitBranchCheckout, reply: GitBranchCheckoutResponse(branch: "main"))
        fixture.host.on(.gitBranchDelete, reply: GitBranchDeleteResponse())
        fixture.host.on(.gitBranchRename, reply: GitBranchRenameResponse(name: "reviewed"))
        fixture.host.on(.gitMerge, reply: GitMergeResponse(outcome: .conflict, conflicts: ["source.m"]))
        fixture.host.on(.gitMergeAbort, reply: GitMergeAbortResponse())
        fixture.host.on(.gitLog, reply: GitLogResponse(hasMore: true))
        fixture.host.on(.gitCommitDetail, reply: GitCommitDetailResponse(id: "abc", message: "test", authorName: "Ada", authorEmail: "ada@example.com", authoredAt: 0))
        var context = fixture.context()
        context.project.id = "forged-project"
        let branches = try await fixture.backend.gitBranches(GitBranchesToolRequest(context: context))
        _ = try await fixture.backend.gitBranchCreate(GitBranchCreateToolRequest(context: context, name: "feature", startPoint: "HEAD~1", checkout: true))
        _ = try await fixture.backend.gitBranchCheckout(GitBranchCheckoutToolRequest(context: context, name: "main", remote: "origin"))
        _ = try await fixture.backend.gitBranchDelete(GitBranchDeleteToolRequest(context: context, name: "old", remote: "origin", force: true))
        _ = try await fixture.backend.gitBranchRename(GitBranchRenameToolRequest(context: context, from: "feature", to: "reviewed"))
        let merged = try await fixture.backend.gitMerge(GitMergeToolRequest(context: context, branch: "reviewed", noFastForward: true))
        _ = try await fixture.backend.gitMergeAbort(GitMergeAbortToolRequest(context: context))
        let history = try await fixture.backend.gitLog(GitLogToolRequest(context: context, limit: 7, skip: 14))
        _ = try await fixture.backend.gitCommitDetail(GitCommitDetailToolRequest(context: context, commit: "HEAD~1"))
        #expect(fixture.host.requests.map(\.operation) == [.gitBranches, .gitBranchCreate, .gitBranchCheckout, .gitBranchDelete, .gitBranchRename, .gitMerge, .gitMergeAbort, .gitLog, .gitCommitDetail])
        struct Scoped: Decodable { var projectID: String }
        for request in fixture.host.requests {
            let scope = try JSONCoding.decode(Scoped.self, from: request.payload)
            #expect(scope.projectID == fixture.project.id)
        }
        let create = try #require(fixture.host.requests(GitBranchCreateRequest.self).first)
        #expect(create.name == "feature" && create.startPoint == "HEAD~1" && create.checkout)
        let checkout = try #require(fixture.host.requests(GitBranchCheckoutRequest.self).first)
        #expect(checkout.name == "main" && checkout.remote == "origin")
        let deletion = try #require(fixture.host.requests(GitBranchDeleteRequest.self).first)
        #expect(deletion.name == "old" && deletion.remote == "origin" && deletion.force == true)
        let rename = try #require(fixture.host.requests(GitBranchRenameRequest.self).first)
        #expect(rename.from == "feature" && rename.to == "reviewed")
        let merge = try #require(fixture.host.requests(GitMergeRequest.self).first)
        #expect(merge.branch == "reviewed" && merge.noFastForward)
        let log = try #require(fixture.host.requests(GitLogRequest.self).first)
        #expect(log.limit == 7 && log.skip == 14)
        #expect(fixture.host.requests(GitCommitDetailRequest.self).first?.commit == "HEAD~1")
        #expect(branches.current == "main")
        #expect(merged.outcome == .conflict && merged.conflicts == ["source.m"])
        #expect(history.hasMore)
    }
}
