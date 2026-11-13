import Foundation

private enum ReadFailure: Error { case expected }

private actor ReadGate {
    private var requests: [(Int, CheckedContinuation<Int, Error>)] = []
    var count: Int { requests.count }

    func read(_ key: Int) async throws -> Int {
        try await withCheckedThrowingContinuation { requests.append((key, $0)) }
    }

    func finish(_ index: Int, _ result: Result<Int, Error>) {
        requests[index].1.resume(with: result)
    }
}

@main
struct SharedModelLoadCheck {
    @MainActor
    static func main() async throws {
        let loader = SharedModelLoad<Int, Int>()
        let gate = ReadGate()
        let fetch: @Sendable (Int) async throws -> Int = { try await gate.read($0) }

        let automatic = Task { try await loader.value(for: 1, fetch: fetch) }
        await waitFor(1, in: gate)
        var pickerStarted = false
        let picker = Task {
            pickerStarted = true
            return try await loader.value(for: 1, fetch: fetch)
        }
        while !pickerStarted { await Task.yield() }
        let joinedCount = await gate.count
        precondition(joinedCount == 1, "automatic selection and the picker share one request")
        automatic.cancel()
        await gate.finish(0, .success(10))
        do {
            _ = try await automatic.value
            preconditionFailure("a cancelled waiter must not apply its result")
        } catch is CancellationError {}
        let picked = try await picker.value
        precondition(picked == 10, "cancelling the automatic check must not cancel the picker")
        precondition(loader.preview(for: 1) == 10)
        precondition(loader.preview(for: 2) == nil, "changed IDs cannot reuse another preview")

        let older = Task { try await loader.value(for: 1, fetch: fetch) }
        await waitFor(2, in: gate)
        let newer = Task { try await loader.value(for: 2, fetch: fetch) }
        await waitFor(3, in: gate)
        await gate.finish(2, .success(20))
        _ = try await newer.value
        await gate.finish(1, .success(11))
        _ = try await older.value
        precondition(loader.preview(for: 2) == 20, "a late old read must not overwrite the new preview")
        precondition(loader.preview(for: 1) == nil)

        let failed = Task { try await loader.value(for: 2, fetch: fetch) }
        await waitFor(4, in: gate)
        await gate.finish(3, .failure(ReadFailure.expected))
        do {
            _ = try await failed.value
            preconditionFailure("read failure must reach the sheet")
        } catch ReadFailure.expected {}
        precondition(loader.preview(for: 2) == 20, "a failure keeps the preview, not an empty success")
        let retry = Task { try await loader.value(for: 2, fetch: fetch) }
        await waitFor(5, in: gate)
        await gate.finish(4, .success(21))
        let retried = try await retry.value
        precondition(retried == 21 && loader.preview(for: 2) == 21, "retry must make a fresh request")
        print("ok: shared model load — coalescing, cancellation isolation, key changes, late replies, failure and retry")
    }

    private static func waitFor(_ count: Int, in gate: ReadGate) async {
        for _ in 0..<2_000 {
            if await gate.count >= count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("model load did not start")
    }
}
