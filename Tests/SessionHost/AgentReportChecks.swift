import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

// The report outbox (`Apelind/Session/Agent/AgentReportOutbox.swift`): which
// turns are reported, what a report carries, what a stop is bound to, what a
// delivery acknowledges, and what a file that does not read refuses to become.

func agentReportChecks(scratch: URL) async {
    let opener = UUID().uuidString.lowercased()
    let child = UUID().uuidString.lowercased()
    let other = UUID().uuidString.lowercased()
    let task = UUID().uuidString.lowercased()
    let message = UUID()

    func opened() -> AgentReportLedger {
        var ledger = AgentReportLedger()
        _ = ledger.seed(child: child, task: task)
        return ledger
    }

    func deliver(_ ledger: inout AgentReportLedger, _ event: AgentReportEvent, stopped: AgentTurnStoppedBy? = nil)
        -> AgentTurnReport?
    {
        ledger.apply(
            event,
            child: child,
            task: task,
            opener: opener,
            title: "Build it",
            stopped: stopped
        )
    }

    // MARK: - A turn the opener started is reported when it ends

    do {
        var ledger = opened()
        _ = deliver(&ledger, AgentReportEvent(seq: 1, kind: .prompt, message: UUID()))
        _ = deliver(&ledger, AgentReportEvent(seq: 2, kind: .message, text: "done, and here is why"))
        let report = deliver(&ledger, AgentReportEvent(seq: 3, kind: .finished, reason: "completed"))
        check(report?.outcome == .completed && report?.closingSeq == 3, "the opening turn is reported when it ends")
        check(report?.childSessionID == child && report?.childTaskID == task, "the report names the child and its task")
        check(report?.answered.isEmpty == true, "the opening prompt has no message id to answer")
        check(report?.text == "done, and here is why" && report?.title == "Build it", "the report carries the last answer")
        check(ledger.pending.count == 1 && ledger.turns.isEmpty, "the report enters the outbox once and the turn closes")
        check(ledger.cursors[AgentReportLedger.key(child: child, task: task)] == 3, "the cursor is the closing event")

        // The same closing event, read again (a retried append, a replayed log).
        let again = deliver(&ledger, AgentReportEvent(seq: 3, kind: .finished, reason: "completed"))
        check(again == nil && ledger.pending.count == 1, "one closing event is one report, however often it is read")
    }

    // MARK: - A turn the reader held with that child is nobody else's

    do {
        var ledger = AgentReportLedger()
        _ = deliver(&ledger, AgentReportEvent(seq: 1, kind: .prompt, message: UUID()))
        _ = deliver(&ledger, AgentReportEvent(seq: 2, kind: .message, text: "private answer"))
        let report = deliver(&ledger, AgentReportEvent(seq: 3, kind: .finished, reason: "completed"))
        check(report == nil && ledger.pending.isEmpty, "a turn no message from the opener reached makes no report")
        check(ledger.turns.isEmpty, "and its turn is still closed")

        var fromAnother = AgentReportLedger()
        _ = fromAnother.apply(
            AgentReportEvent(seq: 1, kind: .prompt, from: other, message: UUID()),
            child: child,
            task: task,
            opener: opener,
            title: nil,
            stopped: nil
        )
        check(
            fromAnother.apply(
                AgentReportEvent(seq: 2, kind: .finished, reason: "completed"),
                child: child,
                task: task,
                opener: opener,
                title: nil,
                stopped: nil
            ) == nil,
            "another conversation's message is not the opener's"
        )
    }

    // MARK: - The opener's messages are answered, in order and once

    do {
        var ledger = opened()
        let second = UUID()
        _ = deliver(&ledger, AgentReportEvent(seq: 1, kind: .prompt, message: UUID()))
        _ = deliver(&ledger, AgentReportEvent(seq: 2, kind: .prompt, from: opener, message: message))
        _ = deliver(&ledger, AgentReportEvent(seq: 3, kind: .prompt, from: opener, message: message))
        _ = deliver(&ledger, AgentReportEvent(seq: 4, kind: .prompt, from: opener, message: second))
        let report = deliver(&ledger, AgentReportEvent(seq: 5, kind: .finished, reason: "completed"))
        check(report?.answered == [message, second], "the messages it answered are the opener's, oldest first, once each")
    }

    // MARK: - A replayed log is history, not a turn now

    do {
        var ledger = opened()
        let replayed = deliver(&ledger, AgentReportEvent(seq: 9, historical: true, kind: .message, text: "old answer"))
        check(replayed == nil && ledger.turns.count == 1, "a replayed event changes nothing")
        _ = deliver(&ledger, AgentReportEvent(seq: 10, historical: true, kind: .finished, reason: "completed"))
        check(ledger.pending.isEmpty && ledger.turns.count == 1, "and a replayed end reports nothing")

        // The seeded turn is still read from the first live event.
        _ = deliver(&ledger, AgentReportEvent(seq: 11, kind: .prompt))
        let report = deliver(&ledger, AgentReportEvent(seq: 12, kind: .finished, reason: "completed"))
        check(report?.closingSeq == 12, "the live turn after a replay is reported on its own closing event")
    }

    // MARK: - A stop names the turn it was asked for, and only an aborted one

    do {
        var stops = AgentReportStops()
        stops.note(session: child, by: .user, task: task)
        check(stops.take(session: child, task: "another task") == nil, "a note for one task names no other turn")
        check(stops.take(session: child, task: task) == nil, "and the close it did not belong to spends it")

        stops.note(session: child, by: .opener, task: task)
        var ledger = opened()
        _ = deliver(&ledger, AgentReportEvent(seq: 1, kind: .prompt))
        let aborted = deliver(
            &ledger,
            AgentReportEvent(seq: 2, kind: .finished, reason: "aborted"),
            stopped: stops.take(session: child, task: task)
        )
        check(aborted?.outcome == .aborted && aborted?.stoppedBy == .opener, "an aborted turn says who stopped it")

        stops.note(session: child, by: .user, task: task)
        var completed = opened()
        _ = deliver(&completed, AgentReportEvent(seq: 1, kind: .prompt))
        let own = deliver(
            &completed,
            AgentReportEvent(seq: 2, kind: .finished, reason: "completed"),
            stopped: stops.take(session: child, task: task)
        )
        check(own?.stoppedBy == nil, "a turn that ended by itself names no one, whatever a stop said")

        stops.note(session: child, by: .user, task: task)
        stops.clear(session: child)
        check(stops.take(session: child, task: task) == nil, "a stop the host could not forward is not kept")
    }

    // MARK: - A task that ends without its run saying so

    do {
        var ledger = opened()
        _ = deliver(&ledger, AgentReportEvent(seq: 1, kind: .prompt))
        _ = deliver(&ledger, AgentReportEvent(seq: 2, kind: .state, state: "running"))
        check(ledger.turns.count == 1, "a task that is still running closes nothing")
        let interrupted = deliver(
            &ledger,
            AgentReportEvent(seq: 3, kind: .state, state: "cancelled"),
            stopped: .user
        )
        check(
            interrupted?.outcome == .interrupted && interrupted?.stoppedBy == .user,
            "a task the app closed ends its turn as interrupted, by the reader"
        )

        var detached = opened()
        _ = deliver(&detached, AgentReportEvent(seq: 1, kind: .prompt))
        let gone = detached.interrupted(
            child: child,
            task: task,
            closing: 7,
            stoppedBy: nil,
            title: nil
        )
        check(
            gone?.outcome == .interrupted && gone?.stoppedBy == .host && gone?.closingSeq == 7,
            "a task whose worker went away is interrupted by the host"
        )
        let twice = detached.interrupted(child: child, task: task, closing: 7, stoppedBy: nil, title: nil)
        check(twice == nil, "and it is not reported twice")
    }

    // MARK: - What a delivery acknowledges, and what it leaves

    do {
        var ledger = opened()
        _ = deliver(&ledger, AgentReportEvent(seq: 1, kind: .prompt))
        _ = deliver(&ledger, AgentReportEvent(seq: 2, kind: .finished, reason: "completed"))
        let waveID = UUID()
        let members = ledger.waveMembers(maxBytes: AgentReportLedger.maximumMessageBytes) { _ in "wave" }
        ledger.wave = AgentReportWave(id: waveID, members: members)
        check(members.count == 1 && ledger.envelopes(of: ledger.wave!).count == 1, "the wave holds the one report")

        // A second child's report lands while that message is under way.
        let later = UUID().uuidString.lowercased()
        let laterTask = UUID().uuidString.lowercased()
        _ = ledger.seed(child: later, task: laterTask)
        _ = ledger.apply(
            AgentReportEvent(seq: 1, kind: .prompt),
            child: later,
            task: laterTask,
            opener: opener,
            title: nil,
            stopped: nil
        )
        _ = ledger.apply(
            AgentReportEvent(seq: 2, kind: .finished, reason: "failed"),
            child: later,
            task: laterTask,
            opener: opener,
            title: nil,
            stopped: nil
        )
        check(ledger.pending.count == 2, "a report that arrived meanwhile is in the outbox")

        ledger.acknowledge(AgentReportWave(id: waveID, members: members))
        check(ledger.pending.count == 1 && ledger.pending[0].report.childSessionID == later,
              "the acknowledgement removes only the envelope the message carried")
        check(ledger.wave == nil, "and the next delivery starts a message of its own")
    }

    // MARK: - A wave keeps its identity, and its members are never dropped

    do {
        var ledger = opened()
        for index in 0 ..< 3 {
            var turn = AgentReportLedger()
            _ = turn.seed(child: child, task: task)
            _ = turn.apply(
                AgentReportEvent(seq: 1, kind: .prompt),
                child: child,
                task: task,
                opener: opener,
                title: nil,
                stopped: nil
            )
            let finished = turn.apply(
                AgentReportEvent(seq: UInt64(index + 2), kind: .finished, reason: "completed"),
                child: child,
                task: task,
                opener: opener,
                title: nil,
                stopped: nil
            )
            if let finished {
                ledger.pending.append(AgentReportEnvelope(id: UUID(), report: finished))
            }
        }
        check(ledger.pending.count == 3, "three turns are three reports")
        // A message holds one report's body and nothing more.
        let oneAtATime = ledger.waveMembers(maxBytes: 10) { reports in
            String(repeating: "x", count: 20 * reports.count)
        }
        check(oneAtATime.count == 1, "a message that has room for one report carries one")
        let waveID = UUID()
        ledger.wave = AgentReportWave(id: waveID, members: oneAtATime)
        ledger.acknowledge(AgentReportWave(id: waveID, members: oneAtATime))
        check(ledger.pending.count == 2, "the reports that did not fit wait for the next message")
        let next = ledger.waveMembers(maxBytes: 10) { reports in
            String(repeating: "x", count: 20 * reports.count)
        }
        check(next.count == 1 && !oneAtATime.contains(next[0]), "and the next message takes the next report")
    }

    // MARK: - The file is the state: one write, and a corrupt one is left alone

    do {
        let folder = scratch.appendingPathComponent("reports-\(UUID().uuidString)", isDirectory: true)
        let store = AgentReportStore(file: folder.appendingPathComponent("\(opener).json"))
        var file = AgentReportFile(store: store)
        check(!file.blocked && file.ledger.pending.isEmpty, "an outbox with no file starts empty")
        _ = file.commit { _ = $0.seed(child: child, task: task) }
        _ = file.commit { draft in
            _ = draft.apply(
                AgentReportEvent(seq: 1, kind: .prompt),
                child: child,
                task: task,
                opener: opener,
                title: nil,
                stopped: nil
            )
        }
        _ = file.commit { draft in
            _ = draft.apply(
                AgentReportEvent(seq: 2, kind: .finished, reason: "completed"),
                child: child,
                task: task,
                opener: opener,
                title: nil,
                stopped: nil
            )
        }
        check(file.ledger.pending.count == 1, "the report is in the outbox the host holds")
        let saved = try? Data(contentsOf: store.file)
        check(saved != nil, "and it is on disk")
        let reopened = AgentReportFile(store: store)
        check(reopened.ledger == file.ledger, "an outbox reads back exactly as it was written")
        check(reopened.ledger.pending.first?.id == file.ledger.pending.first?.id,
              "the envelope keeps its identity across a restart")

        // The wave under way keeps its message ID too, so a redelivery is the
        // same message and the opener drops a second copy.
        var wave = reopened
        let waveID = UUID()
        wave.commit { draft in
            draft.wave = AgentReportWave(id: waveID, members: draft.pending.map { $0.id })
        }
        let afterRestart = AgentReportFile(store: store)
        check(afterRestart.ledger.wave?.id == waveID, "a message under way is the same one after a restart")

        var repaired = wave
        repaired.commit { draft in
            draft.wave = AgentReportWave(id: UUID(), members: [UUID()])
        }
        let repairedAgain = AgentReportFile(store: store)
        check(repairedAgain.ledger.wave == nil, "a wave naming an envelope the outbox lost starts again")

        // A file that does not read is never written over.
        let bytes = Data("{ not an outbox".utf8)
        try? bytes.write(to: store.file)
        var broken = AgentReportFile(store: store)
        check(broken.blocked, "a file that does not read closes the outbox")
        let kept = broken.commit { _ = $0.seed(child: child, task: task) }
        check(!kept, "and nothing is written through it")
        check((try? Data(contentsOf: store.file)) == bytes, "so the file is exactly what it was")

        // A file another version wrote is not this host's to overwrite either.
        let future = Data(#"{"cursors":{},"pending":[],"turns":{},"version":99}"#.utf8)
        try? future.write(to: store.file)
        check(store.load() == .unreadable("version 99 is not \(AgentReportLedger.version)"),
              "an outbox of another version is reported, not read")
        check((try? Data(contentsOf: store.file)) == future, "and not replaced")
    }

    // MARK: - A save that fails moves nothing

    do {
        let folder = scratch.appendingPathComponent("reports-readonly-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        check(chmod(folder.path, 0o500) == 0, "the folder can be made unwritable")
        var file = AgentReportFile(store: AgentReportStore(file: folder.appendingPathComponent("\(opener).json")))
        let saved = file.commit { _ = $0.seed(child: child, task: task) }
        check(!saved, "a write that fails is reported as unsaved")
        check(file.ledger.turns.isEmpty, "and the outbox in memory did not move")
        check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(opener).json").path),
              "and nothing was left on disk")
        _ = chmod(folder.path, 0o700)
    }

    // MARK: - A body cut to its budget is cut at a character

    do {
        let long = String(repeating: "é", count: 3000)
        let bounded = AgentReportLedger.bounded(long, bytes: 101)
        check(bounded.truncated && bounded.text.utf8.count <= 101, "a long answer is cut to the budget")
        check(bounded.text.utf8.count % 2 == 0, "and never inside a character")
        let short = AgentReportLedger.bounded("done", bytes: 101)
        check(!short.truncated && short.text == "done", "an answer inside the budget is kept whole")
    }
}
