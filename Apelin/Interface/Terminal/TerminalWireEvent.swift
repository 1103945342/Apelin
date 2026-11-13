import ApelinCore
import Foundation

/// What one of a terminal task's events means to the screen.
///
/// The reducer is deliberately small and total: the app feeds the emulator the
/// base64 `output` bytes — never the socket's live bytes, so a replayed event
/// and a live one can never arrive in the wrong order — and learns from the
/// rest only what the page draws. Nothing here touches a view or the wire.
enum TerminalWireAction: Equatable {
    /// The shell is up: `cwd` as the host started it and the shell's path.
    case started(directory: String?, shell: String?)
    /// Bytes the shell wrote, in the order the host numbered them.
    case output(Data)
    /// The host dropped older output: what follows is a tail, not the whole
    /// screen. `throughSeq` is the sequence number the following events
    /// continue from, when the host names it: a rebuilt surface must start
    /// there, never from the beginning, or it would be told the same thing
    /// again for ever.
    case outputTruncated(throughSeq: UInt64?)
    /// The shell exited, by status or by signal.
    case exited(status: Int32?, signal: Int32?)
    /// The task's own state, by its raw value (`running`, `interrupted`, …).
    case state(String)
}

enum TerminalWireEvent {
    /// The actions `kind` carries, in order. An event this version does not
    /// know, or one whose payload does not read, carries none: the terminal
    /// keeps running and the log keeps its bytes.
    static func actions(kind: String, payload: JSONValue?) -> [TerminalWireAction] {
        switch kind {
        case "started":
            return [.started(
                directory: payload?["cwd"]?.stringValue,
                shell: payload?["shell"]?.stringValue
            )]
        case "output":
            guard let encoded = payload?["base64"]?.stringValue,
                  let data = Data(base64Encoded: encoded),
                  !data.isEmpty
            else { return [] }
            return [.output(data)]
        case "outputTruncated":
            return [.outputTruncated(throughSeq: sequence(payload?["throughSeq"]))]
        case "exit":
            return [.exited(
                status: statusValue(payload?["status"]),
                signal: statusValue(payload?["signal"])
            )]
        case TaskEventState.kind:
            guard let raw = payload?["state"]?.stringValue else { return [] }
            return [.state(raw)]
        default:
            return []
        }
    }

    /// The task's final event: `state` with `{"state": "succeeded"}`.
    enum TaskEventState {
        static let kind = "state"
    }

    private static func statusValue(_ value: JSONValue?) -> Int32? {
        guard let number = value?.doubleValue, number.isFinite else { return nil }
        return Int32(exactly: number.rounded())
    }

    /// A sequence number as the wire carries it: a positive whole number, or
    /// nothing when the payload does not say.
    private static func sequence(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.doubleValue, number.isFinite, number >= 0,
              let exact = UInt64(exactly: number.rounded()), exact > 0
        else { return nil }
        return exact
    }
}
