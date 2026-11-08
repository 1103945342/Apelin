import ApelinCore
import ApelinProtocol
import Foundation

/// Finished logs must not be opened during startup, but their first reader
/// still gets the same repair, pagination and final-state semantics.
func checkTaskRegistryStartup(_ scratch: URL, check: (Bool, String) -> Void) async throws {
    let directory = scratch.appendingPathComponent("lazy-finished-tasks")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let finished = await first.create(kind: .build, owner: .build)
    for number in 1 ... 1001 {
        await first.append(finished.taskID, kind: "log", payload: .object(["line": .string("line-\(number)")]))
    }
    await first.finish(finished.taskID, .succeeded)
    let log = directory.appendingPathComponent("\(finished.taskID.rawValue).events.jsonl")
    let complete = try Data(contentsOf: log)
    // With its final event intact, this task has a torn fragment after it.
    // Eager replay would truncate the fragment during load().
    var torn = complete
    torn.append(Data(#"{"seq":1003,"kind":"log""#.utf8))
    try torn.write(to: log)

    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(unfinished.isEmpty, "startup: terminal metadata is enough to exclude a task from recovery")
    let untouched = try Data(contentsOf: log)
    check(untouched == torn, "startup: a finished log is not read or repaired by load")
    let counts = await second.activeCount
    check(counts == 0, "startup: lazy finished tasks do not keep the host busy")
    let metadata = await second.records(kind: .build)
    check(metadata.count == 1 && metadata[0].state == .succeeded, "startup: metadata lists include lazy tasks")

    let batch = try await second.attach(finished.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(batch.events.count == 1000 && !batch.finished, "startup: lazy replay preserves the attach batch limit")
    let tail = try await second.attach(finished.taskID, as: .buildAttach, afterSeq: batch.lastSeq, waitMilliseconds: 0)
    check(tail.events.map(\.seq.rawValue) == [1001, 1002] && tail.finished, "startup: pagination reaches the final event")
    let repaired = try Data(contentsOf: log)
    check(repaired == complete, "startup: the first reader repairs the torn tail")

    // lastEvent and record are readers too, without needing an attach first.
    let third = TaskRegistry(directory: directory)
    await third.load()
    let final = await third.lastEvent(finished.taskID, kind: TaskEvent.stateKind)
    check(final?.payload?["state"]?.stringValue == "succeeded", "startup: lastEvent loads a finished log")
    let fourth = TaskRegistry(directory: directory)
    await fourth.load()
    let matching = await fourth.lastEvent(finished.taskID, kind: "log", field: "line", equals: "line-1001")
    check(matching?.seq == EventSeq(1001), "startup: filtered lastEvent loads a finished log")
    let fifth = TaskRegistry(directory: directory)
    await fifth.load()
    let record = await fifth.record(finished.taskID)
    check(record?.lastSeq == EventSeq(1002), "startup: record returns reconciled sequence metadata")

    // A record behind a final event must be replayed eagerly. Otherwise the
    // host would restart a completed build and remove its artifact.
    let running = await first.create(kind: .build, owner: .build)
    let runningLog = directory.appendingPathComponent("\(running.taskID.rawValue).events.jsonl")
    let finalEvent = TaskEvent(seq: EventSeq(1), kind: TaskEvent.stateKind, payload: .object(["state": .string("succeeded")]))
    var line = try JSONCoding.encode(finalEvent)
    line.append(0x0A)
    try line.write(to: runningLog)
    let sixth = TaskRegistry(directory: directory)
    let recovered = await sixth.load()
    check(recovered.isEmpty, "startup: a final event ahead of its record is never resumed")
    let corrected = await sixth.record(running.taskID)
    check(corrected?.state == .succeeded, "startup: unfinished metadata is reconciled eagerly")

    // A log that is there and cannot be read is not an empty log. Reading it
    // must leave the log and its record alone, and the task's real end must
    // read once it can be read again.
    let locked = await first.create(kind: .build, owner: .build)
    await first.append(locked.taskID, kind: "log", payload: .object(["line": .string("kept")]))
    await first.finish(locked.taskID, .succeeded)
    let lockedLog = directory.appendingPathComponent("\(locked.taskID.rawValue).events.jsonl")
    let lockedRecord = directory.appendingPathComponent("\(locked.taskID.rawValue).json")
    let logBytes = try Data(contentsOf: lockedLog)
    let recordBytes = try Data(contentsOf: lockedRecord)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedLog.path)
    let seventh = TaskRegistry(directory: directory)
    await seventh.load()
    let whileLocked = await seventh.record(locked.taskID)
    check(whileLocked?.state == .succeeded, "startup: an unreadable log leaves its record as it was")
    check(try Data(contentsOf: lockedRecord) == recordBytes, "startup: an unreadable log is not written over through its record")
    let noFinal = await seventh.lastEvent(locked.taskID, kind: TaskEvent.stateKind)
    check(noFinal == nil, "startup: an unreadable log reports no events rather than an invented end")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockedLog.path)
    check(try Data(contentsOf: lockedLog) == logBytes, "startup: an unreadable log keeps every line")
    let eighth = TaskRegistry(directory: directory)
    await eighth.load()
    let readable = await eighth.lastEvent(locked.taskID, kind: TaskEvent.stateKind)
    check(readable?.payload?["state"]?.stringValue == "succeeded", "startup: the log reads again once it can be read")
}
