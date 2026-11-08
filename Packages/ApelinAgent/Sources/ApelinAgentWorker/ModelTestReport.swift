import ApelinProtocol
import Foundation

/// A report and a one-shot completion gate. The deadline returns even when a
/// provider ignores Swift cancellation; late callbacks cannot change the report.
/// Every mutable field is protected by `lock`; no callback runs while it is held.
final class ModelTestReport: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var active: (AgentModelTestPhase, TimeInterval)?
    private var requestStarted: TimeInterval?
    private var values: [AgentModelTestPhase: Double] = [:]
    private var text = ""
    private var thinking = ""
    private var answer: AgentModelTestResponse?
    private var continuation: CheckedContinuation<AgentModelTestResponse, Never>?
    private var tasks: [Task<Void, Never>] = []
    private let cancelRequest: @Sendable () -> Void

    init(cancelRequest: @escaping @Sendable () -> Void) {
        self.cancelRequest = cancelRequest
    }

    func attach(_ continuation: CheckedContinuation<AgentModelTestResponse, Never>) {
        lock.lock()
        if let answer {
            lock.unlock()
            continuation.resume(returning: answer)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func attach(tasks: [Task<Void, Never>]) {
        lock.lock()
        let finished = answer != nil
        if !finished { self.tasks = tasks }
        lock.unlock()
        if finished { for task in tasks { task.cancel() } }
    }

    func begin(_ phase: AgentModelTestPhase) {
        lock.lock(); defer { lock.unlock() }
        guard answer == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        endActive(at: now)
        active = (phase, now)
    }

    func beginRequest() {
        lock.lock(); defer { lock.unlock() }
        guard answer == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        endActive(at: now)
        requestStarted = now
    }

    func record(text: String, thinking: String, event: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard answer == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let requestStarted {
            if event, values[.firstEvent] == nil {
                values[.firstEvent] = milliseconds(now - requestStarted)
                active = (.response, now)
            }
            if !text.isEmpty, values[.firstText] == nil {
                values[.firstText] = milliseconds(now - requestStarted)
            }
        }
        // An aborted/error final message may be empty. Keep streamed content.
        if !text.isEmpty { self.text = text }
        if !thinking.isEmpty { self.thinking = thinking }
    }

    var phaseName: String {
        lock.lock(); defer { lock.unlock() }
        return active?.0.rawValue ?? (requestStarted == nil ? "preparation" : "waiting for a response")
    }

    func finish(failure: String? = nil) {
        lock.lock()
        guard answer == nil else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        endActive(at: now)
        values[.total] = milliseconds(now - started)
        let empty = (text + thinking).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let failure = failure ?? (empty ? "The model returned an empty response." : nil)
        let result = AgentModelTestResponse(
            success: failure == nil,
            stages: AgentModelTestPhase.allCases.compactMap { phase in
                values[phase].map { AgentModelTestStage(name: phase, milliseconds: $0) }
            },
            text: text,
            thinking: thinking,
            failure: failure,
        )
        answer = result
        let continuation = continuation
        self.continuation = nil
        let tasks = tasks
        self.tasks = []
        lock.unlock()
        // Resume first: a transport's cancellation callback cannot hold up UI.
        continuation?.resume(returning: result)
        for task in tasks { task.cancel() }
        cancelRequest()
    }

    private func endActive(at now: TimeInterval) {
        if let (phase, start) = active { values[phase] = milliseconds(now - start) }
        active = nil
    }

    private func milliseconds(_ interval: TimeInterval) -> Double {
        max(0, interval * 1000)
    }
}
