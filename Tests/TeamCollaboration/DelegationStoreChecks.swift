import Foundation

@main
struct DelegationStoreChecks {
    static func main() async throws {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = scratch.appendingPathComponent("authority")
        let project = scratch.appendingPathComponent("project")
        try fm.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let child = UUID().uuidString, opener = UUID().uuidString, stranger = UUID().uuidString
        let step = AgentDelegationBrief.Step(id: "edit", title: "Edit", writeRoots: ["Sources"], capabilities: [.fileWrite])
        let brief = AgentDelegationBrief(objective: "Bounded change", acceptance: ["Reviewed"], steps: [step])
        let store = AgentDelegationStore(directory: directory)
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            count += 1
        }
        func denied(_ label: String, _ body: () async throws -> Void) async {
            do { try await body(); fatalError("allowed: \(label)") }
            catch { count += 1 }
        }
        let plan = try await store.register(child: child, opener: opener, projectID: "project", brief: brief)
        check(plan.revision == 1, "initial authority")
        let restarted = AgentDelegationStore(directory: directory)
        check(try await restarted.record(child)?.plan == plan, "restart retains authority")
        await denied("duplicate registration") { _ = try await store.register(child: child, opener: opener, projectID: "project", brief: brief) }
        await denied("stranger cannot read") { _ = try await store.apply(.init(sessionID: child, action: .read), caller: stranger) }
        await denied("child cannot amend") { _ = try await store.apply(.init(sessionID: child, action: .amend, expectedRevision: 1, step: step), caller: child) }
        await denied("child cannot accept") { _ = try await store.apply(.init(sessionID: child, action: .accept, expectedRevision: 1), caller: child) }
        await denied("stale tool revision") { _ = try await store.apply(.init(sessionID: child, action: .admit, expectedRevision: 0, tool: "file_edit", path: "Sources/a"), caller: child) }
        await denied("scope prefix escape") { _ = try await store.apply(.init(sessionID: child, action: .admit, expectedRevision: 1, tool: "file_edit", path: "SourcesOther/a"), caller: child) }
        for tool in ["shell_run", "apelin_project_build", "git_commit", "apelin_package_install", "apelin_conversation_create", "unknown_plugin"] {
            await denied("unsupported \(tool)") { _ = try await store.apply(.init(sessionID: child, action: .admit, expectedRevision: 1, tool: tool), caller: child) }
        }
        _ = try await store.apply(.init(sessionID: child, action: .admit, expectedRevision: 1, tool: "file_read"), caller: child)
        count += 1
        await denied("unsupported check does not certify") { _ = try await store.apply(.init(sessionID: child, action: .check, expectedRevision: 1), caller: child) }
        check(try await store.record(child)?.plan == plan, "denials do not change plan")
        let brokenWriter = AgentDelegationStore(directory: directory, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        await denied("failed write is not acknowledged") { _ = try await brokenWriter.apply(.init(sessionID: child, action: .blocked, expectedRevision: 1), caller: child) }
        check(try await restarted.record(child)?.plan == plan, "failed write retains durable plan")
        let blocked = try await store.apply(.init(sessionID: child, action: .blocked, expectedRevision: 1), caller: child).plan!
        await denied("blocked denies writes") { _ = try await store.apply(.init(sessionID: child, action: .admit, expectedRevision: blocked.revision, tool: "file_write", path: "Sources/a"), caller: child) }
        let amended = try await store.apply(.init(sessionID: child, action: .amend, expectedRevision: blocked.revision, step: step), caller: opener).plan!
        await denied("approval for old revision") { _ = try await store.apply(.init(sessionID: child, action: .admit, expectedRevision: 1, tool: "file_edit", path: "Sources/a"), caller: child) }
        let review = try await store.apply(.init(sessionID: child, action: .review, expectedRevision: amended.revision), caller: child).plan!
        let accepted = try await store.apply(.init(sessionID: child, action: .accept, expectedRevision: review.revision), caller: opener).plan!
        check(accepted.currentStep == nil && accepted.statuses == [.unverified], "opener acceptance does not invent verification")
        try AgentDelegationPath.validate("Sources/new.swift", projectRoot: project.path)
        count += 1
        try fm.createSymbolicLink(at: project.appendingPathComponent("linked"), withDestinationURL: project.appendingPathComponent("Sources"))
        for path in ["linked/a", "Sources/../escape", ".git/config", "Sources/.git/config", "/tmp/file"] {
            await denied("invalid path \(path)") { try AgentDelegationPath.validate(path, projectRoot: project.path) }
        }
        let file = directory.appendingPathComponent(child + ".json")
        let corrupt = Data("broken authority".utf8)
        try corrupt.write(to: file)
        await denied("corrupt authority fails closed") { _ = try await store.record(child) }
        check(try Data(contentsOf: file) == corrupt, "corrupt bytes preserved")
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: project)
        await denied("authority symlink refused") { _ = try await store.record(child) }
        print("\(count) delegation store checks passed")
    }
}
