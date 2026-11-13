import Foundation

/// One batch walked through the attachment exactly as the session does, with
/// the compiler's exclusive-access checks on (`run.sh` passes
/// `-enforce-exclusivity=checked`): a truncation in the middle of a large
/// batch, a newer generation taking over, duplicates, a gap, and a replay the
/// surface would not take. Run by `Tests/TerminalUI/run.sh`.
enum TerminalBatchCheck {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("ok   \(message)")
        } else {
            failures += 1
            print("FAIL \(message)")
        }
    }

    static func items(_ sequences: [UInt64]) -> [TerminalAttachment.BatchItem] {
        sequences.map { TerminalAttachment.BatchItem(seq: $0) }
    }

    static func run() -> Int {
        failures = 0

        // The host's real first page for a trimmed log: the marker's seq is the
        // sequence its tail continues from (300), then 301 onwards. A cursor of
        // zero must resume at 300, not call the jump a gap and rebuild from 0.
        var attachment = TerminalAttachment()
        attachment.begin(openShell: false)
        attachment.replaying()
        attachment.replayEnding(at: 500)
        var batch = [TerminalAttachment.BatchItem(seq: 300, truncation: true, throughSeq: 300)]
        batch.append(contentsOf: items((301 ... 500).map(UInt64.init)))
        var applied: [UInt64] = []
        let outcome = attachment.runBatch(items: batch, isCurrent: { true }) { index in
            // Only external state: the attachment belongs to runBatch while
            // this runs, and touching it here would be an overlapping access.
            applied.append(batch[index].seq)
        }
        check(outcome == .rebuildRequested, "a truncation ends this generation")
        check(applied == [300], "only the marker is applied; the tail belongs to the next surface")
        check(attachment.resumeFrom == 300, "the rebuild starts where the host said its tail continues")
        check(attachment.cursor == 300, "the cursor is the marker's own sequence")
        check(attachment.phase == .reconnecting, "the attachment is ready for a rebuild")
        check(attachment.hasReachedReplayEnd == false, "the batch did not pretend the replay finished")

        // A marker at a cursor that already moved past it is not a jump back.
        var late = TerminalAttachment()
        late.begin(openShell: false)
        late.replaying()
        late.applied(seq: 400)
        let lateOutcome = late.runBatch(
            items: [TerminalAttachment.BatchItem(seq: 300, truncation: true, throughSeq: 300)],
            isCurrent: { true }
        ) { _ in }
        check(lateOutcome == .completed, "an older marker asks for no rebuild")
        check(late.cursor == 400, "an older marker does not move the cursor back")

        // A newer attachment taking over mid-batch stops the old one.
        var superseded = TerminalAttachment()
        superseded.begin(openShell: false)
        superseded.replaying()
        let takenOver = (1 ... 10).map(UInt64.init)
        var currentGeneration = true
        var oldApplied: [UInt64] = []
        let stop = superseded.runBatch(
            items: items(takenOver),
            isCurrent: { currentGeneration }
        ) { index in
            oldApplied.append(takenOver[index])
            if index == 1 {
                currentGeneration = false
            }
        }
        check(stop == .superseded, "a newer generation stops the old batch")
        check(oldApplied == [1, 2], "nothing after the takeover is applied")
        check(superseded.cursor == 2, "the old batch did not move the cursor past its own events")

        // Duplicates are never applied twice.
        var duplicates = TerminalAttachment()
        duplicates.begin(openShell: false)
        var appliedCount = 0
        _ = duplicates.runBatch(
            items: items([1, 1, 2, 2, 3]),
            isCurrent: { true }
        ) { _ in
            appliedCount += 1
        }
        check(appliedCount == 3, "duplicate events are skipped")
        check(duplicates.cursor == 3, "the cursor ends at the last real event")

        // A gap asks for one rebuild from the log's beginning.
        var gap = TerminalAttachment()
        gap.begin(openShell: false)
        let gapOutcome = gap.runBatch(items: items([1, 2, 5]), isCurrent: { true }) { _ in }
        check(gapOutcome == .rebuildRequested, "a gap asks for a rebuild")
        check(gap.resumeFrom == 0, "a gap rebuilds from the log's beginning")
        check(gap.cursor == 0, "a gap does not keep a cursor past the missing bytes")

        // The keys stay closed when the replay never reaches its end: the page
        // and time bounds fail the attempt instead of unlocking a partial screen.
        var stuck = TerminalAttachment()
        stuck.begin(openShell: false)
        stuck.replaying()
        stuck.replayEnding(at: 1_000_000)
        stuck.applied(seq: 10)
        check(stuck.hasReachedReplayEnd == false, "a replay short of its end is not caught up")
        check(stuck.phase == .catchingUp, "and it is not live either")

        // A replay the surface will not take is retried a bounded number of
        // times, then the session says it failed rather than opening the keys.
        var recovery = TerminalAttachment()
        recovery.begin(openShell: false)
        recovery.replaying()
        var allowed = 0
        while recovery.replayRecoveryAllowed() {
            allowed += 1
        }
        check(allowed == TerminalAttachment.replayRecoveryLimit,
              "replay recoveries stop at the limit")
        check(recovery.phase == .failed, "past the limit the session is failed, not live")
        recovery.begin(openShell: false)
        check(recovery.replayRecoveryAllowed() == false,
              "an automatic reattach does not reset the replay budget")
        recovery.restart()
        check(recovery.replayRecoveryAllowed(),
              "the reader's Try Again resets it once")

        // Reaching live resets both budgets for a later episode.
        var later = TerminalAttachment()
        later.begin(openShell: false)
        later.replaying()
        later.replayEnding(at: 5)
        for seq in 1 ... 5 {
            later.applied(seq: UInt64(seq))
        }
        later.caughtUp()
        later.applied(seq: 10)
        check(later.truncated(throughSeq: 20), "a live session may rebuild again")
        check(later.hasReachedReplayEnd == false, "the new round has no end until its first batch")

        print(failures == 0 ? "TerminalBatchCheck: all checks passed" : "TerminalBatchCheck: \(failures) failed")
        return failures
    }
}
