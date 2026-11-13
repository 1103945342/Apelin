import Foundation

/// The attachment's decision half: what the next event is, when a truncation
/// asks for a rebuild and where that rebuild starts, what an open that lands
/// after the page moved on is worth, and how many retries are enough. Run by
/// `Tests/TerminalUI/run.sh`.
enum TerminalAttachmentCheck {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("ok   \(message)")
        } else {
            failures += 1
            print("FAIL \(message)")
        }
    }

    static func run() -> Int {
        failures = 0
        // A first attach: the shell is opened, adopted, and replayed.
        var attachment = TerminalAttachment()
        attachment.begin(openShell: true)
        check(attachment.phase == .opening, "a first attach waits for the shell")
        check(attachment.wantsSurface, "a page wants a surface while it attaches")
        check(attachment.shellOpened() == .adopt, "a shell nobody objected to is adopted")
        check(attachment.phase == .catchingUp, "an adopted shell is replayed before it is live")
        attachment.replaying()
        check(attachment.phase == .catchingUp, "replaying keeps the catching-up phase")
        attachment.caughtUp()
        check(attachment.phase == .live, "a drained replay is live")

        // Events: numbered with no gaps, never applied twice.
        var cursor = TerminalAttachment()
        cursor.begin(openShell: false)
        check(cursor.judge(seq: 1) == .apply, "the first event at an empty cursor applies")
        cursor.applied(seq: 1)
        check(cursor.judge(seq: 1) == .duplicate, "the same event is never applied twice")
        check(cursor.judge(seq: 0) == .duplicate, "an older event is a duplicate too")
        check(cursor.judge(seq: 2) == .apply, "the next event applies")
        check(cursor.judge(seq: 4) == .gap, "a jump is a gap, not the next event")
        cursor.applied(seq: 2)
        check(cursor.cursor == 2, "the cursor only moves forward")

        // Truncation: rebuild from where the host says its tail continues, and
        // never be told the same thing twice.
        var truncated = TerminalAttachment()
        truncated.begin(openShell: false)
        truncated.replaying()
        truncated.applied(seq: 10)
        check(truncated.truncated(throughSeq: 42), "the first truncation asks for a rebuild")
        check(truncated.resumeFrom == 42, "the rebuild starts where the host said the tail continues")
        check(truncated.phase == .reconnecting, "a rebuild is a reattach")
        check(truncated.truncated(throughSeq: 42) == false,
              "the same truncation twice does not rebuild for ever")
        check(truncated.resumeFrom == 42, "a refused rebuild leaves the resume point alone")
        truncated.begin(openShell: false)
        check(truncated.cursor == 42, "a rebuilt surface starts replaying at the resume point")
        check(truncated.truncated(throughSeq: 43), "a later, further truncation may rebuild again")
        check(truncated.resumeFrom == 43, "and moves the resume point on")

        // The marker's own sequence is where the tail continues: a marker at
        // the cursor may still rebuild once, and one behind it never does.
        var atCursor = TerminalAttachment()
        atCursor.begin(openShell: false)
        atCursor.applied(seq: 7)
        check(atCursor.truncated(throughSeq: 7), "a marker at the cursor may rebuild once")
        check(atCursor.resumeFrom == 7, "the resume point is the marker's sequence")
        var behind = TerminalAttachment()
        behind.begin(openShell: false)
        behind.applied(seq: 7)
        check(behind.truncated(throughSeq: 5) == false, "a marker behind the cursor rebuilds nothing")
        check(behind.cursor == 7, "and leaves the cursor where it was")

        // Rebuilds are bounded: past the limit the tail is kept, not looped for.
        var bounded = TerminalAttachment()
        bounded.begin(openShell: false)
        var last = UInt64(0)
        var rebuilds = 0
        for step in 1 ... (TerminalAttachment.rebuildLimit + 2) {
            last = UInt64(step) * 10
            bounded.applied(seq: last)
            if bounded.truncated(throughSeq: last + 5) {
                rebuilds += 1
                bounded.begin(openShell: false)
                bounded.applied(seq: last + 5)
            }
        }
        check(rebuilds == TerminalAttachment.rebuildLimit, "rebuilds stop at the limit")

        // A gap asks for one rebuild, then settles for what arrives.
        var gap = TerminalAttachment()
        gap.begin(openShell: false)
        gap.applied(seq: 3)
        check(gap.gapSeen(), "a gap asks for one rebuild")
        check(gap.resumeFrom == 0, "a gap rebuilds from the log's own beginning")
        check(gap.gapSeen() == false, "a second gap does not rebuild again")

        // An open that lands after the page left is kept, not closed.
        var detachedDuringOpen = TerminalAttachment()
        detachedDuringOpen.begin(openShell: true)
        detachedDuringOpen.detach()
        check(detachedDuringOpen.shellOpened() == .adopt,
              "a shell that opens after the page left is kept, not killed")
        check(detachedDuringOpen.wantsShell, "the shell is still wanted after a detach")

        // An open that lands after the reader ended the terminal is closed.
        var terminatedDuringOpen = TerminalAttachment()
        terminatedDuringOpen.begin(openShell: true)
        terminatedDuringOpen.terminate()
        check(terminatedDuringOpen.shellOpened() == .close,
              "a shell that opens after the reader ended it is closed")
        check(terminatedDuringOpen.wantsShell == false, "an ended terminal wants no shell")
        check(terminatedDuringOpen.phase == .ended, "an ended terminal says so")

        // Transient failures retry, then become the reader's decision.
        var retrying = TerminalAttachment()
        retrying.begin(openShell: false)
        var attempts = 0
        while retrying.transientFailure() {
            attempts += 1
        }
        check(attempts == TerminalAttachment.retryLimit, "retries stop at the limit")
        check(retrying.phase == .failed, "past the limit the page is told")
        retrying.recovered()
        check(retrying.retries == 0, "a success resets the retries")
        retrying.begin(openShell: false)
        check(retrying.transientFailure(), "after a success a failure retries again")

        // The host losing the task is an ending, not a retry.
        var lost = TerminalAttachment()
        lost.begin(openShell: false)
        lost.hostLost()
        check(lost.phase == .ended, "a lost task ends the session")
        check(lost.wantsShell == false && lost.wantsSurface == false,
              "a lost task is not something to attach to or show")

        // A shell that keeps writing never gives an empty answer; the fixed end
        // named by the first batch is what ends the replay.
        var busy = TerminalAttachment()
        busy.begin(openShell: false)
        busy.replaying()
        busy.replayEnding(at: 100)
        for seq in 1 ... 100 {
            busy.applied(seq: UInt64(seq))
        }
        check(busy.hasReachedReplayEnd, "the replay ends at the fixed end while the shell writes on")
        check(busy.phase == .catchingUp, "reaching the end is not live until the session says so")
        busy.caughtUp()
        check(busy.phase == .live, "and then it is live")
        check(busy.catchUpEnd == nil, "the next attach names its own end")

        // A host that names no end leaves the caller its own fallback.
        var unnamedEnd = TerminalAttachment()
        unnamedEnd.begin(openShell: false)
        unnamedEnd.replaying()
        unnamedEnd.replayEnding(at: nil)
        unnamedEnd.applied(seq: 5)
        check(unnamedEnd.hasReachedReplayEnd == false, "without a named end there is no boundary")

        // A rebuild starts a new round with its own end.
        var rounds = TerminalAttachment()
        rounds.begin(openShell: false)
        rounds.replaying()
        rounds.replayEnding(at: 50)
        rounds.applied(seq: 50)
        check(rounds.hasReachedReplayEnd, "the first round reaches its end")
        rounds.applied(seq: 60)
        check(rounds.truncated(throughSeq: 60), "a truncation asks for a rebuild")
        rounds.begin(openShell: false)
        check(rounds.catchUpEnd == nil, "a new round starts without an end")
        rounds.replayEnding(at: 200)
        rounds.applied(seq: 150)
        check(rounds.hasReachedReplayEnd == false, "the new round is not done at the old round's end")
        rounds.applied(seq: 200)
        check(rounds.hasReachedReplayEnd, "the new round ends at its own end")

        // Being live again clears the rebuild budget for a later episode.
        var episodes = TerminalAttachment()
        episodes.begin(openShell: false)
        episodes.replaying()
        episodes.replayEnding(at: 10)
        episodes.applied(seq: 10)
        episodes.caughtUp()
        episodes.applied(seq: 20)
        check(episodes.truncated(throughSeq: 30), "a live session may rebuild again later")

        print(failures == 0 ? "TerminalAttachmentCheck: all checks passed" : "TerminalAttachmentCheck: \(failures) failed")
        return failures
    }
}
