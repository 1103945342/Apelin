// The device-side run of Tests/SessionHost/TerminalChecks.swift: the bounded
// terminal history, where a terminal starts, and a real pty with an
// input-only socket. The checks are the Mac harness's; only this entry and
// the stand-ins beside it are the device's, because those two stages leave
// the packages as separate modules and this one compiles everything as a
// single module (see Scripts/test-terminal.sh, which strips the package
// imports from every file it copies).

import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// The counters live in a class: a top-level `var` is main-actor isolated, and
/// the checks run from wherever an await resumes.
final class Tally: @unchecked Sendable {
    var failures = 0
    var checks = 0
}

let tally = Tally()

func check(_ condition: @autoclosure () -> Bool, _ what: String, line: UInt = #line) {
    tally.checks += 1
    if !condition() {
        tally.failures += 1
        print("FAIL \(what) (line \(line))")
    }
}

func expectErrorAsync(
    _ what: String,
    code: ApelinError.Code? = nil,
    line: UInt = #line,
    _ body: () async throws -> Void,
) async {
    tally.checks += 1
    do {
        try await body()
        tally.failures += 1
        print("FAIL \(what): no error (line \(line))")
    } catch let error as ApelinError {
        if let code, error.code != code {
            tally.failures += 1
            print("FAIL \(what): \(error) (line \(line))")
        }
    } catch {
        if code != nil {
            tally.failures += 1
            print("FAIL \(what): \(error) (line \(line))")
        }
    }
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("apelin-terminal-checks-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let scratchPath = CanonicalPath.resolve(scratch.path)!

func write(_ path: String, _ text: String) {
    try! FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true,
    )
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
}

try await terminalChecks(scratch: scratch, scratchPath: scratchPath)

print(tally.failures == 0 ? "PASS \(tally.checks) checks" : "FAILED \(tally.failures) of \(tally.checks)")
exit(tally.failures == 0 ? 0 : 1)
