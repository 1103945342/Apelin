import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("ChannelHostBackend's tags, stashes and paths")
struct GitWorktreeBackendTests {
    @Test
    func `every call lands on its operation with the arguments it was given`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.gitTagCreate, reply: GitTagCreateResponse(name: "v1.0.0"))
        fixture.host.on(.gitTagDelete, reply: GitTagDeleteResponse())
        fixture.host.on(.gitStashList, reply: GitStashListResponse(stashes: []))
        fixture.host.on(.gitStashSave, reply: GitStashSaveResponse(saved: true))
        fixture.host.on(.gitStashApply, reply: GitStashApplyResponse(conflicts: ["a.swift"]))
        fixture.host.on(.gitStashDrop, reply: GitStashDropResponse())
        fixture.host.on(.gitStashClear, reply: GitStashClearResponse())
        fixture.host.on(.gitRestore, reply: GitRestoreResponse())
        fixture.host.on(.gitDeletePaths, reply: GitDeletePathsResponse())

        let context = fixture.context()
        let made = try await fixture.backend.gitTag(GitTagToolRequest(
            context: context, action: .create, name: "v1.0.0", commit: "HEAD~1", message: "First",
        ))
        _ = try await fixture.backend.gitTag(GitTagToolRequest(context: context, action: .delete, name: "v1.0.0"))
        _ = try await fixture.backend.gitStash(GitStashToolRequest(context: context, action: .list))
        let saved = try await fixture.backend.gitStash(GitStashToolRequest(
            context: context, action: .save, message: "wip", includeUntracked: true,
        ))
        let applied = try await fixture.backend.gitStash(GitStashToolRequest(
            context: context, action: .apply, index: 2, pop: true,
        ))
        _ = try await fixture.backend.gitStash(GitStashToolRequest(context: context, action: .drop, index: 1))
        _ = try await fixture.backend.gitStash(GitStashToolRequest(context: context, action: .clear))
        _ = try await fixture.backend.gitRestore(GitRestoreToolRequest(
            context: context, source: .index, paths: ["a.swift"],
        ))
        _ = try await fixture.backend.gitClean(GitCleanToolRequest(context: context, paths: ["build"]))

        #expect(fixture.host.requests.map(\.operation) == [
            .gitTagCreate, .gitTagDelete, .gitStashList, .gitStashSave, .gitStashApply,
            .gitStashDrop, .gitStashClear, .gitRestore, .gitDeletePaths,
        ])
        struct Scoped: Decodable { var projectID: String }
        for request in fixture.host.requests {
            let scope = try JSONCoding.decode(Scoped.self, from: request.payload)
            #expect(scope.projectID == fixture.project.id)
        }
        let create = try #require(fixture.host.requests(GitTagCreateRequest.self).first)
        #expect(create.name == "v1.0.0" && create.commit == "HEAD~1" && create.message == "First")
        let save = try #require(fixture.host.requests(GitStashSaveRequest.self).first)
        #expect(save.message == "wip" && save.includeUntracked)
        let apply = try #require(fixture.host.requests(GitStashApplyRequest.self).first)
        #expect(apply.index == 2 && apply.pop)
        let drop = try #require(fixture.host.requests(GitStashDropRequest.self).first)
        #expect(drop.index == 1)
        let restore = try #require(fixture.host.requests(GitRestoreRequest.self).first)
        #expect(restore.paths == ["a.swift"] && restore.source == .index)
        #expect(fixture.host.requests(GitDeletePathsRequest.self).first?.paths == ["build"])
        #expect(made.name == "v1.0.0")
        #expect(saved.saved)
        #expect(applied.conflicts == ["a.swift"])
    }
}
