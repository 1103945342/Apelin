import Foundation

/// A write closure the checks can break, so a failed save is proven not to
/// reach the file or a later read.
final class WriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    private var writes = 0

    func failNextWrite() {
        lock.lock()
        failures += 1
        lock.unlock()
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func write(_ data: Data, _ url: URL) throws {
        lock.lock()
        let failing = failures > 0
        if failing {
            failures -= 1
        } else {
            writes += 1
        }
        lock.unlock()
        if failing { throw ProbeFailure.injected }
        try data.write(to: url, options: .atomic)
    }
}

enum ProbeFailure: Error {
    case injected
}

@main
struct AssignmentStoreChecks {
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
        }
        func refuses(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                fatalError("Allowed: \(name)")
            } catch let error as AgentAssignmentViolation {
                check(!error.subject.isEmpty && !error.rule.isEmpty, name)
            } catch {
                fatalError("Unexpected error for \(name): \(error)")
            }
        }
        func fails(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                fatalError("Allowed: \(name)")
            } catch {
                check(true, name)
            }
        }
        func brief(objective: String = "Ship the change",
                   acceptance: [String] = ["The change is verified"],
                   checkID: String? = nil) -> AgentDelegationBrief {
            AgentDelegationBrief(
                objective: objective,
                acceptance: acceptance,
                steps: [.init(id: "edit", title: "Edit", writeRoots: ["Sources"],
                              capabilities: [.fileWrite], checkID: checkID)]
            )
        }
        func finishedPlan(_ brief: AgentDelegationBrief) throws -> AgentDelegationPlan {
            var plan = try AgentDelegationPlan(brief: brief)
            plan = try plan.requestReview(expectedRevision: plan.revision)
            plan = try plan.accepted(expectedRevision: plan.revision)
            return plan
        }
        func scratch(_ name: String) throws -> URL {
            let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("assignment-store-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let root = try scratch("main")
        let brokenRoot = try scratch("broken")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: brokenRoot)
        }
        let probe = WriteProbe()
        let store = AgentAssignmentStore(directory: root) { data, url in
            try probe.write(data, url)
        }
        let opener = UUID().uuidString
        let otherOpener = UUID().uuidString
        let openerTwo = UUID().uuidString
        let openerThree = UUID().uuidString
        let childOne = UUID().uuidString
        let childTwo = UUID().uuidString
        let childFour = UUID().uuidString
        let childFive = UUID().uuidString
        let childSix = UUID().uuidString
        let file = root.appendingPathComponent(opener + ".json")

        // Registration creates one member, one file, and the origin the report
        // will name.
        let first = try await store.register(child: childOne, opener: opener,
                                             brief: brief(), request: "request-1")
        check(first.id == childOne && first.state == .working && first.briefRevision == 1,
              "registration creates a working member")
        check(first.origin.openerSessionID == opener && first.origin.childSessionID == childOne,
              "the member keeps its opener and child")
        check(first.origin.openerRequestID == "request-1", "the opening request is recorded")
        check(try await store.read(opener: otherOpener) == nil,
              "an opener with no file reads as nil")
        let opened = try await store.read(opener: opener)
        check(opened?.groups.count == 1, "one group per opener")
        check(opened?.groups.first?.id == "team." + opener, "the group derives from its opener")
        check(opened?.groups.first?.revision == 2, "the first delegation moves the group revision")
        check(opened?.groups.first?.assignment(childOne) == first, "the file holds the member")
        check(FileManager.default.fileExists(atPath: file.path), "the opener owns one file")

        // Registration is idempotent with the same brief and refuses another.
        let writesBefore = probe.writeCount
        let again = try await store.register(child: childOne, opener: opener, brief: brief())
        check(again == first, "re-registering the same brief answers the stored member")
        check(probe.writeCount == writesBefore, "a re-registration does not write")
        await refuses("a different brief is not a re-registration") {
            _ = try await store.register(child: childOne, opener: opener,
                                         brief: brief(objective: "Something else"))
        }
        await refuses("an opener must be a session UUID") {
            _ = try await store.register(child: UUID().uuidString, opener: "not-a-uuid", brief: brief())
        }
        await refuses("a child must be a session UUID") {
            _ = try await store.register(child: "child", opener: opener, brief: brief())
        }
        await refuses("a child cannot open itself") {
            _ = try await store.register(child: opener, opener: opener, brief: brief())
        }
        await fails("an invalid brief is refused") {
            _ = try await store.register(child: UUID().uuidString, opener: opener,
                                         brief: AgentDelegationBrief(objective: "", acceptance: ["x"], steps: []))
        }

        // Two delegations, one file, one account per child.
        let second = try await store.register(child: childTwo, opener: opener, brief: brief())
        check(second.id == childTwo && second.state == .working, "a second child registers")
        check(try await store.read(opener: opener)?.groups.first?.revision == 3,
              "a second delegation moves the group revision again")
        await refuses("a child already registered elsewhere is refused") {
            _ = try await store.register(child: childOne, opener: otherOpener, brief: brief())
        }
        check(try await store.read(opener: otherOpener) == nil,
              "the refused registration left no file behind")

        // A plan's blocked step blocks the member with a derived blocker; the
        // amendment that reopens the step removes exactly that blocker.
        let plan = try AgentDelegationPlan(brief: brief())
        let step = plan.brief.steps[0]
        let blockedPlan = try plan.blocked(expectedRevision: plan.revision)
        let blockedMember = try await store.sync(child: childOne, opener: opener, plan: blockedPlan)
        check(blockedMember.state == .blocked && blockedMember.blockers.count == 1,
              "a blocked plan blocks the member")
        check(try await store.derivedBlocker(child: childOne, opener: opener) != nil,
              "the blocker is recorded as derived")
        check(blockedMember.state != .readyForReview, "a blocked plan is not a completion claim")
        let amendedPlan = try blockedPlan.amendingCurrent(step, expectedRevision: blockedPlan.revision)
        let cleared = try await store.sync(child: childOne, opener: opener, plan: amendedPlan)
        check(cleared.state == .working, "the amended step clears the derived block")
        check(cleared.blockers.isEmpty, "the derived blocker is removed from the member")
        check(try await store.derivedBlocker(child: childOne, opener: opener) == nil,
              "no derived blocker is left behind")
        let blockedAgain = try amendedPlan.blocked(expectedRevision: amendedPlan.revision)
        let blockedTwice = try await store.sync(child: childOne, opener: opener, plan: blockedAgain)
        check(blockedTwice.state == .blocked && blockedTwice.blockers.count == 1,
              "a later blocked step blocks again, once")
        let replayedBlock = try await store.sync(child: childOne, opener: opener, plan: blockedAgain)
        check(replayedBlock == blockedTwice, "a replayed blocked plan adds no blocker")
        let amendedAgain = try blockedAgain.amendingCurrent(step,
                                                            expectedRevision: blockedAgain.revision)
        let clearedAgain = try await store.sync(child: childOne, opener: opener, plan: amendedAgain)
        check(clearedAgain.state == .working && clearedAgain.blockers.isEmpty,
              "the second amendment clears its derived blocker")
        check(try await store.read(opener: opener)?.groups.first?.revision == 3,
              "a member update does not move the group revision")

        // A plan carried to its end is reviewable, never accepted.
        let done = try finishedPlan(brief())
        check(done.currentStep == nil, "the plan is finished")
        let finished = try await store.sync(child: childTwo, opener: opener, plan: done)
        check(finished.state == .readyForReview, "a finished plan becomes ready for review")
        check(finished.state != .accepted, "a finished plan is never acceptance")
        check(finished.verification == .unverified, "an unreviewed plan stays unverified")
        let settledWrites = probe.writeCount
        let repeated = try await store.sync(child: childTwo, opener: opener, plan: done)
        check(repeated == finished && probe.writeCount == settledWrites,
              "a replayed plan is the same fact")

        // Stale and foreign plans are refused.
        await refuses("an older plan is refused") {
            _ = try await store.sync(child: childOne, opener: opener, plan: blockedPlan)
        }
        await refuses("a plan without a registration is refused") {
            _ = try await store.sync(child: UUID().uuidString, opener: opener, plan: plan)
        }
        await refuses("a plan for another brief is refused") {
            _ = try await store.sync(child: childOne, opener: opener,
                                     plan: try AgentDelegationPlan(brief: brief(objective: "Elsewhere",
                                                                                acceptance: ["Other"])))
        }
        await refuses("a plan for an opener with no file is refused") {
            _ = try await store.sync(child: childOne, opener: otherOpener, plan: plan)
        }

        // The opener's explicit acceptance, only for a finished plan.
        await refuses("acceptance needs a finished plan") {
            _ = try await store.accept(child: childOne, opener: opener, plan: plan,
                                       expectedRevision: clearedAgain.revision)
        }
        await refuses("acceptance from a stale revision is refused") {
            _ = try await store.accept(child: childTwo, opener: opener, plan: done,
                                       expectedRevision: finished.revision - 1)
        }
        await refuses("a plan for another brief cannot be accepted") {
            _ = try await store.accept(child: childTwo, opener: opener,
                                       plan: try finishedPlan(brief(objective: "Elsewhere",
                                                                    acceptance: ["Other"])),
                                       expectedRevision: finished.revision)
        }
        await refuses("another opener cannot accept this child") {
            _ = try await store.accept(child: childTwo, opener: otherOpener, plan: done,
                                       expectedRevision: finished.revision)
        }
        let accepted = try await store.accept(child: childTwo, opener: opener, plan: done,
                                              expectedRevision: finished.revision)
        check(accepted.state == .accepted, "the opener's explicit review accepts the work")
        check(accepted.verification == .unverified, "an unchecked acceptance stays unverified")
        check(accepted.missingChecks == ["The change is verified"],
              "the missing checks stay listed after acceptance")
        let acceptedAgain = try await store.accept(child: childTwo, opener: opener, plan: done,
                                                   expectedRevision: finished.revision)
        check(acceptedAgain == accepted, "a repeated acceptance is the same fact")

        // Cancellation and failure state why, and are terminal.
        let four = try await store.register(child: childFour, opener: opener, brief: brief())
        await refuses("a cancellation states why") {
            _ = try await store.cancel(child: childFour, opener: opener, reason: "   ",
                                       expectedRevision: four.revision)
        }
        await refuses("a cancellation from a stale revision is refused") {
            _ = try await store.cancel(child: childFour, opener: opener, reason: "Superseded",
                                       expectedRevision: four.revision + 5)
        }
        let cancelled = try await store.cancel(child: childFour, opener: opener,
                                               reason: "Superseded by a newer task",
                                               expectedRevision: four.revision)
        check(cancelled.state == .cancelled && cancelled.outcomeNote == "Superseded by a newer task",
              "a cancellation keeps its reason")
        let cancelledAgain = try await store.cancel(child: childFour, opener: opener,
                                                    reason: "Superseded by a newer task",
                                                    expectedRevision: four.revision)
        check(cancelledAgain == cancelled, "a repeated cancellation is the same fact")
        await refuses("an accepted member cannot fail later") {
            _ = try await store.fail(child: childTwo, opener: opener, reason: "Too late",
                                     expectedRevision: accepted.revision)
        }
        let five = try await store.register(child: childFive, opener: opener, brief: brief())
        await refuses("a failure states why") {
            _ = try await store.fail(child: childFive, opener: opener, reason: "",
                                     expectedRevision: five.revision)
        }
        let failed = try await store.fail(child: childFive, opener: opener,
                                          reason: "The worker went away",
                                          expectedRevision: five.revision)
        check(failed.state == .failed && failed.outcomeNote == "The worker went away",
              "a failure keeps its reason")
        check(try await store.fail(child: childFive, opener: opener, reason: "Other",
                                   expectedRevision: five.revision) == failed,
              "a repeated failure is the same fact")

        // Reports are claims: kept, deduplicated, and never evidence.
        let beforeReport = try await store.assignment(child: childTwo, opener: opener)!
        let report = AgentTurnReport(childSessionID: childTwo, childTaskID: "task-1",
                                     outcome: .completed, closingSeq: 7, text: "All done")
        let afterReport = try await store.recordReport(report, opener: opener)
        check(afterReport == beforeReport, "a report changes no member state or receipt")
        let storedReports = try await store.reports(child: childTwo, opener: opener)
        check(storedReports.count == 1 && storedReports.first?.text == "All done",
              "the report is kept as a claim with its text")
        let afterFirstReport = probe.writeCount
        check(try await store.recordReport(report, opener: opener) == beforeReport,
              "the same turn again is the same fact")
        check(probe.writeCount == afterFirstReport, "a replayed report does not write")
        await refuses("another text under the same turn identity is refused") {
            _ = try await store.recordReport(
                AgentTurnReport(childSessionID: childTwo, childTaskID: "task-1",
                                outcome: .completed, closingSeq: 7, text: "Something else"),
                opener: opener
            )
        }
        await refuses("a report for an unknown child is refused") {
            _ = try await store.recordReport(
                AgentTurnReport(childSessionID: UUID().uuidString, childTaskID: "task-2",
                                outcome: .failed, closingSeq: 1, text: "x"),
                opener: opener
            )
        }
        await refuses("an oversized report is refused") {
            _ = try await store.recordReport(
                AgentTurnReport(childSessionID: childTwo, childTaskID: "task-big",
                                outcome: .completed, closingSeq: 8,
                                text: String(repeating: "x", count: 20_000)),
                opener: opener
            )
        }
        let runningReport = AgentTurnReport(childSessionID: childOne, childTaskID: "task-live",
                                            outcome: .aborted, stoppedBy: .opener,
                                            closingSeq: 9, text: "Paused")
        let stillCleared = try await store.recordReport(runningReport, opener: opener)
        check(stillCleared.state == .working, "a report on a running member does not move it")

        // The kept claims are bounded and say how many were left out; the
        // member and the final account never depend on this list.
        let beforeBulk = try await store.assignment(child: childOne, opener: opener)
        for index in 0..<33 {
            _ = try await store.recordReport(
                AgentTurnReport(childSessionID: childOne, childTaskID: "bulk-\(index)",
                                outcome: .completed, closingSeq: UInt64(100 + index),
                                text: "claim \(index)"),
                opener: opener
            )
        }
        let claims = try await store.reports(child: childOne, opener: opener)
        check(claims.count == 32, "the kept claims stay bounded at 32")
        check(claims.first?.closingSeq == 101, "the oldest kept claim is the 32nd from the end")
        check(try await store.droppedReportCount(child: childOne, opener: opener) == 2,
              "the dropped claims are counted, not hidden")
        check(try await store.assignment(child: childOne, opener: opener) == beforeBulk,
              "recording claims never moves the member")

        // A blocker the member carries itself is never cleared by the plan.
        let six = try await store.register(child: childSix, opener: opener, brief: brief())
        var seeded = try JSONDecoder().decode(AgentAssignmentStore.Record.self,
                                              from: Data(contentsOf: file))
        let seededGroup = seeded.group
        let explicit = try six.blocked(.init(reason: "The reader asked for a pause",
                                             needs: "a decision"), expectedRevision: six.revision)
        seeded.group = try seededGroup.replacing(explicit, expectedRevision: seededGroup.revision)
        try JSONEncoder().encode(seeded).write(to: file, options: .atomic)
        check(try await store.derivedBlocker(child: childSix, opener: opener) == nil,
              "an explicit blocker has no derived note")
        let stillExplicit = try await store.sync(child: childSix, opener: opener, plan: plan)
        check(stillExplicit.state == .blocked && stillExplicit.blockers.count == 1,
              "a working plan does not clear an explicit blocker")
        let planBlockedSix = try plan.blocked(expectedRevision: plan.revision)
        let stillExplicitBlocked = try await store.sync(child: childSix, opener: opener,
                                                        plan: planBlockedSix)
        check(stillExplicitBlocked.state == .blocked && stillExplicitBlocked.blockers.count == 1,
              "a blocked plan adds no second blocker to an explicit one")
        check(try await store.derivedBlocker(child: childSix, opener: opener) == nil,
              "the explicit block is still not derived")
        await refuses("an explicitly blocked member is not accepted") {
            _ = try await store.accept(child: childSix, opener: opener,
                                       plan: try finishedPlan(brief()),
                                       expectedRevision: stillExplicitBlocked.revision)
        }

        // Restart: the ledger, plan notes and reports survive.
        let reopened = AgentAssignmentStore(directory: root) { data, url in
            try probe.write(data, url)
        }
        let beforeRestart = try await store.read(opener: opener)
        let afterRestart = try await reopened.read(opener: opener)
        check(afterRestart == beforeRestart, "the ledger survives a restart")
        check(afterRestart?.groups.first?.assignment(childTwo)?.state == .accepted,
              "an acceptance survives a restart")
        check(try await reopened.reports(child: childTwo, opener: opener).count == 1,
              "recorded reports survive a restart")
        check(try await reopened.droppedReportCount(child: childOne, opener: opener) == 2,
              "the dropped-claim count survives a restart")
        await refuses("a stale plan stays refused after a restart") {
            _ = try await reopened.sync(child: childOne, opener: opener, plan: blockedPlan)
        }
        let continued = try await reopened.sync(child: childOne, opener: opener, plan: amendedAgain)
        check(continued.state == .working, "a restarted store continues from the saved note")

        // Seal fixes membership; the final account is staged under the ledger
        // model's stable ID and acknowledged once.
        let s1 = UUID().uuidString
        let s2 = UUID().uuidString
        _ = try await store.register(child: s1, opener: openerTwo, brief: brief())
        _ = try await store.register(child: s2, opener: openerTwo, brief: brief())
        let unsealed = try await store.read(opener: openerTwo)!.groups.first!
        check(unsealed.assignments.count == 2, "the group holds both children")
        await refuses("sealing from a stale group revision is refused") {
            _ = try await store.seal(opener: openerTwo, expectedRevision: unsealed.revision + 1)
        }
        let sealed = try await store.seal(opener: openerTwo, expectedRevision: unsealed.revision)
        check(sealed.isSealed && sealed.revision == unsealed.revision + 1,
              "the seal fixes membership and moves the group revision")
        await refuses("a sealed group takes no more tasks") {
            _ = try await store.register(child: UUID().uuidString, opener: openerTwo, brief: brief())
        }
        check(try await store.finalAccount(opener: openerTwo) == nil,
              "no final account while members are running")
        check(try await store.pendingFinalAccount(opener: openerTwo) == nil,
              "nothing is staged while members are running")
        let doneS1 = try finishedPlan(brief())
        let doneS2 = try finishedPlan(brief())
        _ = try await store.sync(child: s1, opener: openerTwo, plan: doneS1)
        _ = try await store.sync(child: s2, opener: openerTwo, plan: doneS2)
        let readyS1 = try await store.assignment(child: s1, opener: openerTwo)!
        let readyS2 = try await store.assignment(child: s2, opener: openerTwo)!
        _ = try await store.accept(child: s1, opener: openerTwo, plan: doneS1,
                                   expectedRevision: readyS1.revision)
        _ = try await store.accept(child: s2, opener: openerTwo, plan: doneS2,
                                   expectedRevision: readyS2.revision)
        let settled = try await store.finalAccount(opener: openerTwo)
        check(settled != nil, "a sealed group with every member settled owes an account")
        check(settled?.eventID == AgentAssignmentFinalAccount.identifier(
            groupID: "team." + openerTwo, groupRevision: sealed.revision
        ), "the account uses the model's stable event ID")
        let stagedWrites = probe.writeCount
        let pending = try await store.pendingFinalAccount(opener: openerTwo)
        check(pending == settled, "staging answers the computed account")
        check(probe.writeCount == stagedWrites + 1, "staging writes the account once")
        let pendingAgain = try await store.pendingFinalAccount(opener: openerTwo)
        check(pendingAgain == pending && probe.writeCount == stagedWrites + 1,
              "a second pending call writes nothing")

        // The event ID and snapshot are stable while the group is settled:
        // replays and claims do not mint a second account.
        _ = try await store.sync(child: s1, opener: openerTwo, plan: doneS1)
        _ = try await store.accept(child: s1, opener: openerTwo, plan: doneS1,
                                   expectedRevision: readyS1.revision)
        _ = try await store.recordReport(
            AgentTurnReport(childSessionID: s1, childTaskID: "s1-turn", outcome: .completed,
                            closingSeq: 1, text: "Finished"),
            opener: openerTwo
        )
        check(try await store.pendingFinalAccount(opener: openerTwo) == pending,
              "a replay or a claim does not change the pending account")
        check(try await store.finalAccount(opener: openerTwo) == pending,
              "the computed account still matches the staged one")
        await refuses("acknowledging an unknown event is refused") {
            _ = try await store.acknowledgeFinalAccount(opener: openerTwo, eventID: "assignment-final:x:1")
        }
        let acknowledged = try await store.acknowledgeFinalAccount(opener: openerTwo,
                                                                   eventID: pending!.eventID)
        check(acknowledged == pending, "the acknowledgement answers the staged account")
        check(try await store.pendingFinalAccount(opener: openerTwo) == nil,
              "an acknowledged account is no longer pending")
        let acknowledgedWrites = probe.writeCount
        _ = try await store.acknowledgeFinalAccount(opener: openerTwo, eventID: pending!.eventID)
        check(probe.writeCount == acknowledgedWrites, "a repeated acknowledgement writes nothing")
        _ = try await store.recordReport(
            AgentTurnReport(childSessionID: s1, childTaskID: "s1-turn-2", outcome: .completed,
                            closingSeq: 2, text: "More"),
            opener: openerTwo
        )
        check(try await store.pendingFinalAccount(opener: openerTwo) == nil,
              "a claim after acknowledgement does not mint a second final event")
        check(try await store.finalAccount(opener: openerTwo) == pending,
              "the acknowledged account is still the group's account")
        let afterAccountRestart = AgentAssignmentStore(directory: root) { data, url in
            try probe.write(data, url)
        }
        check(try await afterAccountRestart.pendingFinalAccount(opener: openerTwo) == nil,
              "an acknowledged account stays acknowledged after a restart")
        check(try await afterAccountRestart.finalAccount(opener: openerTwo) == pending,
              "the final account itself is unchanged after a restart")

        // A failed write publishes nothing.
        let blockedTask = UUID().uuidString
        _ = try await store.register(child: blockedTask, opener: openerThree, brief: brief())
        let threeGroup = try await store.read(opener: openerThree)!.groups.first!
        probe.failNextWrite()
        await fails("a failed seal write surfaces the error") {
            _ = try await store.seal(opener: openerThree, expectedRevision: threeGroup.revision)
        }
        check(try await store.read(opener: openerThree)?.groups.first?.isSealed == false,
              "a failed seal leaves the group open")
        let fourth = try await store.register(child: UUID().uuidString, opener: openerThree,
                                              brief: brief())
        check(fourth.state == .working, "the store keeps working after a failed write")
        let failingChild = UUID().uuidString
        let failingMember = try await store.register(child: failingChild, opener: openerThree,
                                                     brief: brief())
        let failingPlan = try finishedPlan(brief())
        _ = try await store.sync(child: failingChild, opener: openerThree, plan: failingPlan)
        let readyToAccept = try await store.assignment(child: failingChild, opener: openerThree)!
        check(readyToAccept.state == .readyForReview && failingMember.state == .working,
              "the member is ready for the failing acceptance")
        probe.failNextWrite()
        await fails("a failed acceptance write surfaces the error") {
            _ = try await store.accept(child: failingChild, opener: openerThree,
                                       plan: failingPlan,
                                       expectedRevision: readyToAccept.revision)
        }
        check(try await store.assignment(child: failingChild, opener: openerThree)?.state
                == .readyForReview,
              "a failed acceptance keeps the previous state on disk")
        let retried = try await store.accept(child: failingChild, opener: openerThree,
                                             plan: failingPlan,
                                             expectedRevision: readyToAccept.revision)
        check(retried.state == .accepted, "the retried acceptance applies")

        // Fail-closed reads: unreadable bytes, a link, a directory and an
        // oversized file are never treated as an empty ledger.
        let broken = AgentAssignmentStore(directory: brokenRoot) { data, url in
            try probe.write(data, url)
        }
        let corruptOpener = UUID().uuidString
        let corruptFile = brokenRoot.appendingPathComponent(corruptOpener + ".json")
        let garbage = Data("this is not a ledger".utf8)
        try garbage.write(to: corruptFile)
        await refuses("unreadable bytes never read as an empty ledger") {
            _ = try await broken.read(opener: corruptOpener)
        }
        await refuses("registration refuses an unreadable ledger") {
            _ = try await broken.register(child: UUID().uuidString, opener: corruptOpener,
                                          brief: brief())
        }
        check(try Data(contentsOf: corruptFile) == garbage,
              "the unreadable bytes are preserved")
        let linkedOpener = UUID().uuidString
        try FileManager.default.createSymbolicLink(
            at: brokenRoot.appendingPathComponent(linkedOpener + ".json"),
            withDestinationURL: corruptFile
        )
        await refuses("a link is never an authority alias") {
            _ = try await broken.read(opener: linkedOpener)
        }
        let directoryOpener = UUID().uuidString
        try FileManager.default.createDirectory(
            at: brokenRoot.appendingPathComponent(directoryOpener + ".json"),
            withIntermediateDirectories: false
        )
        await refuses("a directory is not a ledger file") {
            _ = try await broken.read(opener: directoryOpener)
        }
        let hugeOpener = UUID().uuidString
        try Data(count: 5 * 1024 * 1024).write(
            to: brokenRoot.appendingPathComponent(hugeOpener + ".json")
        )
        await refuses("an oversized ledger is refused before it is read") {
            _ = try await broken.read(opener: hugeOpener)
        }

        // The saved record is validated on the way in.
        let foreignOpener = UUID().uuidString
        let foreignFile = brokenRoot.appendingPathComponent(foreignOpener + ".json")
        var foreignRecord = try JSONDecoder().decode(AgentAssignmentStore.Record.self,
                                                     from: Data(contentsOf: file))
        foreignRecord.opener = opener
        try JSONEncoder().encode(foreignRecord).write(to: foreignFile, options: .atomic)
        await refuses("a record naming another opener is refused") {
            _ = try await broken.read(opener: foreignOpener)
        }
        let brokenOpener = UUID().uuidString
        var brokenPlans = try JSONDecoder().decode(AgentAssignmentStore.Record.self,
                                                   from: Data(contentsOf: file))
        brokenPlans.plans["not-a-member"] = 1
        brokenPlans.opener = brokenOpener
        brokenPlans.group = try AgentAssignmentGroup(id: "team." + brokenOpener,
                                                     openerSessionID: brokenOpener)
        try JSONEncoder().encode(brokenPlans).write(
            to: brokenRoot.appendingPathComponent(brokenOpener + ".json"), options: .atomic
        )
        await refuses("plan notes for a non-member are refused") {
            _ = try await broken.read(opener: brokenOpener)
        }

        // What a child reports it produced: its claim, recorded while the
        // assignment is working, bounded, and never turned into a check.
        let outputOpener = UUID().uuidString
        let outputChild = UUID().uuidString
        _ = try await store.register(child: outputChild, opener: outputOpener, brief: brief())
        let outputOne = AgentAssignment.Output(id: "out-1", summary: "Wrote Sources/File.swift",
                                               path: "Sources/File.swift")
        let outputTwo = AgentAssignment.Output(id: "out-2", summary: "Read the change back")
        let recorded = try await store.report([outputOne, outputTwo], child: outputChild, opener: outputOpener)
        check(recorded.outputs.map(\.id) == ["out-1", "out-2"], "a child's outputs are recorded in order")
        check(recorded.state == .working, "recording output leaves the assignment working")
        check(recorded.outputs.first?.path == "Sources/File.swift", "an output keeps its path")
        check(recorded.verification == .unverified, "a claim is never a check")
        let replayed = try await store.report([outputOne], child: outputChild, opener: outputOpener)
        check(replayed.outputs.count == 2, "the same output is not recorded twice")
        await refuses("an output says what it is") {
            _ = try await store.report([AgentAssignment.Output(id: "out-3", summary: "   ")],
                                       child: outputChild, opener: outputOpener)
        }
        let reread = try await store.read(opener: outputOpener)
        check(reread?.groups.first?.assignment(outputChild)?.outputs.count == 2,
              "the recorded claims are on disk")
        var reviewPlan = try AgentDelegationPlan(brief: brief())
        reviewPlan = try reviewPlan.requestReview(expectedRevision: reviewPlan.revision)
        _ = try await store.sync(child: outputChild, opener: outputOpener, plan: reviewPlan)
        let awaiting = try await store.assignment(child: outputChild, opener: outputOpener)
        check(awaiting?.state == .working,
              "a step waiting for its opener's review leaves the member working")
        reviewPlan = try reviewPlan.accepted(expectedRevision: reviewPlan.revision)
        _ = try await store.sync(child: outputChild, opener: outputOpener, plan: reviewPlan)
        let afterReview = try await store.report([AgentAssignment.Output(id: "out-9", summary: "later")],
                                                 child: outputChild, opener: outputOpener)
        check(afterReview.outputs.count == 2, "a reviewed assignment records no further claim")

        // A plan that restates the acceptance re-baselines the member instead of
        // reading as another brief; the same change without a newer revision is
        // refused.
        let restateOpener = UUID().uuidString
        let restateChild = UUID().uuidString
        _ = try await store.register(child: restateChild, opener: restateOpener, brief: brief())
        var restated = try AgentDelegationPlan(brief: brief())
        restated = try restated.amendingCurrent(
            AgentDelegationBrief.Step(id: "edit", title: "Edit", writeRoots: ["Sources"],
                                      capabilities: [.fileWrite]),
            acceptance: ["The new evidence is checked"],
            expectedRevision: restated.revision
        )
        let rebased = try await store.sync(child: restateChild, opener: restateOpener, plan: restated)
        check(rebased.acceptance == ["The new evidence is checked"],
              "an amendment restates what the member is measured against")
        check(rebased.briefRevision == restated.revision,
              "the member keeps the plan revision it is measured at")
        check(rebased.state == .working, "a restated acceptance keeps the member working")
        await refuses("an acceptance change without a newer revision is refused") {
            _ = try await store.sync(child: restateChild, opener: restateOpener,
                                     plan: try AgentDelegationPlan(brief: brief(acceptance: ["Something else"])))
        }

        // A blocker derived from the step being replaced goes with the step: a
        // restated acceptance returns the member to working with no residue.
        let blockerOpener = UUID().uuidString
        let blockerChild = UUID().uuidString
        _ = try await store.register(child: blockerChild, opener: blockerOpener, brief: brief())
        var haltedPlan = try AgentDelegationPlan(brief: brief())
        haltedPlan = try haltedPlan.blocked(expectedRevision: haltedPlan.revision)
        let haltedMember = try await store.sync(child: blockerChild, opener: blockerOpener, plan: haltedPlan)
        check(haltedMember.state == .blocked && haltedMember.blockers.count == 1,
              "a blocked step shows as a blocker")
        let restatedPlan = try haltedPlan.amendingCurrent(
            AgentDelegationBrief.Step(id: "edit", title: "Edit again", writeRoots: ["Sources"],
                                      capabilities: [.fileWrite]),
            acceptance: ["The revised evidence is checked"],
            expectedRevision: haltedPlan.revision
        )
        let clearedMember = try await store.sync(child: blockerChild, opener: blockerOpener, plan: restatedPlan)
        check(clearedMember.state == .working, "a restated acceptance returns the member to working")
        check(clearedMember.blockers.isEmpty,
              "a restated acceptance drops the blocker derived from the old step")

        print("\(count) assignment store checks passed")
    }
}
