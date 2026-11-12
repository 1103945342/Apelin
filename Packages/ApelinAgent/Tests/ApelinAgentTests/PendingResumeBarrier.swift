import Foundation

/// A test gate that deliberately survives cancellation of the stopped run.
actor PendingResumeBarrier {
    private var entered = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var exits: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        let waiting = arrivals
        arrivals.removeAll()
        waiting.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { exits.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        released = true
        let waiting = exits
        exits.removeAll()
        waiting.forEach { $0.resume() }
    }
}
