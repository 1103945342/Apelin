import ApelinCore
import Foundation

/// What a terminal task's events mean to the screen: the base64 output bytes,
/// in order, and the three lifecycle facts the page draws. Run by
/// `Tests/TerminalUI/run.sh`.
enum TerminalWireEventCheck {
    static var failures = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("ok   \(message)")
        } else {
            failures += 1
            print("FAIL \(message)")
        }
    }

    static func payload(_ json: String) -> JSONValue? {
        try? JSONCoding.decode(JSONValue.self, from: Data(json.utf8))
    }

    static func run() -> Int {
        failures = 0
        // Output is bytes, and only from base64.
        let hello = TerminalWireEvent.actions(
            kind: "output",
            payload: payload(#"{"base64":"aGVsbG8=","text":"hello"}"#)
        )
        check(hello == [.output(Data("hello".utf8))], "output decodes to bytes, in order")

        let two = TerminalWireEvent.actions(
            kind: "output",
            payload: payload(#"{"base64":"YQ=="}"#)
        ) + TerminalWireEvent.actions(
            kind: "output",
            payload: payload(#"{"base64":"Yg=="}"#)
        )
        check(two == [.output(Data("a".utf8)), .output(Data("b".utf8))], "two events keep their order")

        check(TerminalWireEvent.actions(kind: "output", payload: nil).isEmpty,
              "an output event without a payload carries nothing")
        check(TerminalWireEvent.actions(kind: "output", payload: payload(#"{"text":"hello"}"#)).isEmpty,
              "text alone is never fed to the emulator")
        check(TerminalWireEvent.actions(kind: "output", payload: payload(#"{"base64":"not base64!"}"#)).isEmpty,
              "a payload that does not decode is dropped, not guessed at")
        check(TerminalWireEvent.actions(kind: "output", payload: payload(#"{"base64":""}"#)).isEmpty,
              "an empty output event is nothing to feed")

        // The host cut the history.
        check(TerminalWireEvent.actions(
            kind: "outputTruncated",
            payload: payload(#"{"limit":2097152,"throughSeq":42,"reason":"budget"}"#)
        ) == [.outputTruncated(throughSeq: 42)], "a truncation names the sequence its tail continues from")
        check(TerminalWireEvent.actions(
            kind: "outputTruncated",
            payload: payload(#"{"limit":2097152}"#)
        ) == [.outputTruncated(throughSeq: nil)], "a truncation without a number is still a truncation")
        check(TerminalWireEvent.actions(
            kind: "outputTruncated",
            payload: payload(#"{"throughSeq":0}"#)
        ) == [.outputTruncated(throughSeq: nil)], "a sequence of zero is not a place to start")

        // How the shell ended.
        check(TerminalWireEvent.actions(kind: "exit", payload: payload(#"{"status":3}"#))
              == [.exited(status: 3, signal: nil)], "an exit status is read")
        check(TerminalWireEvent.actions(kind: "exit", payload: payload(#"{"signal":9}"#))
              == [.exited(status: nil, signal: 9)], "a signal is read")
        check(TerminalWireEvent.actions(kind: "exit", payload: payload(#"{}"#))
              == [.exited(status: nil, signal: nil)], "an exit with neither number is still an exit")
        check(TerminalWireEvent.actions(kind: "exit", payload: payload(#"{"status":"three"}"#))
              == [.exited(status: nil, signal: nil)], "a status that is not a number is not invented")

        // The task's own state, by its raw value.
        check(TerminalWireEvent.actions(kind: "state", payload: payload(#"{"state":"interrupted"}"#))
              == [.state("interrupted")], "the final state arrives by its raw value")
        check(TerminalWireEvent.actions(kind: "state", payload: payload(#"{"state":"running"}"#))
              == [.state("running")], "a running state arrives too")
        check(TerminalWireEvent.actions(kind: "state", payload: nil).isEmpty,
              "a state event without a payload carries nothing")

        // Where the shell started.
        check(TerminalWireEvent.actions(
            kind: "started",
            payload: payload(#"{"pid":12,"cwd":"/var/mobile","shell":"/bin/bash"}"#)
        ) == [.started(directory: "/var/mobile", shell: "/bin/bash")], "started names the directory and the shell")

        // Anything this version does not know is ignored, not fed.
        check(TerminalWireEvent.actions(kind: "somethingNew", payload: payload(#"{"base64":"YQ=="}"#)).isEmpty,
              "an unknown event kind carries nothing")

        print(failures == 0 ? "TerminalWireEventCheck: all checks passed" : "TerminalWireEventCheck: \(failures) failed")
        return failures
    }
}
