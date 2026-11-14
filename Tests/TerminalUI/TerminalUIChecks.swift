import Foundation

/// Runs every terminal check and fails if any did. Compiled with the sources
/// it checks by `Tests/TerminalUI/run.sh`, which signs and starts it on the
/// device.
@main
struct TerminalUIChecks {
    static func main() {
        let failures = TerminalTargetCheck.run()
            + TerminalWireEventCheck.run()
            + TerminalSessionStoreCheck.run()
            + TerminalSessionListCheck.run()
            + TerminalAttachmentCheck.run()
            + TerminalBatchCheck.run()
            + TerminalFeedCheck.run()
        if failures == 0 {
            print("TerminalUI: all checks passed")
        } else {
            print("TerminalUI: \(failures) failed")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
