import Foundation

// Lightweight stand-ins for the two host types AgentReportRelay reads. The real
// ones live in AgentApprovals.swift and drag the approval ledger, the task
// registry and the session table's storage; the relay only asks for an entry's
// current task and title, and a child's parent session.
actor AgentSessionTable {
    static let shared = AgentSessionTable()

    struct Entry {
        var task: TaskHandle
        var title: String
    }

    private var entries: [String: Entry] = [:]

    func add(_ entry: Entry, session: String) {
        entries[session] = entry
    }

    func entry(_ session: String) -> Entry? {
        entries[session]
    }

    func setTitle(_ title: String, session: String) {
        entries[session]?.title = title
    }
}

enum AgentSessionLineage {
    struct Record {
        var parentSessionID: String
    }

    private static let lock = NSLock()
    private static var parents: [String: String] = [:]

    static func save(parent: String, session: String) {
        lock.lock()
        parents[session] = parent
        lock.unlock()
    }

    static func load(session: String, state: URL) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return parents[session].map { Record(parentSessionID: $0) }
    }

    static func remove(session: String) {
        lock.lock()
        parents.removeValue(forKey: session)
        lock.unlock()
    }
}

/// What the opener's prompt path saw, and what each attempt answered.
actor DeliveryProbe {
    private var prompts: [AgentPromptRequest] = []
    private var results: [Bool] = []
    private var hold = false
    private var released = false
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

    func expect(_ values: [Bool]) {
        results.append(contentsOf: values)
    }

    func holdDeliveries() {
        hold = true
    }

    func release() {
        hold = false
        released = true
        let pending = waiting
        waiting = [:]
        for (_, continuation) in pending { continuation.resume() }
    }

    func attempt(_ prompt: AgentPromptRequest) async -> Bool {
        prompts.append(prompt)
        let index = prompts.count - 1
        if hold && !released {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiting[index] = continuation
            }
        }
        return index < results.count ? results[index] : true
    }

    var count: Int { prompts.count }

    func prompt(_ index: Int) -> AgentPromptRequest? {
        prompts.indices.contains(index) ? prompts[index] : nil
    }
}

/// The final-account acknowledgement, optionally failing the first time, and
/// whether the wave was still on disk when it ran — the cross-store ordering
/// the relay claims (acknowledge the account, then clear the wave).
final class AckProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    private var calls = 0
    private var wavePresent: [Bool] = []
    private let file: URL

    init(file: URL, failures: Int) {
        self.file = file
        failuresLeft = failures
    }

    func acknowledge(_ opener: String, _ event: String) async throws {
        let failing = recordAttempt()
        if failing {
            throw ApelinError(.unavailable, "injected acknowledgement failure")
        }
    }

    /// Synchronous so the lock is never taken from an async context.
    private func recordAttempt() -> Bool {
        let present: Bool
        if case let .ledger(ledger) = AgentReportStore(file: file).load() {
            present = ledger.wave != nil
        } else {
            present = false
        }
        lock.lock()
        calls += 1
        wavePresent.append(present)
        let failing = failuresLeft > 0
        if failing { failuresLeft -= 1 }
        lock.unlock()
        return failing
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var everyCallSawTheWave: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !wavePresent.isEmpty && wavePresent.allSatisfy { $0 }
    }
}

func scratchDirectory(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("report-relay-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func waitUntil(_ name: String, seconds: Double = 10,
               _ condition: @Sendable () async -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    fatalError("timed out waiting for \(name)")
}

func outboxURL(_ root: URL, _ opener: String) -> URL {
    root.appendingPathComponent("agent-reports", isDirectory: true)
        .appendingPathComponent(opener + ".json")
}

func savedReportLedger(_ root: URL, _ opener: String) -> AgentReportLedger? {
    if case let .ledger(ledger) = AgentReportStore(file: outboxURL(root, opener)).load() {
        return ledger
    }
    return nil
}

func brief(_ objective: String = "Ship the change") -> AgentDelegationBrief {
    AgentDelegationBrief(
        objective: objective,
        acceptance: ["The change is verified"],
        steps: [.init(id: "edit", title: "Edit", writeRoots: ["Sources"],
                      capabilities: [.fileWrite])]
    )
}

func finishedPlan(_ brief: AgentDelegationBrief) throws -> AgentDelegationPlan {
    var plan = try AgentDelegationPlan(brief: brief)
    plan = try plan.requestReview(expectedRevision: plan.revision)
    plan = try plan.accepted(expectedRevision: plan.revision)
    return plan
}

/// The budget the relay measures a wave with: the composed text plus the
/// encoded reports themselves, so a wave is bounded by what it sends.
func budgetedCompose(_ reports: [AgentTurnReport]) -> String {
    let metadata = (try? JSONEncoder().encode(reports))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    return AgentReportRelay.compose(reports) + metadata
}

func promptEvent(_ seq: UInt64, from: String, id: UUID) -> TaskEvent {
    TaskEvent(seq: EventSeq(seq), kind: "prompt",
              payload: .object(["from": .string(from), "id": .string(id.uuidString)]))
}

func messageEvent(_ seq: UInt64, text: String) -> TaskEvent {
    TaskEvent(seq: EventSeq(seq), kind: "message", payload: .object(["text": .string(text)]))
}

func finishedEvent(_ seq: UInt64, reason: String) -> TaskEvent {
    TaskEvent(seq: EventSeq(seq), kind: "finished", payload: .object(["reason": .string(reason)]))
}

func stateEvent(_ seq: UInt64, state: String) -> TaskEvent {
    TaskEvent(seq: EventSeq(seq), kind: TaskEvent.stateKind,
              payload: .object(["state": .string(state)]))
}

@main
struct ReportRelayChecks {
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
        }

        let root1 = try scratchDirectory("reports")
        let probe1 = DeliveryProbe()
        let relay1 = AgentReportRelay()
        await relay1.configure(state: root1) { prompt in
            await probe1.attempt(prompt)
        }
        let opener1 = UUID().uuidString
        let child1 = UUID().uuidString
        let task1 = TaskID.make()
        let message1 = UUID()
        await relay1.registered(child: child1, opener: opener1, task: task1,
                                title: "Child One", openedByOpener: true)
        await relay1.observed(sessionID: child1, taskID: task1,
                              event: promptEvent(1, from: opener1, id: message1))
        await relay1.observed(sessionID: child1, taskID: task1,
                              event: messageEvent(2, text: "work done"))
        await relay1.observed(sessionID: child1, taskID: task1,
                              event: finishedEvent(3, reason: "completed"))
        await waitUntil("the first report wave") { await probe1.count == 1 }
        let first = await probe1.prompt(0)
        check(first != nil, "the delivery callback ran")
        check(first?.sessionID == opener1, "the wave goes to the opener")
        check(first?.reports?.count == 1, "one finished turn makes one report")
        check(first?.reports?.first?.childSessionID == child1, "the report names its child")
        check(first?.reports?.first?.outcome == .completed, "the outcome is the closing event's")
        check(first?.reports?.first?.text == "work done", "the child's answer travels")
        check(first?.fromSessionID == child1, "the sender is the child, not the reader")
        check(first?.messageID != nil, "the wave carries one message ID")
        check(first?.text.contains("work done") == true, "the composed text carries the answer")
        check(first?.text.contains("not the user's instruction") == true,
              "a report is labelled data, not an instruction")
        await waitUntil("the outbox to clear") {
            let ledger = savedReportLedger(root1, opener1)
            return ledger != nil && ledger?.pending.isEmpty == true && ledger?.wave == nil
        }
        check(savedReportLedger(root1, opener1)?.pending.isEmpty == true,
              "an accepted wave leaves the outbox")

        // A stop the reader asked for names the turn that ends next.
        let child2 = UUID().uuidString
        let opener2 = UUID().uuidString
        let task2 = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: task2, kind: .agent), title: "Child Two"),
            session: child2
        )
        await relay1.registered(child: child2, opener: opener2, task: task2,
                                title: "Child Two", openedByOpener: true)
        await relay1.observed(sessionID: child2, taskID: task2,
                              event: promptEvent(1, from: opener2, id: UUID()))
        let stopToken = await relay1.stopped(session: child2, by: .user)
        check(stopToken != nil, "an open turn gives the stop request a token")
        await relay1.resolveStop(stopToken, accepted: true)
        await relay1.observed(sessionID: child2, taskID: task2,
                              event: messageEvent(2, text: "stopped midway"))
        await relay1.observed(sessionID: child2, taskID: task2,
                              event: finishedEvent(3, reason: "aborted"))
        await waitUntil("the stopped turn's wave") { await probe1.count == 2 }
        let stopped = await probe1.prompt(1)?.reports?.first
        check(stopped?.outcome == .aborted, "an aborted turn reports aborted")
        check(stopped?.stoppedBy == .user, "the reader's stop names the turn it ended")

        // A delivery that fails is retried as the same message, and a restart
        // reloads that same UUID and text from disk.
        let root2 = try scratchDirectory("retry")
        let probe2 = DeliveryProbe()
        // Every attempt before the restart fails, so the outbox still holds
        // the wave when the restarted relay reads it.
        await probe2.expect([false, false, false])
        let relay2 = AgentReportRelay()
        await relay2.configure(state: root2) { prompt in
            await probe2.attempt(prompt)
        }
        let opener3 = UUID().uuidString
        let child3 = UUID().uuidString
        let task3 = TaskID.make()
        await relay2.registered(child: child3, opener: opener3, task: task3,
                                title: "Child Three", openedByOpener: true)
        await relay2.observed(sessionID: child3, taskID: task3,
                              event: promptEvent(1, from: opener3, id: UUID()))
        await relay2.observed(sessionID: child3, taskID: task3,
                              event: messageEvent(2, text: "held once"))
        await relay2.observed(sessionID: child3, taskID: task3,
                              event: finishedEvent(3, reason: "completed"))
        await waitUntil("the rejected attempt") { await probe2.count == 1 }
        let held = savedReportLedger(root2, opener3)?.wave
        check(held != nil, "a rejected delivery keeps its wave on disk")
        check(held?.text != nil, "the text is frozen beside the wave's UUID")
        let probe3 = DeliveryProbe()
        let restarted = AgentReportRelay()
        await restarted.configure(state: root2) { prompt in
            await probe3.attempt(prompt)
        }
        await restarted.reopened(opener3)
        await waitUntil("the retried wave") { await probe3.count == 1 }
        let retried = await probe3.prompt(0)
        check(retried?.messageID == held?.id, "a restart retries the same message ID")
        check(retried?.text == held?.text, "a restart retries the same frozen text")
        await waitUntil("the retried wave to clear") {
            savedReportLedger(root2, opener3)?.wave == nil
        }
        check(savedReportLedger(root2, opener3)?.pending.isEmpty == true,
              "the retried wave clears once accepted")

        // Reports that arrive while a delivery is in flight go in the next
        // message, never in the one already handed over.
        let root3 = try scratchDirectory("concurrent")
        let probe4 = DeliveryProbe()
        await probe4.holdDeliveries()
        let relay3 = AgentReportRelay()
        await relay3.configure(state: root3) { prompt in
            await probe4.attempt(prompt)
        }
        let opener4 = UUID().uuidString
        let child4 = UUID().uuidString
        let task4 = TaskID.make()
        let task5 = TaskID.make()
        await relay3.registered(child: child4, opener: opener4, task: task4,
                                title: "Child Four", openedByOpener: true)
        await relay3.observed(sessionID: child4, taskID: task4,
                              event: promptEvent(1, from: opener4, id: UUID()))
        await relay3.observed(sessionID: child4, taskID: task4,
                              event: messageEvent(2, text: "first turn"))
        await relay3.observed(sessionID: child4, taskID: task4,
                              event: finishedEvent(3, reason: "completed"))
        await waitUntil("the held delivery") { await probe4.count == 1 }
        await relay3.observed(sessionID: child4, taskID: task5,
                              event: promptEvent(1, from: opener4, id: UUID()))
        await relay3.observed(sessionID: child4, taskID: task5,
                              event: messageEvent(2, text: "second turn"))
        await relay3.observed(sessionID: child4, taskID: task5,
                              event: finishedEvent(3, reason: "completed"))
        await probe4.release()
        await waitUntil("the second wave") { await probe4.count == 2 }
        let one = await probe4.prompt(0)
        let two = await probe4.prompt(1)
        check(one?.reports?.count == 1, "the in-flight wave carries only what it froze")
        check(one?.reports?.first?.text == "first turn", "the first turn is the first wave")
        check(two?.reports?.count == 1, "a later report is its own wave")
        check(two?.reports?.first?.text == "second turn", "the later turn is the later wave")
        check(one?.messageID != two?.messageID, "the two waves name different messages")
        await waitUntil("both waves to clear") {
            let ledger = savedReportLedger(root3, opener4)
            return ledger != nil && ledger?.pending.isEmpty == true && ledger?.wave == nil
        }
        check(savedReportLedger(root3, opener4)?.pending.isEmpty == true,
              "no report is lost when one arrives during a delivery")

        // A final account is staged by the assignment ledger, found by resume
        // through agent-assignments, delivered as an empty-reports wave, and
        // acknowledged before its wave is cleared; a failed acknowledgement
        // retries the same message.
        let root4 = try scratchDirectory("final")
        let assignments = AgentAssignmentStore(
            directory: root4.appendingPathComponent("agent-assignments", isDirectory: true)
        )
        let opener5 = UUID().uuidString
        let child5 = UUID().uuidString
        let sharedBrief = brief()
        _ = try await assignments.register(child: child5, opener: opener5, brief: sharedBrief)
        let groupRevision = try await assignments.read(opener: opener5)!.groups.first!.revision
        _ = try await assignments.seal(opener: opener5, expectedRevision: groupRevision)
        let plan5 = try finishedPlan(sharedBrief)
        _ = try await assignments.sync(child: child5, opener: opener5, plan: plan5)
        let ready5 = try await assignments.assignment(child: child5, opener: opener5)!
        _ = try await assignments.accept(child: child5, opener: opener5, plan: plan5,
                                         expectedRevision: ready5.revision)
        let account = try await assignments.pendingFinalAccount(opener: opener5)
        check(account != nil, "the sealed, settled group stages a final account")
        let probe5 = DeliveryProbe()
        let ack = AckProbe(file: outboxURL(root4, opener5), failures: 1)
        let relay4 = AgentReportRelay()
        await relay4.configure(
            state: root4,
            account: nil,
            nextFinal: { opener in try await assignments.pendingFinalAccount(opener: opener) },
            nextStatus: { opener in try await assignments.read(opener: opener)?.groups.first?.snapshot() },
            acknowledgeFinal: { opener, event in
                try await ack.acknowledge(opener, event)
                _ = try await assignments.acknowledgeFinalAccount(opener: opener, eventID: event)
            }
        ) { prompt in
            await probe5.attempt(prompt)
        }
        await relay4.resume()
        await waitUntil("the final wave") { await probe5.count == 1 }
        let final = await probe5.prompt(0)
        check(final?.sessionID == opener5, "the final wave goes to the opener")
        check(final?.fromSessionID == opener5, "the final wave is the opener's own host message")
        check(final?.reports?.isEmpty == true, "an empty report list marks the host account")
        check(final?.text.contains(account?.eventID ?? "") == true,
              "the final wave names its stable event ID")
        check(final?.text.contains("not a user instruction") == true,
              "the final wave is labelled host data")
        await waitUntil("the wave to remain after a failed ack") {
            savedReportLedger(root4, opener5)?.wave != nil
        }
        check(ack.callCount == 1, "the acknowledgement was attempted")
        check(savedReportLedger(root4, opener5)?.wave != nil,
              "a failed acknowledgement keeps the wave")
        // No trigger from the test: the relay's bounded retry sends the same
        // wave again by itself.
        await waitUntil("the automatically retried final wave", seconds: 6) {
            await probe5.count == 2
        }
        let finalRetry = await probe5.prompt(1)
        check(finalRetry?.messageID == final?.messageID, "a failed ack retries the same UUID")
        check(finalRetry?.text == final?.text, "a failed ack retries the same text")
        await waitUntil("the acknowledged wave to clear") {
            savedReportLedger(root4, opener5)?.wave == nil
        }
        check(ack.callCount == 2, "the acknowledgement was retried")
        check(ack.everyCallSawTheWave, "the wave exists whenever the account is acknowledged")
        check(try await assignments.pendingFinalAccount(opener: opener5) == nil,
              "an acknowledged final account is no longer pending")
        let settledDeliveries = await probe5.count
        await relay4.accountChanged( opener5)
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(await probe5.count == settledDeliveries,
              "a settled group and its recorded status do not push again")

        // A blocked child is announced at once as a host status wave, and the
        // same status is not pushed twice.
        let root5 = try scratchDirectory("status")
        let statusStore = AgentAssignmentStore(
            directory: root5.appendingPathComponent("agent-assignments", isDirectory: true)
        )
        let opener6 = UUID().uuidString
        let childA = UUID().uuidString
        let childB = UUID().uuidString
        _ = try await statusStore.register(child: childA, opener: opener6, brief: brief())
        _ = try await statusStore.register(child: childB, opener: opener6, brief: brief())
        let workingPlan = try AgentDelegationPlan(brief: brief())
        let blockedPlan = try workingPlan.blocked(expectedRevision: workingPlan.revision)
        _ = try await statusStore.sync(child: childA, opener: opener6, plan: blockedPlan)
        let blockedSnapshot = try await statusStore.read(opener: opener6)?.groups.first?.snapshot()
        let probe6 = DeliveryProbe()
        let relay5 = AgentReportRelay()
        await relay5.configure(
            state: root5,
            account: nil,
            nextFinal: nil,
            nextStatus: { opener in try await statusStore.read(opener: opener)?.groups.first?.snapshot() },
            acknowledgeFinal: nil
        ) { prompt in
            await probe6.attempt(prompt)
        }
        await relay5.accountChanged( opener6)
        await waitUntil("the blocked status wave") { await probe6.count == 1 }
        let statusWave = await probe6.prompt(0)
        check(statusWave?.reports?.isEmpty == true, "a status wave carries no child report")
        check(statusWave?.fromSessionID == opener6, "a status wave is the opener's host message")
        check(statusWave?.text.contains("assignment state changed") == true,
              "the status wave is labelled a state change")
        check(statusWave?.text.contains("blocked") == true, "the blocked member is in the wave")
        check(statusWave?.text.contains(childA) == true, "the wave names the blocked child")
        await waitUntil("the status wave to be acknowledged") {
            savedReportLedger(root5, opener6)?.wave == nil
        }
        check(savedReportLedger(root5, opener6)?.lastStatusKey
                == blockedSnapshot.map { AgentReportRelay.statusKey($0) },
              "the acknowledged status is recorded by its key")
        await relay5.accountChanged( opener6)
        await relay5.reopened(opener6)
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(await probe6.count == 1, "the same status is not pushed twice")
        let amendedPlan = try blockedPlan.amendingCurrent(workingPlan.brief.steps[0],
                                                          expectedRevision: blockedPlan.revision)
        _ = try await statusStore.sync(child: childA, opener: opener6, plan: amendedPlan)
        await relay5.accountChanged( opener6)
        await waitUntil("the changed status wave") { await probe6.count == 2 }
        let changed = await probe6.prompt(1)
        check(changed?.messageID != statusWave?.messageID, "a changed status is a new message")
        check(changed?.text.contains("working") == true,
              "the changed wave reports the member's new state")
        check(changed?.text != statusWave?.text, "the changed wave carries different facts")
        await waitUntil("the changed status to be acknowledged") {
            savedReportLedger(root5, opener6)?.wave == nil
        }

        // An outbox that does not read is never written over and delivers
        // nothing.
        let root6 = try scratchDirectory("broken")
        let brokenOpener = UUID().uuidString
        let brokenChild = UUID().uuidString
        let brokenTask = TaskID.make()
        let reportsFolder = root6.appendingPathComponent("agent-reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsFolder, withIntermediateDirectories: true)
        let garbage = Data("this is not an outbox".utf8)
        let brokenFile = outboxURL(root6, brokenOpener)
        try garbage.write(to: brokenFile)
        let probe7 = DeliveryProbe()
        let relay6 = AgentReportRelay()
        await relay6.configure(state: root6) { prompt in
            await probe7.attempt(prompt)
        }
        await relay6.registered(child: brokenChild, opener: brokenOpener, task: brokenTask,
                                title: "Broken", openedByOpener: true)
        await relay6.observed(sessionID: brokenChild, taskID: brokenTask,
                              event: promptEvent(1, from: brokenOpener, id: UUID()))
        await relay6.observed(sessionID: brokenChild, taskID: brokenTask,
                              event: messageEvent(2, text: "cannot be written"))
        await relay6.observed(sessionID: brokenChild, taskID: brokenTask,
                              event: finishedEvent(3, reason: "completed"))
        await relay6.reopened(brokenOpener)
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(await probe7.count == 0, "an unreadable outbox delivers nothing")
        check(try Data(contentsOf: brokenFile) == garbage,
              "an unreadable outbox is left exactly as it was")
        let linkedOpener = UUID().uuidString
        let linkedFile = outboxURL(root6, linkedOpener)
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: brokenFile)
        let probeLinked = DeliveryProbe()
        let relayLinked = AgentReportRelay()
        await relayLinked.configure(state: root6) { prompt in
            await probeLinked.attempt(prompt)
        }
        let linkedChild = UUID().uuidString
        let linkedTask = TaskID.make()
        await relayLinked.registered(child: linkedChild, opener: linkedOpener, task: linkedTask,
                                     title: "Linked", openedByOpener: true)
        await relayLinked.observed(sessionID: linkedChild, taskID: linkedTask,
                                   event: promptEvent(1, from: linkedOpener, id: UUID()))
        await relayLinked.observed(sessionID: linkedChild, taskID: linkedTask,
                                   event: messageEvent(2, text: "through a link"))
        await relayLinked.observed(sessionID: linkedChild, taskID: linkedTask,
                                   event: finishedEvent(3, reason: "completed"))
        await relayLinked.reopened(linkedOpener)
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(await probeLinked.count == 0, "a linked outbox delivers nothing")
        var linkInfo = stat()
        check(lstat(linkedFile.path, &linkInfo) == 0
                && linkInfo.st_mode & S_IFMT == S_IFLNK,
              "a linked outbox is not replaced by a regular file")

        // A long CJK title is bounded by UTF-8 bytes before the ledger's
        // 256-byte rule sees it, so the claim is stored rather than refused.
        let root7 = try scratchDirectory("title")
        let titleStore = AgentAssignmentStore(
            directory: root7.appendingPathComponent("agent-assignments", isDirectory: true)
        )
        let opener7 = UUID().uuidString
        let child7 = UUID().uuidString
        let brief7 = brief()
        _ = try await titleStore.register(child: child7, opener: opener7, brief: brief7)
        let longTitle = String(repeating: "任", count: 100)
        check(longTitle.utf8.count > 256, "the title is longer than the ledger's byte bound")
        let probe8 = DeliveryProbe()
        let relay7 = AgentReportRelay()
        await relay7.configure(
            state: root7,
            account: { opener, reports in
                if let ledger = try await titleStore.read(opener: opener) {
                    for report in reports where ledger.groups.contains(where: {
                        $0.assignment(report.childSessionID) != nil
                    }) {
                        _ = try await titleStore.recordReport(report, opener: opener)
                    }
                }
                return ""
            },
            nextFinal: nil,
            nextStatus: nil,
            acknowledgeFinal: nil
        ) { prompt in
            await probe8.attempt(prompt)
        }
        let task8 = TaskID.make()
        await relay7.registered(child: child7, opener: opener7, task: task8,
                                title: longTitle, openedByOpener: true)
        await relay7.observed(sessionID: child7, taskID: task8,
                              event: promptEvent(1, from: opener7, id: UUID()))
        await relay7.observed(sessionID: child7, taskID: task8,
                              event: messageEvent(2, text: "标题测试完成"))
        await relay7.observed(sessionID: child7, taskID: task8,
                              event: finishedEvent(3, reason: "completed"))
        await waitUntil("the long-title wave") { await probe8.count == 1 }
        let titled = await probe8.prompt(0)?.reports?.first
        check(titled != nil, "a long title does not stop delivery")
        check((titled?.title?.utf8.count ?? .max) <= 256,
              "the report title is bounded by UTF-8 bytes")
        check(try await titleStore.reports(child: child7, opener: opener7).count == 1,
              "the assignment ledger stores the bounded claim")

        // The wave budget counts the encoded reports' metadata, not just the
        // text: two reports that only fit alone travel in two messages.
        var budgetLedger = AgentReportLedger()
        func answeredReport(_ child: String, _ task: String, _ text: String) -> AgentTurnReport {
            AgentTurnReport(
                childSessionID: child,
                childTaskID: task,
                title: "Member",
                outcome: .completed,
                closingSeq: 1,
                answered: (0..<150).map { _ in UUID() },
                text: text
            )
        }
        let budgetFirst = AgentReportEnvelope(id: UUID(),
                                              report: answeredReport(UUID().uuidString, "one", "first"))
        let budgetSecond = AgentReportEnvelope(id: UUID(),
                                               report: answeredReport(UUID().uuidString, "two", "second"))
        budgetLedger.pending = [budgetFirst, budgetSecond]
        let split = budgetLedger.waveMembers(maxBytes: 8 * 1024, compose: budgetedCompose)
        check(split.count == 1, "the metadata budget splits reports that only fit alone")
        check(split.first == budgetFirst.id, "the oldest report is in the first wave")
        budgetLedger.pending = [budgetFirst]
        let alone = budgetLedger.waveMembers(maxBytes: 8 * 1024, compose: budgetedCompose)
        check(alone == [budgetFirst.id], "one report with its metadata fits the wave budget")

        // A prompt whose encoded reports exceed the delivery bound is never
        // handed over, and the wave it belonged to stays on disk.
        let root8 = try scratchDirectory("encoded-bound")
        let probe9 = DeliveryProbe()
        let relay8 = AgentReportRelay()
        await relay8.configure(state: root8) { prompt in
            await probe9.attempt(prompt)
        }
        let opener8 = UUID().uuidString
        let child8 = UUID().uuidString
        let task9 = TaskID.make()
        await relay8.registered(child: child8, opener: opener8, task: task9,
                                title: "Wide", openedByOpener: true)
        var seq: UInt64 = 0
        for _ in 0..<400 {
            seq += 1
            await relay8.observed(sessionID: child8, taskID: task9,
                                  event: promptEvent(seq, from: opener8, id: UUID()))
        }
        seq += 1
        await relay8.observed(sessionID: child8, taskID: task9,
                              event: messageEvent(seq, text: String(repeating: "x", count: 4000)))
        seq += 1
        await relay8.observed(sessionID: child8, taskID: task9,
                              event: finishedEvent(seq, reason: "completed"))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check(await probe9.count == 0, "an encoded prompt over the bound is not handed over")
        let wedged = savedReportLedger(root8, opener8)
        check(wedged?.wave != nil, "the oversized wave stays on disk for inspection")
        check(wedged?.pending.count == 1, "the report is kept rather than dropped")
        await relay8.reopened(opener8)
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(await probe9.count == 0,
              "the same undeliverable wave is not re-sent as a new message")

        // A provisional stop is not evidence until its RPC is accepted: the
        // turn is held, and a failed RPC leaves the attribution unknown rather
        // than naming the reader.
        let root9 = try scratchDirectory("stop-race")
        let probe10 = DeliveryProbe()
        let relay9 = AgentReportRelay()
        await relay9.configure(state: root9) { prompt in
            await probe10.attempt(prompt)
        }

        let openerA = UUID().uuidString
        let childSA = UUID().uuidString
        let taskA = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskA, kind: .agent), title: "Racing A"),
            session: childSA
        )
        await relay9.registered(child: childSA, opener: openerA, task: taskA,
                                title: "Racing A", openedByOpener: true)
        await relay9.observed(sessionID: childSA, taskID: taskA,
                              event: promptEvent(1, from: openerA, id: UUID()))
        let acceptedToken = await relay9.stopped(session: childSA, by: .user)
        check(acceptedToken != nil, "a provisional stop names its request")
        await relay9.observed(sessionID: childSA, taskID: taskA,
                              event: finishedEvent(2, reason: "aborted"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(await probe10.count == 0,
              "a provisionally stopped turn is not delivered before its RPC resolves")
        await relay9.resolveStop(acceptedToken, accepted: true)
        await waitUntil("the resolved stop wave") { await probe10.count == 1 }
        let confirmed = await probe10.prompt(0)?.reports?.first
        check(confirmed?.outcome == .aborted, "the resolved turn reports aborted")
        check(confirmed?.stoppedBy == .user,
              "an accepted stop names the reader on the turn it closed")

        let openerB = UUID().uuidString
        let childSB = UUID().uuidString
        let taskB = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskB, kind: .agent), title: "Racing B"),
            session: childSB
        )
        await relay9.registered(child: childSB, opener: openerB, task: taskB,
                                title: "Racing B", openedByOpener: true)
        await relay9.observed(sessionID: childSB, taskID: taskB,
                              event: promptEvent(1, from: openerB, id: UUID()))
        let failedToken = await relay9.stopped(session: childSB, by: .user)
        await relay9.observed(sessionID: childSB, taskID: taskB,
                              event: finishedEvent(2, reason: "aborted"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(await probe10.count == 1, "another opener's turn is held separately")
        await relay9.resolveStop(failedToken, accepted: false)
        await waitUntil("the failed-stop wave") { await probe10.count == 2 }
        let unresolved = await probe10.prompt(1)?.reports?.first
        check(unresolved?.outcome == .aborted, "the failed stop's turn still reports aborted")
        check(unresolved?.stoppedBy == nil,
              "a failed stop RPC never attributes the turn to the reader")

        let openerC = UUID().uuidString
        let childSC = UUID().uuidString
        let taskC = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskC, kind: .agent), title: "Racing C"),
            session: childSC
        )
        await relay9.registered(child: childSC, opener: openerC, task: taskC,
                                title: "Racing C", openedByOpener: true)
        await relay9.observed(sessionID: childSC, taskID: taskC,
                              event: promptEvent(1, from: openerC, id: UUID()))
        let earlyToken = await relay9.stopped(session: childSC, by: .opener)
        await relay9.resolveStop(earlyToken, accepted: true)
        await relay9.observed(sessionID: childSC, taskID: taskC,
                              event: finishedEvent(2, reason: "aborted"))
        await waitUntil("the early confirmed stop wave") { await probe10.count == 3 }
        let early = await probe10.prompt(2)?.reports?.first
        check(early?.stoppedBy == .opener,
              "a stop confirmed before the closing event names its caller")

        // A stop accepted after the turn closed annotates the exact closing
        // report, as long as it has not been framed into a wave yet.
        let openerD = UUID().uuidString
        let childSD = UUID().uuidString
        let taskD = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskD, kind: .agent), title: "Racing D"),
            session: childSD
        )
        await relay9.registered(child: childSD, opener: openerD, task: taskD,
                                title: "Racing D", openedByOpener: true)
        await relay9.observed(sessionID: childSD, taskID: taskD,
                              event: promptEvent(1, from: openerD, id: UUID()))
        let afterToken = await relay9.stopped(session: childSD, by: .user)
        await relay9.observed(sessionID: childSD, taskID: taskD,
                              event: finishedEvent(2, reason: "aborted"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(await probe10.count == 3, "a provisionally stopped turn waits for its resolution")
        await relay9.resolveStop(afterToken, accepted: true)
        await waitUntil("the late accepted stop wave") { await probe10.count == 4 }
        let lateAccepted = await probe10.prompt(3)?.reports?.first
        check(lateAccepted?.stoppedBy == .user,
              "an accepted stop after the close annotates that exact report")

        // A failed concurrent request cannot clear an accepted one.
        let openerE = UUID().uuidString
        let childSE = UUID().uuidString
        let taskE = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskE, kind: .agent), title: "Racing E"),
            session: childSE
        )
        await relay9.registered(child: childSE, opener: openerE, task: taskE,
                                title: "Racing E", openedByOpener: true)
        await relay9.observed(sessionID: childSE, taskID: taskE,
                              event: promptEvent(1, from: openerE, id: UUID()))
        let acceptedOne = await relay9.stopped(session: childSE, by: .user)
        let failedOne = await relay9.stopped(session: childSE, by: .opener)
        await relay9.resolveStop(acceptedOne, accepted: true)
        await relay9.resolveStop(failedOne, accepted: false)
        await relay9.observed(sessionID: childSE, taskID: taskE,
                              event: finishedEvent(2, reason: "aborted"))
        await waitUntil("the concurrently stopped wave") { await probe10.count == 5 }
        let concurrent = await probe10.prompt(4)?.reports?.first
        check(concurrent?.stoppedBy == .user,
              "a failed concurrent stop cannot clear an accepted one")

        // A non-terminal state and an event at or below the cursor do not
        // spend the confirmed stop; the real closing event still does.
        let openerF = UUID().uuidString
        let childSF = UUID().uuidString
        let taskF = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskF, kind: .agent), title: "Racing F"),
            session: childSF
        )
        await relay9.registered(child: childSF, opener: openerF, task: taskF,
                                title: "Racing F", openedByOpener: true)
        await relay9.observed(sessionID: childSF, taskID: taskF,
                              event: promptEvent(1, from: openerF, id: UUID()))
        let survivorToken = await relay9.stopped(session: childSF, by: .user)
        await relay9.resolveStop(survivorToken, accepted: true)
        await relay9.observed(sessionID: childSF, taskID: taskF,
                              event: stateEvent(2, state: "running"))
        await relay9.observed(sessionID: childSF, taskID: taskF,
                              event: finishedEvent(1, reason: "aborted"))
        await relay9.observed(sessionID: childSF, taskID: taskF,
                              event: finishedEvent(3, reason: "aborted"))
        await waitUntil("the survived stop wave") { await probe10.count == 6 }
        let survivor = await probe10.prompt(5)?.reports?.first
        check(survivor?.stoppedBy == .user,
              "a non-terminal state and an old closing event do not spend the stop")

        // A stop spent on one turn never names the next.
        let openerG = UUID().uuidString
        let childSG = UUID().uuidString
        let taskG = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskG, kind: .agent), title: "Racing G"),
            session: childSG
        )
        await relay9.registered(child: childSG, opener: openerG, task: taskG,
                                title: "Racing G", openedByOpener: true)
        await relay9.observed(sessionID: childSG, taskID: taskG,
                              event: promptEvent(1, from: openerG, id: UUID()))
        let spentToken = await relay9.stopped(session: childSG, by: .user)
        await relay9.resolveStop(spentToken, accepted: true)
        await relay9.observed(sessionID: childSG, taskID: taskG,
                              event: finishedEvent(2, reason: "completed"))
        await waitUntil("the completed turn's wave") { await probe10.count == 7 }
        let completed = await probe10.prompt(6)?.reports?.first
        check(completed?.outcome == .completed && completed?.stoppedBy == nil,
              "a completed turn reports no stop even when one was confirmed")
        let taskG2 = TaskID.make()
        await relay9.observed(sessionID: childSG, taskID: taskG2,
                              event: promptEvent(1, from: openerG, id: UUID()))
        await relay9.observed(sessionID: childSG, taskID: taskG2,
                              event: finishedEvent(2, reason: "aborted"))
        await waitUntil("the next turn's wave") { await probe10.count == 8 }
        let nextTurn = await probe10.prompt(7)?.reports?.first
        check(nextTurn?.stoppedBy == nil, "a spent stop never names a later turn")

        // A host that dies before the stop resolves cannot later fabricate the
        // reader's attribution: the restarted relay sees only the durable nil.
        let root10 = try scratchDirectory("stop-crash")
        let probe11 = DeliveryProbe()
        let openerH = UUID().uuidString
        let childSH = UUID().uuidString
        let taskH = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskH, kind: .agent), title: "Racing H"),
            session: childSH
        )
        let relayH1 = AgentReportRelay()
        await relayH1.configure(state: root10) { prompt in
            await probe11.attempt(prompt)
        }
        await relayH1.registered(child: childSH, opener: openerH, task: taskH,
                                 title: "Racing H", openedByOpener: true)
        await relayH1.observed(sessionID: childSH, taskID: taskH,
                               event: promptEvent(1, from: openerH, id: UUID()))
        _ = await relayH1.stopped(session: childSH, by: .user)
        await relayH1.observed(sessionID: childSH, taskID: taskH,
                               event: finishedEvent(2, reason: "aborted"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(await probe11.count == 0, "an unresolved stop holds its turn")
        let relayH2 = AgentReportRelay()
        await relayH2.configure(state: root10) { prompt in
            await probe11.attempt(prompt)
        }
        await relayH2.reopened(openerH)
        await waitUntil("the recovered turn") { await probe11.count == 1 }
        let recovered = await probe11.prompt(0)?.reports?.first
        check(recovered?.outcome == .aborted, "the recovered turn reports aborted")
        check(recovered?.stoppedBy == nil,
              "a crash before resolution never fabricates the reader's stop")

        // A stop still in flight holds only that child's closing report. The
        // other child's finished turn goes out first, without waiting for it.
        let root13 = try scratchDirectory("held-report")
        let probe13 = DeliveryProbe()
        let relayHeld = AgentReportRelay()
        await relayHeld.configure(state: root13) { prompt in
            await probe13.attempt(prompt)
        }
        let openerX = UUID().uuidString
        let childAX = UUID().uuidString
        let childBX = UUID().uuidString
        let taskAX = TaskID.make()
        let taskBX = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskAX, kind: .agent), title: "Held A"),
            session: childAX
        )
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskBX, kind: .agent), title: "Held B"),
            session: childBX
        )
        await relayHeld.registered(child: childAX, opener: openerX, task: taskAX,
                                   title: "Held A", openedByOpener: true)
        await relayHeld.registered(child: childBX, opener: openerX, task: taskBX,
                                   title: "Held B", openedByOpener: true)
        await relayHeld.observed(sessionID: childAX, taskID: taskAX,
                                 event: promptEvent(1, from: openerX, id: UUID()))
        await relayHeld.observed(sessionID: childBX, taskID: taskBX,
                                 event: promptEvent(1, from: openerX, id: UUID()))
        let heldToken = await relayHeld.stopped(session: childAX, by: .user)
        await relayHeld.observed(sessionID: childAX, taskID: taskAX,
                                 event: finishedEvent(2, reason: "aborted"))
        await relayHeld.observed(sessionID: childBX, taskID: taskBX,
                                 event: messageEvent(2, text: "B finished"))
        await relayHeld.observed(sessionID: childBX, taskID: taskBX,
                                 event: finishedEvent(3, reason: "completed"))
        await waitUntil("the unheld child's wave") { await probe13.count == 1 }
        let unheld = await probe13.prompt(0)
        check(unheld?.reports?.count == 1, "the other child's report is not held")
        check(unheld?.reports?.first?.childSessionID == childBX,
              "the child without a stop in flight is delivered first")
        await relayHeld.resolveStop(heldToken, accepted: true)
        await waitUntil("the held child's wave") { await probe13.count == 2 }
        let released = await probe13.prompt(1)?.reports?.first
        check(released?.childSessionID == childAX, "the held report follows its resolution")
        check(released?.stoppedBy == .user, "the held report keeps the accepted attribution")

        // The same, with the stop rejected: the held report is delivered last,
        // with no reader attribution.
        let root14 = try scratchDirectory("held-report-failed")
        let probe14 = DeliveryProbe()
        let relayHeld2 = AgentReportRelay()
        await relayHeld2.configure(state: root14) { prompt in
            await probe14.attempt(prompt)
        }
        let openerY = UUID().uuidString
        let childCY = UUID().uuidString
        let childDY = UUID().uuidString
        let taskCY = TaskID.make()
        let taskDY = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskCY, kind: .agent), title: "Held C"),
            session: childCY
        )
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskDY, kind: .agent), title: "Held D"),
            session: childDY
        )
        await relayHeld2.registered(child: childCY, opener: openerY, task: taskCY,
                                    title: "Held C", openedByOpener: true)
        await relayHeld2.registered(child: childDY, opener: openerY, task: taskDY,
                                    title: "Held D", openedByOpener: true)
        await relayHeld2.observed(sessionID: childCY, taskID: taskCY,
                                  event: promptEvent(1, from: openerY, id: UUID()))
        await relayHeld2.observed(sessionID: childDY, taskID: taskDY,
                                  event: promptEvent(1, from: openerY, id: UUID()))
        let rejectedToken = await relayHeld2.stopped(session: childCY, by: .user)
        await relayHeld2.observed(sessionID: childCY, taskID: taskCY,
                                  event: finishedEvent(2, reason: "aborted"))
        await relayHeld2.observed(sessionID: childDY, taskID: taskDY,
                                  event: finishedEvent(2, reason: "completed"))
        await waitUntil("the unheld child's wave after a stop") { await probe14.count == 1 }
        check(await probe14.prompt(0)?.reports?.first?.childSessionID == childDY,
              "the unheld child is delivered while a stop is still in flight")
        await relayHeld2.resolveStop(rejectedToken, accepted: false)
        await waitUntil("the rejected held wave") { await probe14.count == 2 }
        let rejected = await probe14.prompt(1)?.reports?.first
        check(rejected?.childSessionID == childCY, "the rejected child's report follows")
        check(rejected?.stoppedBy == nil, "a rejected stop leaves the held report unattributed")

        // A stop accepted before the turn closes is persisted on that turn, so
        // a restarted relay still reports its aborted and interrupted ends
        // with the caller's attribution; the next turn does not inherit it.
        let root15 = try scratchDirectory("confirmed-stop")
        let relayP1 = AgentReportRelay()
        let unusedProbeA = DeliveryProbe()
        await relayP1.configure(state: root15) { prompt in
            await unusedProbeA.attempt(prompt)
        }
        let openerP = UUID().uuidString
        let childP1 = UUID().uuidString
        let childP2 = UUID().uuidString
        let taskP1 = TaskID.make()
        let taskP2 = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskP1, kind: .agent), title: "Persisted P1"),
            session: childP1
        )
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskP2, kind: .agent), title: "Persisted P2"),
            session: childP2
        )
        await relayP1.registered(child: childP1, opener: openerP, task: taskP1,
                                 title: "Persisted P1", openedByOpener: true)
        await relayP1.registered(child: childP2, opener: openerP, task: taskP2,
                                 title: "Persisted P2", openedByOpener: true)
        await relayP1.observed(sessionID: childP1, taskID: taskP1,
                               event: promptEvent(1, from: openerP, id: UUID()))
        await relayP1.observed(sessionID: childP2, taskID: taskP2,
                               event: promptEvent(1, from: openerP, id: UUID()))
        let persistedToken1 = await relayP1.stopped(session: childP1, by: .user)
        check(persistedToken1 != nil, "the persisted user stop has a live task token")
        await relayP1.resolveStop(persistedToken1, accepted: true)
        let persistedToken2 = await relayP1.stopped(session: childP2, by: .opener)
        check(persistedToken2 != nil, "the persisted opener stop has a live task token")
        await relayP1.resolveStop(persistedToken2, accepted: true)
        let persistedLedger = savedReportLedger(root15, openerP)
        check(persistedLedger?.turns[AgentReportLedger.key(child: childP1,
                                                          task: taskP1.rawValue)]?.confirmedStop
                == .user,
              "an accepted stop on an open turn is persisted on that turn")
        check(persistedLedger?.turns[AgentReportLedger.key(child: childP2,
                                                          task: taskP2.rawValue)]?.confirmedStop
                == .opener,
              "each turn keeps its own caller")
        let probe15 = DeliveryProbe()
        let relayP2 = AgentReportRelay()
        await relayP2.configure(state: root15) { prompt in
            await probe15.attempt(prompt)
        }
        await relayP2.registered(child: childP1, opener: openerP, task: taskP1,
                                 title: "Persisted P1", openedByOpener: false)
        await relayP2.registered(child: childP2, opener: openerP, task: taskP2,
                                 title: "Persisted P2", openedByOpener: false)
        await relayP2.observed(sessionID: childP1, taskID: taskP1,
                               event: finishedEvent(2, reason: "aborted"))
        await waitUntil("the persisted aborted report") { await probe15.count == 1 }
        let persistedAborted = await probe15.prompt(0)?.reports?.first
        check(persistedAborted?.outcome == .aborted, "the restarted aborted turn still reports")
        check(persistedAborted?.stoppedBy == .user,
              "a persisted confirmed stop survives a restart for an aborted turn")
        await relayP2.interrupted(session: childP2, task: taskP2, closing: 5)
        await waitUntil("the persisted interrupted report") { await probe15.count == 2 }
        let persistedInterrupted = await probe15.prompt(1)?.reports?.first
        check(persistedInterrupted?.outcome == .interrupted,
              "the restarted interrupted turn still reports")
        check(persistedInterrupted?.stoppedBy == .opener,
              "a persisted confirmed stop survives a restart for an interrupted turn")
        let taskP1b = TaskID.make()
        await relayP2.observed(sessionID: childP1, taskID: taskP1b,
                               event: promptEvent(1, from: openerP, id: UUID()))
        await relayP2.observed(sessionID: childP1, taskID: taskP1b,
                               event: finishedEvent(2, reason: "aborted"))
        await waitUntil("the next turn after a confirmed stop") { await probe15.count == 3 }
        let nextAfterRestart = await probe15.prompt(2)?.reports?.first
        check(nextAfterRestart?.stoppedBy == nil,
              "a confirmed stop bound to one turn does not name the next")

        // An archived turn written before confirmedStop existed still reads,
        // and simply has no persisted attribution.
        let root16 = try scratchDirectory("old-schema")
        let relayQ1 = AgentReportRelay()
        let unusedProbeB = DeliveryProbe()
        await relayQ1.configure(state: root16) { prompt in
            await unusedProbeB.attempt(prompt)
        }
        let openerQ = UUID().uuidString
        let childQ = UUID().uuidString
        let taskQ = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskQ, kind: .agent), title: "Archived"),
            session: childQ
        )
        await relayQ1.registered(child: childQ, opener: openerQ, task: taskQ,
                                 title: "Archived", openedByOpener: true)
        await relayQ1.observed(sessionID: childQ, taskID: taskQ,
                               event: promptEvent(1, from: openerQ, id: UUID()))
        let archiveToken = await relayQ1.stopped(session: childQ, by: .user)
        check(archiveToken != nil, "the compatibility fixture has a confirmed stop to remove")
        await relayQ1.resolveStop(archiveToken, accepted: true)
        let archiveFile = outboxURL(root16, openerQ)
        var archiveJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: archiveFile)
        ) as! [String: Any]
        var archivedTurns = archiveJSON["turns"] as! [String: Any]
        for (key, value) in archivedTurns {
            var turn = value as! [String: Any]
            turn.removeValue(forKey: "confirmedStop")
            archivedTurns[key] = turn
        }
        archiveJSON["turns"] = archivedTurns
        try JSONSerialization.data(withJSONObject: archiveJSON).write(to: archiveFile,
                                                                     options: .atomic)
        let archiveKey = AgentReportLedger.key(child: childQ, task: taskQ.rawValue)
        if case let .ledger(archived) = AgentReportStore(file: archiveFile).load() {
            check(archived.turns[archiveKey] != nil,
                  "an archived turn without confirmedStop still reads")
            check(archived.turns[archiveKey]?.confirmedStop == nil,
                  "an archived turn carries no invented attribution")
        } else {
            check(false, "the archived outbox still loads")
        }
        let probe16 = DeliveryProbe()
        let relayQ2 = AgentReportRelay()
        await relayQ2.configure(state: root16) { prompt in
            await probe16.attempt(prompt)
        }
        await relayQ2.registered(child: childQ, opener: openerQ, task: taskQ,
                                 title: "Archived", openedByOpener: false)
        await relayQ2.observed(sessionID: childQ, taskID: taskQ,
                               event: finishedEvent(2, reason: "aborted"))
        await waitUntil("the archived turn's report") { await probe16.count == 1 }
        let archivedReport = await probe16.prompt(0)?.reports?.first
        check(archivedReport?.outcome == .aborted, "the archived turn still closes")
        check(archivedReport?.stoppedBy == nil,
              "an archived turn without confirmedStop reports no attribution")

        // A rejected delivery is retried by the relay itself, with the same
        // message, and no reopened/reader input is needed to make it happen.
        let root11 = try scratchDirectory("auto-retry")
        let probeAuto = DeliveryProbe()
        await probeAuto.expect([false])
        let relayAuto = AgentReportRelay()
        await relayAuto.configure(state: root11) { prompt in
            await probeAuto.attempt(prompt)
        }
        let openerAuto = UUID().uuidString
        let childAuto = UUID().uuidString
        let taskAuto = TaskID.make()
        await relayAuto.registered(child: childAuto, opener: openerAuto, task: taskAuto,
                                   title: "Auto", openedByOpener: true)
        await relayAuto.observed(sessionID: childAuto, taskID: taskAuto,
                                 event: promptEvent(1, from: openerAuto, id: UUID()))
        await relayAuto.observed(sessionID: childAuto, taskID: taskAuto,
                                 event: messageEvent(2, text: "auto retried"))
        await relayAuto.observed(sessionID: childAuto, taskID: taskAuto,
                                 event: finishedEvent(3, reason: "completed"))
        await waitUntil("the rejected delivery") { await probeAuto.count == 1 }
        let autoFirst = await probeAuto.prompt(0)
        await waitUntil("the automatic retry", seconds: 6) { await probeAuto.count == 2 }
        let autoSecond = await probeAuto.prompt(1)
        check(autoSecond?.messageID == autoFirst?.messageID,
              "the automatic retry keeps the message ID")
        check(autoSecond?.text == autoFirst?.text,
              "the automatic retry keeps the frozen text")
        await waitUntil("the automatically retried wave to clear", seconds: 6) {
            savedReportLedger(root11, openerAuto)?.wave == nil
        }
        check(savedReportLedger(root11, openerAuto)?.pending.isEmpty == true,
              "no trigger is needed to finish a retried wave")

        // The retry burst is bounded: after 1 s, 3 s and 10 s it stops, and
        // the wave waits on disk for a later external trigger.
        let root12 = try scratchDirectory("retry-cap")
        let probeCap = DeliveryProbe()
        await probeCap.expect([false, false, false, false, false, false])
        let relayCap = AgentReportRelay()
        await relayCap.configure(state: root12) { prompt in
            await probeCap.attempt(prompt)
        }
        let openerCap = UUID().uuidString
        let childCap = UUID().uuidString
        let taskCap = TaskID.make()
        await relayCap.registered(child: childCap, opener: openerCap, task: taskCap,
                                  title: "Cap", openedByOpener: true)
        await relayCap.observed(sessionID: childCap, taskID: taskCap,
                                event: promptEvent(1, from: openerCap, id: UUID()))
        await relayCap.observed(sessionID: childCap, taskID: taskCap,
                                event: messageEvent(2, text: "never accepted"))
        await relayCap.observed(sessionID: childCap, taskID: taskCap,
                                event: finishedEvent(3, reason: "completed"))
        await waitUntil("the first rejected attempt") { await probeCap.count == 1 }
        await waitUntil("the last bounded retry", seconds: 18) { await probeCap.count == 4 }
        let capWave = await probeCap.prompt(0)
        let capRetry = await probeCap.prompt(3)
        check(capRetry?.messageID == capWave?.messageID,
              "every bounded retry keeps the same UUID")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        check(await probeCap.count == 4,
              "the retry burst stops after three attempts")
        check(savedReportLedger(root12, openerCap)?.wave != nil,
              "an exhausted retry burst leaves its wave for a later trigger")

        // A conversation the app deleted takes what the host still owed it: its
        // pending report never goes out, an event that arrives after the
        // deletion reports nothing, and a restarted host reads the same fact.
        let root17 = try scratchDirectory("retired-child")
        let probe17 = DeliveryProbe()
        await probe17.expect([false, false, false, false, false, false])
        let relayR1 = AgentReportRelay()
        await relayR1.configure(state: root17) { prompt in
            await probe17.attempt(prompt)
        }
        let openerR = UUID().uuidString
        let childR = UUID().uuidString
        let taskR = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskR, kind: .agent), title: "Deleted Child"),
            session: childR
        )
        await relayR1.registered(child: childR, opener: openerR, task: taskR,
                                 title: "Deleted Child", openedByOpener: true)
        await relayR1.observed(sessionID: childR, taskID: taskR,
                               event: promptEvent(1, from: openerR, id: UUID()))
        await relayR1.observed(sessionID: childR, taskID: taskR,
                               event: messageEvent(2, text: "work in flight"))
        await relayR1.retired(session: childR)
        let retiredLedger = savedReportLedger(root17, openerR)
        check(retiredLedger?.isRetired(child: childR) == true,
              "a deleted child is recorded as retired")
        check(retiredLedger?.turns.isEmpty == true,
              "the deleted child's open turn is not kept")
        await relayR1.observed(sessionID: childR, taskID: taskR,
                               event: finishedEvent(3, reason: "completed"))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check(await probe17.count == 0,
              "a turn that ends after the deletion is not reported")
        let restartedR = AgentReportRelay()
        await restartedR.configure(state: root17) { prompt in
            await probe17.attempt(prompt)
        }
        await restartedR.registered(child: childR, opener: openerR, task: taskR,
                                    title: "Deleted Child", openedByOpener: false)
        await restartedR.observed(sessionID: childR, taskID: taskR,
                                  event: promptEvent(4, from: openerR, id: UUID()))
        await restartedR.observed(sessionID: childR, taskID: taskR,
                                  event: finishedEvent(5, reason: "completed"))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        check(await probe17.count == 0,
              "a restarted host still reports nothing about a deleted child")

        // A deleted opener is never delivered to again, even when a child it
        // opened finishes afterwards, and its outbox keeps what was owed as a
        // record instead of retrying at a conversation that no longer exists.
        let root18 = try scratchDirectory("retired-opener")
        let probe18 = DeliveryProbe()
        let relayS1 = AgentReportRelay()
        await relayS1.configure(state: root18) { prompt in
            await probe18.attempt(prompt)
        }
        let openerS = UUID().uuidString
        let childS = UUID().uuidString
        let taskS = TaskID.make()
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: taskS, kind: .agent), title: "Child of a Deleted Opener"),
            session: childS
        )
        await AgentSessionTable.shared.add(
            .init(task: TaskHandle(taskID: TaskID.make(), kind: .agent), title: "Opener"),
            session: openerS
        )
        await relayS1.registered(child: openerS, opener: nil, task: TaskID.make(),
                                 title: "Opener", openedByOpener: false)
        await relayS1.registered(child: childS, opener: openerS, task: taskS,
                                 title: "Child of a Deleted Opener", openedByOpener: true)
        await relayS1.observed(sessionID: childS, taskID: taskS,
                               event: promptEvent(1, from: openerS, id: UUID()))
        await relayS1.observed(sessionID: childS, taskID: taskS,
                               event: messageEvent(2, text: "owed to a deleted opener"))
        await relayS1.retired(session: openerS)
        check(savedReportLedger(root18, openerS)?.retired == true,
              "a deleted opener's outbox is retired on disk")
        await relayS1.observed(sessionID: childS, taskID: taskS,
                               event: finishedEvent(3, reason: "completed"))
        let restartedS = AgentReportRelay()
        await restartedS.configure(state: root18) { prompt in
            await probe18.attempt(prompt)
        }
        await restartedS.resume()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        check(await probe18.count == 0,
              "a restarted host never delivers to a deleted opener")
        check(savedReportLedger(root18, openerS)?.retired == true,
              "the retired outbox stays as the record of what was owed")

        print("\(count) report relay checks passed")
    }
}
