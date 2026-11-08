import Foundation

/// Standalone regression harness, compiled with the production wire values and
/// ModelTestReport (see AGENTS.md). No network or saved credentials are used.
@main
struct ModelConnectivityCheck {
    static func main() async throws {
        let success = await result { report in
            report.begin(.credentials)
            Thread.sleep(forTimeInterval: 0.003)
            report.begin(.preparation)
            report.begin(.authorization)
            report.beginRequest()
            report.record(text: "", thinking: "", event: true)
            report.record(text: "Hello", thinking: "Thought", event: true)
            report.record(text: "Hello world", thinking: "Thought done", event: true)
            report.finish()
        }
        precondition(success.success && success.failure == nil)
        precondition(success.text == "Hello world" && success.thinking == "Thought done")
        precondition(success.stages.count == 7)
        let stages = Dictionary(uniqueKeysWithValues: success.stages.map { ($0.name, $0.milliseconds) })
        precondition(stages[.firstText]! >= stages[.firstEvent]!)
        precondition(stages[.credentials]! > stages[.preparation]!)
        precondition(success.stages.allSatisfy { $0.milliseconds >= 0 && $0.milliseconds.isFinite })
        let data = try JSONEncoder().encode(success)
        let decoded = try JSONDecoder().decode(AgentModelTestResponse.self, from: data)
        precondition(decoded == success)

        let partial = await result { report in
            report.begin(.credentials)
            report.begin(.preparation)
            report.begin(.authorization)
            report.beginRequest()
            report.record(text: "partial", thinking: "", event: true)
            report.record(text: "", thinking: "", event: false)
            report.finish(failure: "transport failure")
            report.record(text: "late reply", thinking: "", event: true)
            report.finish()
        }
        precondition(!partial.success && partial.text == "partial")
        precondition(partial.failure == "transport failure")

        let credentials = await result { report in
            report.begin(.credentials)
            report.finish(failure: "missing sign-in")
        }
        precondition(credentials.stages.map(\.name) == [.credentials, .total])
        let empty = await result { report in
            report.beginRequest()
            report.finish()
        }
        precondition(!empty.success && empty.failure?.contains("empty") == true)
        precondition(!empty.stages.contains { $0.name == .firstText || $0.name == .firstEvent })

        // Cancellation may win before the continuation/task handles attach.
        let early = ModelTestReport {}
        early.finish(failure: "cancelled")
        let cancelled = await withCheckedContinuation { early.attach($0) }
        precondition(!cancelled.success && cancelled.failure == "cancelled")

        // A timeout must not await an uncooperative provider. Late completion
        // and concurrent completion attempts must never resume twice.
        let report = ModelTestReport {}
        let before = ProcessInfo.processInfo.systemUptime
        let timedOut = await withCheckedContinuation { continuation in
            report.attach(continuation)
            report.begin(.authorization)
            let operation = Task {
                await withCheckedContinuation { wait in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { wait.resume() }
                }
                report.finish(failure: "late")
            }
            let timeout = Task {
                try? await Task.sleep(for: .milliseconds(10))
                report.finish(failure: "timeout")
            }
            report.attach(tasks: [operation, timeout])
        }
        precondition(timedOut.failure == "timeout")
        precondition(ProcessInfo.processInfo.systemUptime - before < 1)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { report.finish(failure: "late race") } }
        }
        print("PASS: stage durations, latency, wire round-trip, partial failure, empty reply, early cancellation, bounded timeout and completion races")
    }

    private static func result(_ body: @Sendable (ModelTestReport) -> Void) async -> AgentModelTestResponse {
        let report = ModelTestReport {}
        return await withCheckedContinuation { continuation in
            report.attach(continuation)
            body(report)
        }
    }
}
