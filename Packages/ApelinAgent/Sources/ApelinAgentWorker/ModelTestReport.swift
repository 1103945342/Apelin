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
    /// Each phase as it starts and as it ends, so a page can show the probe
    /// moving. Called without the lock held.
    private let onProgress: (@Sendable (AgentModelTestProgress) -> Void)?

    init(
        cancelRequest: @escaping @Sendable () -> Void,
        progress: (@Sendable (AgentModelTestProgress) -> Void)? = nil,
    ) {
        self.cancelRequest = cancelRequest
        onProgress = progress
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
        lock.lock()
        var announced: [AgentModelTestProgress] = []
        if answer == nil {
            let now = ProcessInfo.processInfo.systemUptime
            if let ended = endActive(at: now) { announced.append(ended) }
            active = (phase, now)
            announced.append(AgentModelTestProgress(phase: phase))
        }
        lock.unlock()
        announce(announced)
    }

    func beginRequest() {
        lock.lock()
        var announced: [AgentModelTestProgress] = []
        if answer == nil {
            let now = ProcessInfo.processInfo.systemUptime
            if let ended = endActive(at: now) { announced.append(ended) }
            requestStarted = now
        }
        lock.unlock()
        announce(announced)
    }

    func record(text: String, thinking: String, event: Bool) {
        lock.lock()
        var announced: [AgentModelTestProgress] = []
        if answer == nil {
            let now = ProcessInfo.processInfo.systemUptime
            if let requestStarted {
                if event, values[.firstEvent] == nil {
                    let firstEvent = milliseconds(now - requestStarted)
                    values[.firstEvent] = firstEvent
                    active = (.response, now)
                    announced.append(AgentModelTestProgress(phase: .firstEvent, milliseconds: firstEvent))
                    announced.append(AgentModelTestProgress(phase: .response))
                }
                if !text.isEmpty, values[.firstText] == nil {
                    let firstText = milliseconds(now - requestStarted)
                    values[.firstText] = firstText
                    announced.append(AgentModelTestProgress(phase: .firstText, milliseconds: firstText))
                }
            }
            // An aborted/error final message may be empty. Keep streamed content.
            if !text.isEmpty { self.text = text }
            if !thinking.isEmpty { self.thinking = thinking }
        }
        lock.unlock()
        announce(announced)
    }

    var phaseName: String {
        lock.lock(); defer { lock.unlock() }
        return active?.0.rawValue ?? (requestStarted == nil ? "preparation" : "waiting for a response")
    }

    func finish(failure: String? = nil) {
        lock.lock()
        guard answer == nil else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        var announced = endActive(at: now).map { [$0] } ?? []
        values[.total] = milliseconds(now - started)
        if let total = values[.total] {
            announced.append(AgentModelTestProgress(phase: .total, milliseconds: total))
        }
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
        // The stages go out before the answer that ends the task.
        announce(announced)
        // Resume first: a transport's cancellation callback cannot hold up UI.
        continuation?.resume(returning: result)
        for task in tasks { task.cancel() }
        cancelRequest()
    }

    /// The phase that ended, as the event that reports its duration.
    private func endActive(at now: TimeInterval) -> AgentModelTestProgress? {
        guard let (phase, start) = active else { return nil }
        let elapsed = milliseconds(now - start)
        values[phase] = elapsed
        active = nil
        return AgentModelTestProgress(phase: phase, milliseconds: elapsed)
    }

    private func announce(_ progress: [AgentModelTestProgress]) {
        guard let onProgress else { return }
        for stage in progress { onProgress(stage) }
    }

    private func milliseconds(_ interval: TimeInterval) -> Double {
        max(0, interval * 1000)
    }
}
