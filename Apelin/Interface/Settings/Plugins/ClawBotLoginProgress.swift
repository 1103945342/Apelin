import ApelinCore
import ApelinProtocol
import Foundation

/// What the channel's own task has said while it signs in, folded from its
/// events in order.
///
/// The worker emits two kinds: `channelLogin`, the platform's prompt (a QR
/// picture it drew, a link to draw, or one line of text), and `channelState`
/// (`starting`, `awaitingLogin`, `online`). The task's final `state` ends it.
/// Replaying the task from its first event lands on the same step, so a page
/// opened late still shows the code the phone is being asked to scan.
///
/// The prompt is a sign-in secret: it is kept here only to be drawn, and never
/// named in a log, a label or an alert.
struct ClawBotLoginProgress {
    enum Prompt: Hashable {
        /// The picture the platform drew, exactly as it sent it.
        case image(Data)
        /// A link to draw as a code.
        case link(String)
        /// One line the reader acts on, for a platform that asks for words.
        case text(String)
    }

    enum Step: Equatable {
        case starting
        case prompt(Prompt, expiresAt: Date?)
        /// A code is on screen and the platform is waiting for the phone.
        case awaitingLogin(expiresAt: Date?)
        /// WeChat wants the number it put on the phone, typed here. `retry`
        /// says the last one was refused.
        case code(retry: Bool, expiresAt: Date?)
        case online
        case ended(TaskState, message: String?)
    }

    private(set) var step: Step = .starting

    /// How many times a number has been asked for. A page answers one request
    /// and waits, so a number typed once is never sent twice.
    private(set) var codeRequests = 0

    /// The last prompt the platform gave, which stays on screen while the
    /// phone finishes signing in.
    private(set) var prompt: Prompt?
    private(set) var expiresAt: Date?

    /// The channel is up: nothing is left to wait for.
    var isFinished: Bool {
        switch step {
        case .online, .ended:
            return true
        case .starting, .prompt, .awaitingLogin, .code:
            return false
        }
    }

    mutating func apply(_ event: TaskEvent) {
        guard !isFinished else { return }
        let payload = event.payload
        switch event.kind {
        case "channelLogin":
            // The platform asking for the number it shows on the phone is
            // not a prompt: it is a question, and the page asks it in place.
            if payload?["kind"]?.stringValue == "code" {
                let expires = Self.date(payload?["expiresAt"]?.stringValue)
                codeRequests += 1
                expiresAt = expires
                step = .code(retry: payload?["retry"] == .bool(true), expiresAt: expires)
                return
            }
            guard let prompt = Self.prompt(from: payload) else { return }
            let expires = Self.date(payload?["expiresAt"]?.stringValue)
            self.prompt = prompt
            expiresAt = expires
            step = .prompt(prompt, expiresAt: expires)
        case "channelState":
            switch payload?["state"]?.stringValue {
            case ChannelState.starting.rawValue:
                step = .starting
            case ChannelState.awaitingLogin.rawValue:
                step = .awaitingLogin(expiresAt: expiresAt)
            case ChannelState.online.rawValue:
                step = .online
            case ChannelState.paused.rawValue, ChannelState.failed.rawValue:
                let state = ChannelState(rawValue: payload?["state"]?.stringValue ?? "")
                step = .ended(.failed, message: state == .paused
                    ? String(localized: "The channel stood down before it was signed in.")
                    : String(localized: "The sign-in did not finish."))
            default:
                break
            }
        case TaskEvent.stateKind:
            guard let state = payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)),
                  state.isTerminal
            else { return }
            step = state == .succeeded ? .online : .ended(state, message: payload?["message"]?.stringValue)
        default:
            break
        }
    }

    /// The task could not be read any more: gone from the host, or refused.
    mutating func lost(_ message: String) {
        guard !isFinished else { return }
        step = .ended(.failed, message: message)
    }

    private static func prompt(from payload: JSONValue?) -> Prompt? {
        guard let kind = payload?["kind"]?.stringValue,
              let value = payload?["value"]?.stringValue
        else { return nil }
        switch kind {
        case "qrImage":
            guard let data = Data(base64Encoded: value), !data.isEmpty else { return nil }
            return .image(data)
        case "qrURL":
            return value.isEmpty ? nil : .link(value)
        case "text":
            return value.isEmpty ? nil : .text(value)
        default:
            return nil
        }
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}
