import Foundation

@main
struct BriefChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
        }
        func denies(_ name: String, _ body: () throws -> Void) {
            do { try body(); fatalError("Allowed: \(name)") }
            catch let error as AgentDelegationViolation {
                check(error.errorDescription?.contains("Step ") == true, name)
            } catch { fatalError("Unexpected error: \(error)") }
        }
        let first = AgentDelegationBrief.Step(id: "edit", title: "Edit", writeRoots: ["Sources"],
                                              capabilities: [.fileWrite], checkID: "syntax")
        let second = AgentDelegationBrief.Step(id: "review", title: "Review")
        let brief = AgentDelegationBrief(objective: "Make a verified change", acceptance: ["Syntax check passes"], steps: [first, second])
        let plan = try AgentDelegationPlan(brief: brief)
        try plan.authorize(.fileWrite, canonicalRelativePath: "Sources/File.swift", expectedRevision: 1)
        check(plan.currentStep?.id == "edit", "first step is current")
        denies("prefix is not subtree") { try plan.authorize(.fileWrite, canonicalRelativePath: "SourcesOther/file", expectedRevision: 1) }
        denies("parent escape") { try plan.authorize(.fileWrite, canonicalRelativePath: "Sources/../Other", expectedRevision: 1) }
        denies("absolute path") { try plan.authorize(.fileWrite, canonicalRelativePath: "/Sources/file", expectedRevision: 1) }
        denies("unlisted capability") { try plan.authorize(.install, expectedRevision: 1) }
        denies("stale request") { try plan.authorize(.fileWrite, canonicalRelativePath: "Sources/file", expectedRevision: 0) }
        denies("cannot self-review a checked step") { _ = try plan.requestReview(expectedRevision: 1) }
        denies("cannot skip unchecked work") { _ = try plan.accepted(expectedRevision: 1) }
        denies("wrong check adapter") { _ = try plan.checked(adapterID: "different", exitCode: 0, expectedRevision: 1) }
        let failed = try plan.checked(adapterID: "syntax", exitCode: 1, expectedRevision: 1)
        check(failed == plan, "failed check does not advance")
        let verified = try plan.checked(adapterID: "syntax", exitCode: 0, expectedRevision: 1)
        check(verified.currentIndex == 0 && verified.statuses[0] == .verified, "each gate keeps pointer")
        denies("finished step cannot write") { try verified.authorize(.fileWrite, canonicalRelativePath: "Sources/file", expectedRevision: verified.revision) }
        denies("old check receipt") { _ = try verified.checked(adapterID: "syntax", exitCode: 0, expectedRevision: 1) }
        let released = try verified.accepted(expectedRevision: verified.revision)
        check(released.currentStep?.id == "review", "only opener release moves each gate")
        let ready = try released.requestReview(expectedRevision: released.revision)
        let ended = try ready.accepted(expectedRevision: ready.revision)
        check(ended.currentStep == nil && ended.statuses == [.verified, .unverified], "unchecked acceptance stays unverified")
        denies("cannot release completed assignment again") { _ = try ended.accepted(expectedRevision: ended.revision) }
        let blocked = try plan.blocked(expectedRevision: 1)
        denies("blocked denies mutation") { try blocked.authorize(.fileWrite, canonicalRelativePath: "Sources/file", expectedRevision: blocked.revision) }
        let amended = try blocked.amendingCurrent(first, expectedRevision: blocked.revision)
        try amended.authorize(.fileWrite, canonicalRelativePath: "Sources/file", expectedRevision: amended.revision)
        check(amended.revision > blocked.revision, "amendment reopens with fresh revision")
        // A step that changes what "done" means restates the acceptance in the
        // same amendment; an empty one is refused like any other brief.
        let restated = try amended.amendingCurrent(
            first,
            acceptance: ["The new evidence is checked"],
            expectedRevision: amended.revision
        )
        check(restated.brief.acceptance == ["The new evidence is checked"],
              "an amendment can restate the acceptance")
        check(restated.revision == amended.revision + 1, "restating acceptance is a new revision")
        check(restated.brief.objective == amended.brief.objective,
              "an amendment keeps the objective")
        denies("an amendment keeps acceptance nonempty") {
            _ = try restated.amendingCurrent(first, acceptance: [], expectedRevision: restated.revision)
        }
        denies("late receipt cannot certify amended step") { _ = try amended.checked(adapterID: "syntax", exitCode: 0, expectedRevision: 1) }
        var automaticBrief = brief
        automaticBrief.gates = .end
        var repeated = first
        repeated.id = "second-edit"
        automaticBrief.steps = [first, repeated]
        let automatic = try AgentDelegationPlan(brief: automaticBrief)
        let advanced = try automatic.checked(adapterID: "syntax", exitCode: 0, expectedRevision: 1)
        check(advanced.currentIndex == 1 && advanced.revision == 2, "end gate advances with new revision")
        denies("same adapter old receipt cannot finish next step") { _ = try advanced.checked(adapterID: "syntax", exitCode: 0, expectedRevision: 1) }
        for path in ["", "/", ".", "../x", "a//b", "a/*", "a/./b", "a\0b", "a\\b"] {
            check(!AgentDelegationBrief.validRelativePath(path), "reject \(path)")
        }
        check(AgentDelegationBrief.validRelativePath("目录/文件.swift"), "unicode relative path")
        // A subtree spelled with its slash names the same root, not another one.
        check(AgentDelegationBrief.validRelativePath("Notes/"), "a trailing slash is the same root")
        check(AgentDelegationBrief.Step(id: "s", title: "S", writeRoots: ["Notes/"]).writeRoots == ["Notes"],
              "a write root is kept in one form")
        let slashed = try AgentDelegationPlan(brief: AgentDelegationBrief(
            objective: "Write notes", acceptance: ["A note exists"],
            steps: [AgentDelegationBrief.Step(id: "notes", title: "Notes", writeRoots: ["Notes/"],
                                              capabilities: [.fileWrite])]
        ))
        try slashed.authorize(.fileWrite, canonicalRelativePath: "Notes/a.md", expectedRevision: 1)
        denies("a slashed root still bounds its subtree") {
            try slashed.authorize(.fileWrite, canonicalRelativePath: "Notes2/a.md", expectedRevision: 1)
        }
        var spelledTwice = brief
        spelledTwice.steps = [AgentDelegationBrief.Step(id: "dup", title: "Dup",
                                                       writeRoots: ["Sources", "Sources/"])]
        denies("one root in two spellings") { try spelledTwice.validate() }
        var duplicate = brief
        duplicate.steps = [first, first]
        denies("duplicate step IDs") { try duplicate.validate() }
        var shell = first
        shell.checkID = "sh -c true"
        var shellBrief = brief
        shellBrief.steps = [shell]
        denies("check is not shell text") { try shellBrief.validate() }
        let encoded = try JSONEncoder().encode(amended)
        let restored = try JSONDecoder().decode(AgentDelegationPlan.self, from: encoded)
        try restored.validate()
        check(restored == amended, "state round trip")
        var bad = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        bad["currentIndex"] = -1
        let corrupt = try JSONDecoder().decode(AgentDelegationPlan.self, from: JSONSerialization.data(withJSONObject: bad))
        denies("corrupt index fails closed") { try corrupt.validate() }
        bad["currentIndex"] = 0
        bad["statuses"] = []
        let missing = try JSONDecoder().decode(AgentDelegationPlan.self, from: JSONSerialization.data(withJSONObject: bad))
        denies("corrupt states fail closed") { try missing.validate() }
        print("\(count) delegation brief checks passed")
    }
}
