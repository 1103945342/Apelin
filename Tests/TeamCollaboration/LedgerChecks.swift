import Foundation

@main
struct LedgerChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
        }
        func refuses(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                fatalError("Allowed: \(name)")
            } catch let error as AgentAssignmentViolation {
                check(!error.subject.isEmpty && !error.rule.isEmpty, name)
            } catch {
                fatalError("Unexpected error for \(name): \(error)")
            }
        }
        func origin(_ child: String, opener: String = "opener") -> AgentAssignment.Origin {
            AgentAssignment.Origin(openerSessionID: opener, openerRequestID: "request-1",
                                   childSessionID: child)
        }
        func assignment(_ id: String, _ child: String,
                        acceptance: [String] = ["Criterion A", "Criterion B"],
                        briefRevision: UInt64 = 1) throws -> AgentAssignment {
            try AgentAssignment(id: id, origin: origin(child), objective: "Do the delegated work",
                                acceptance: acceptance, briefRevision: briefRevision)
        }

        // A member starts working, unverified, with one revision.
        let a = try assignment("a1", "child-a")
        check(a.state == .working && a.revision == 1, "a new member is working at revision 1")
        check(a.verification == .unverified && a.missingChecks.count == 2,
              "no receipts means every criterion is missing")
        refuses("an assignment needs an identifier") {
            _ = try AgentAssignment(id: "a b", origin: origin("child-a"), objective: "x",
                                    acceptance: ["c"], briefRevision: 1)
        }
        refuses("acceptance criteria are distinct") {
            _ = try AgentAssignment(id: "dup", origin: origin("child-a"), objective: "x",
                                    acceptance: ["c", "c"], briefRevision: 1)
        }
        refuses("the origin names its opener") {
            _ = try AgentAssignment(id: "bad", origin: origin("child-a", opener: "opener / 1"),
                                    objective: "x", acceptance: ["c"], briefRevision: 1)
        }

        // A child's completion claim reaches review and stops there.
        let submitted = try a.submittedForReview(expectedRevision: 1)
        check(submitted.state == .readyForReview, "a completion claim reaches review")
        check(submitted.state != .accepted, "a completion claim is never acceptance")
        check(submitted.verification == .unverified && submitted.missingChecks == a.acceptance,
              "a claim without receipts stays unverified")
        refuses("the child cannot accept its own work") {
            _ = try submitted.accepted(by: submitted.origin.childSessionID,
                                       expectedRevision: submitted.revision)
        }
        refuses("acceptance needs a reviewed submission") {
            _ = try a.accepted(by: "opener", expectedRevision: 1)
        }
        refuses("only the opener cancels") {
            _ = try a.cancelled(by: "child-a", reason: "self-cancel", expectedRevision: 1)
        }
        refuses("a stale member revision is refused") {
            _ = try submitted.accepted(by: "opener", expectedRevision: 1)
        }
        let accepted = try submitted.accepted(by: "opener", expectedRevision: submitted.revision)
        check(accepted.state == .accepted && accepted.verification == .unverified,
              "accepting unchecked work stays labelled unverified")
        check(accepted.missingChecks.count == 2, "the missing checks stay listed after acceptance")
        refuses("a terminal member takes no output") {
            _ = try accepted.recording(.init(id: "out", summary: "after acceptance"),
                                       expectedRevision: accepted.revision)
        }
        refuses("a terminal member cannot be cancelled again") {
            _ = try accepted.cancelled(by: "opener", reason: "late",
                                       expectedRevision: accepted.revision)
        }

        // Host-observed receipts, a correction at the same revision, and a
        // receipt from an older plan revision.
        let step = AgentDelegationBrief.Step(id: "edit", title: "Edit", writeRoots: ["Sources"],
                                             capabilities: [.fileWrite], checkID: "syntax")
        let brief = AgentDelegationBrief(objective: "Make a verified change",
                                         acceptance: ["Criterion A"], steps: [step])
        let plan = try AgentDelegationPlan(brief: brief)
        let verifiedPlan = try plan.checked(adapterID: "syntax", exitCode: 0,
                                            expectedRevision: plan.revision)
        try verifiedPlan.validate()
        let single = try assignment("s1", "child-s", acceptance: ["Criterion A"])
        var checked = try single.reporting(.init(adapterID: "syntax", criterion: "Criterion A",
                                                 passed: false, planRevision: plan.revision),
                                           expectedRevision: single.revision)
        check(checked.verification == .unverified && checked.failedChecks.count == 1,
              "a failing receipt keeps the criterion missing")
        check(checked.missingChecks == ["Criterion A"], "a failure does not settle its criterion")
        refuses("a stale receipt revision is refused") {
            _ = try checked.reporting(.init(adapterID: "syntax", criterion: "Criterion A",
                                            passed: true, planRevision: plan.revision),
                                      expectedRevision: single.revision)
        }
        check(checked.checks.count == 1 && checked.revision == 2, "a receipt moves the member revision")
        checked = try checked.reporting(.init(adapterID: "syntax", criterion: "Criterion A",
                                              passed: true, planRevision: plan.revision),
                                        expectedRevision: checked.revision)
        check(checked.verification == .verified && checked.missingChecks.isEmpty,
              "a passing receipt settles its criterion")
        check(checked.checks.count == 1, "a re-run replaces the receipt, not the history")

        // An amendment makes the old receipt stale; it cannot certify the new
        // plan, and the new revision owes fresh evidence.
        let amended = try checked.rebased(briefRevision: verifiedPlan.revision,
                                          acceptance: ["Criterion A", "Criterion C"],
                                          expectedRevision: checked.revision)
        check(amended.state == .working && amended.briefRevision == verifiedPlan.revision,
              "an amendment reopens the work at the new brief revision")
        check(amended.staleChecks.count == 1 && amended.missingChecks.count == 2,
              "a receipt from an older revision certifies nothing")
        let fresh = try amended.reporting(.init(adapterID: "syntax", criterion: "Criterion A",
                                                passed: true,
                                                planRevision: verifiedPlan.revision),
                                          expectedRevision: amended.revision)
        check(fresh.missingChecks == ["Criterion C"], "a receipt at the new revision counts")

        // Blocked allows reads and reports, not mutation, and cannot claim
        // completion until it resumes.
        let blocked = try a.blocked(.init(reason: "Need a decision",
                                          needs: "opener chooses a path"),
                                    expectedRevision: 1)
        check(blocked.state == .blocked && blocked.blockers.count == 1, "a blocker moves the member")
        refuses("a blocked member records no output") {
            _ = try blocked.recording(.init(id: "out", summary: "blocked write"),
                                      expectedRevision: blocked.revision)
        }
        refuses("a blocked member cannot claim completion") {
            _ = try blocked.submittedForReview(expectedRevision: blocked.revision)
        }
        let resumed = try blocked.resumed(expectedRevision: blocked.revision)
        check(resumed.state == .working, "resuming returns to working")
        let resubmitted = try resumed.submittedForReview(expectedRevision: resumed.revision)
        check(resubmitted.state == .readyForReview, "planned work continues after a block")

        // Cancellation and failure are terminal and carry their reason.
        let cancelled = try a.cancelled(by: "opener", reason: "Superseded by a newer task",
                                        expectedRevision: 1)
        check(cancelled.state == .cancelled && cancelled.outcomeNote != nil,
              "a cancellation records why")
        let doomed = try assignment("f1", "child-f", acceptance: ["Only criterion"])
        let failed = try doomed.failed("The build runner died", expectedRevision: 1)
        check(failed.state == .failed && failed.verification == .unverified,
              "a failure keeps its evidence label")
        refuses("a failed member cannot submit for review") {
            _ = try failed.submittedForReview(expectedRevision: failed.revision)
        }
        refuses("a failed member cannot be rebased") {
            _ = try failed.rebased(briefRevision: 2, acceptance: ["Only criterion"],
                                   expectedRevision: failed.revision)
        }

        // A group: adding a member moves the group revision and outdates an
        // earlier summary; the seal fixes membership.
        var group = try AgentAssignmentGroup(id: "g1", openerSessionID: "opener")
        check(group.revision == 1 && !group.isSealed, "a new group is open at revision 1")
        group = try group.adding(a, expectedRevision: group.revision)
        let beforeMember = group.snapshot()
        check(group.revision == 2 && beforeMember.members.count == 1,
              "a delegation moves the group revision")
        let b = try assignment("b1", "child-b")
        group = try group.adding(b, expectedRevision: group.revision)
        check(group.revision == 3, "a second delegation moves it again")
        check(group.freshness(of: beforeMember) == .outdated,
              "a new member makes the earlier summary outdated")
        check(group.freshness(of: group.snapshot()) == .current, "the fresh summary is current")
        refuses("a delegation from a stale group revision is refused") {
            _ = try group.adding(try assignment("c1", "child-c"), expectedRevision: 2)
        }
        refuses("a member identifier is unique") {
            _ = try group.adding(try assignment("a1", "child-c"), expectedRevision: group.revision)
        }
        refuses("one member per child conversation") {
            _ = try group.adding(try assignment("a2", "child-a"), expectedRevision: group.revision)
        }
        refuses("another opener's member is refused") {
            let foreign = try AgentAssignment(id: "x1",
                                              origin: origin("child-x", opener: "someone-else"),
                                              objective: "x", acceptance: ["c"], briefRevision: 1)
            _ = try group.adding(foreign, expectedRevision: group.revision)
        }
        refuses("the seal cannot name an unknown assignment") {
            _ = try group.sealed(expectedAssignmentIDs: ["a1", "b1", "zz"],
                                 expectedRevision: group.revision)
        }
        refuses("the seal cannot omit a member") {
            _ = try group.sealed(expectedAssignmentIDs: ["a1"], expectedRevision: group.revision)
        }
        group = try group.sealed(expectedAssignmentIDs: ["a1", "b1"],
                                 expectedRevision: group.revision)
        check(group.isSealed && group.revision == 4, "the seal moves the group revision")
        check(group.expectedAssignmentIDs == ["a1", "b1"], "the seal records the expected members")
        refuses("a sealed group takes no more tasks") {
            _ = try group.adding(try assignment("c1", "child-c"), expectedRevision: group.revision)
        }
        refuses("a final account waits for every member") {
            _ = try group.makeFinalAccount()
        }

        // Members settle independently; a member update keeps the group
        // revision, and a replay of the same member is the same fact.
        let settledA = try submitted.accepted(by: "opener", expectedRevision: submitted.revision)
        group = try group.replacing(settledA, expectedRevision: group.revision)
        check(group.revision == 4, "a member update does not move the group revision")
        check(try group.replacing(settledA, expectedRevision: group.revision) == group,
              "a replayed member is the same fact")
        refuses("a stale member cannot replace a newer one") {
            _ = try group.replacing(a, expectedRevision: group.revision)
        }
        let settledB = try b.cancelled(by: "opener", reason: "Superseded",
                                       expectedRevision: b.revision)
        group = try group.replacing(settledB, expectedRevision: group.revision)
        check(group.allTerminal && group.isAccountable,
              "the group is accountable when every member is terminal")

        // The final account: complete, keyed by group revision, carrying
        // claims and evidence alike.
        let account = try group.makeFinalAccount()
        check(account.eventID == "assignment-final:g1:4",
              "the account is keyed by group and revision")
        check(account.snapshot.acceptedCount == 1
                && account.snapshot.member("b1")?.state == .cancelled,
              "the account reports a cancellation as a cancellation")
        check(account.snapshot.member("a1")?.verification == .unverified,
              "an unverified acceptance stays visible in the account")
        check(account.snapshot.member("b1")?.outcomeNote == "Superseded",
              "the cancellation reason reaches the account")
        check(account.snapshot.member("a1")?.missingChecks.count == 2,
              "missing checks travel with the account")

        // Encoding and restart: nothing is lost and work continues.
        let ledgerData = try JSONEncoder().encode(try AgentAssignmentLedger().adding(group))
        let restoredLedger = try JSONDecoder().decode(AgentAssignmentLedger.self, from: ledgerData)
        try restoredLedger.validate()
        check(restoredLedger.groups.first == group, "a group survives a restart")

        var live = try AgentAssignmentGroup(id: "g2", openerSessionID: "opener")
        live = try live.adding(a, expectedRevision: live.revision)
        let bBlocked = try b.blocked(.init(reason: "Waiting on the opener"),
                                     expectedRevision: b.revision)
        live = try live.adding(bBlocked, expectedRevision: live.revision)
        let liveSnapshot = live.snapshot()
        check(liveSnapshot.member("b1")?.state == .blocked
                && liveSnapshot.member("a1")?.state == .working,
              "a report snapshot includes blocked and working members")
        let liveData = try JSONEncoder().encode(live)
        let liveRestored = try JSONDecoder().decode(AgentAssignmentGroup.self, from: liveData)
        try liveRestored.validate()
        check(liveRestored == live && liveRestored.snapshot() == liveSnapshot,
              "a running group survives a restart intact")
        let continued = try liveRestored.replacing(
            bBlocked.resumed(expectedRevision: bBlocked.revision),
            expectedRevision: liveRestored.revision
        )
        check(continued.assignment("b1")?.state == .working,
              "a decoded group continues where it stopped")

        var corruptJSON = try JSONSerialization.jsonObject(with: liveData) as! [String: Any]
        corruptJSON["revision"] = 0
        let corrupt = try JSONDecoder().decode(
            AgentAssignmentGroup.self,
            from: JSONSerialization.data(withJSONObject: corruptJSON)
        )
        refuses("a corrupt group fails closed") { try corrupt.validate() }
        corruptJSON["revision"] = 3
        corruptJSON["isSealed"] = true
        let unsealed = try JSONDecoder().decode(
            AgentAssignmentGroup.self,
            from: JSONSerialization.data(withJSONObject: corruptJSON)
        )
        refuses("a sealed group without expected IDs fails closed") { try unsealed.validate() }

        // A failure is reported, never painted as success.
        var failedGroup = try AgentAssignmentGroup(id: "g3", openerSessionID: "opener")
        failedGroup = try failedGroup.adding(failed, expectedRevision: failedGroup.revision)
        failedGroup = try failedGroup.sealed(expectedAssignmentIDs: ["f1"],
                                             expectedRevision: failedGroup.revision)
        let failedAccount = try failedGroup.makeFinalAccount()
        check(failedAccount.snapshot.member("f1")?.state == .failed,
              "a failed member stays failed in the account")
        check(failedAccount.snapshot.acceptedCount == 0,
              "a failure is not counted as acceptance")
        check(failedAccount.snapshot.member("f1")?.outcomeNote == "The build runner died",
              "the failure reason reaches the account")

        // The ledger records one final event per group revision.
        var ledger = try AgentAssignmentLedger().adding(group)
        ledger = try ledger.recordingFinalAccount(account)
        let recorded = ledger
        ledger = try ledger.recordingFinalAccount(account)
        check(ledger == recorded && ledger.finalAccounts.count == 1,
              "a redelivered final event is deduplicated")
        check(ledger.outdatedFinalAccounts.isEmpty, "a fresh account is not outdated")
        refuses("an account for a group the ledger does not hold is refused") {
            _ = try ledger.recordingFinalAccount(failedAccount)
        }

        var forgedSnapshot = account.snapshot
        forgedSnapshot.members[0].outputs.append(.init(id: "forged", summary: "never reported"))
        let forged = AgentAssignmentFinalAccount(groupID: "g1", groupRevision: 4,
                                                snapshot: forgedSnapshot)
        refuses("a rewritten account for the same event is refused") {
            _ = try ledger.recordingFinalAccount(forged)
        }
        var relabelledJSON = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(account)
        ) as! [String: Any]
        relabelledJSON["groupRevision"] = 3
        let relabelled = try JSONDecoder().decode(
            AgentAssignmentFinalAccount.self,
            from: JSONSerialization.data(withJSONObject: relabelledJSON)
        )
        refuses("an account whose event ID lies is refused") { try relabelled.validate() }

        // Membership moving during delivery: the older summary is outdated and
        // the new revision owes a fresh account.
        var changed = try AgentAssignmentGroup(id: "g1", openerSessionID: "opener")
        changed = try changed.adding(a, expectedRevision: changed.revision)
        changed = try changed.adding(try assignment("c1", "child-c"),
                                     expectedRevision: changed.revision)
        changed = try changed.adding(try assignment("d1", "child-d"),
                                     expectedRevision: changed.revision)
        changed = try changed.sealed(expectedAssignmentIDs: ["a1", "c1", "d1"],
                                     expectedRevision: changed.revision)
        check(changed.revision == 5 && changed.freshness(of: account.snapshot) == .outdated,
              "a membership change outdates the earlier summary")
        let movedLedger = try AgentAssignmentLedger().adding(changed)
        refuses("an account from an older group revision is refused") {
            _ = try movedLedger.recordingFinalAccount(account)
        }
        refuses("an account naming another snapshot revision is refused") {
            _ = try AgentAssignmentFinalAccount(groupID: "g1", groupRevision: 4,
                                                snapshot: changed.snapshot()).validate()
        }

        // A ledger refuses a group it already holds, an out-of-order update,
        // and a group whose successor is not newer.
        refuses("a group is added once") {
            _ = try AgentAssignmentLedger().adding(group).adding(group)
        }
        refuses("a stale group replacement is refused") {
            _ = try AgentAssignmentLedger().adding(group).replacing(changed, expectedRevision: 3)
        }
        refuses("a group replacement needs a newer revision") {
            _ = try AgentAssignmentLedger().adding(changed).replacing(group, expectedRevision: 5)
        }
        var ledgerJSON = try JSONSerialization.jsonObject(with: ledgerData) as! [String: Any]
        var groupsJSON = ledgerJSON["groups"] as! [[String: Any]]
        groupsJSON.append(groupsJSON[0])
        ledgerJSON["groups"] = groupsJSON
        let duplicated = try JSONDecoder().decode(
            AgentAssignmentLedger.self,
            from: JSONSerialization.data(withJSONObject: ledgerJSON)
        )
        refuses("a duplicate group fails closed") { try duplicated.validate() }

        print("\(count) assignment ledger checks passed")
    }
}
