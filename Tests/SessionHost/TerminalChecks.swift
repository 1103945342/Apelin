import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

// The terminal backend: where a terminal starts (a project, a folder inside it,
// a folder the app picked, or home), how much of its output its task keeps and
// how an attach is told the history was trimmed, the log surviving a restart
// with a damaged head or an unwritable folder, and a real pty whose socket
// carries only the typing.

func terminalChecks(scratch: URL, scratchPath: String) async throws {
    func output(_ bytes: Int) -> JSONValue {
        let data = Data(repeating: 0x41, count: bytes)
        return .object([
            "base64": .string(data.base64EncodedString()),
            "text": .string(String(decoding: data, as: UTF8.self)),
        ])
    }

    func lines(_ url: URL) -> Int {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .count
    }

    func contiguous(_ events: [TaskEvent]) -> Bool {
        zip(events, events.dropFirst()).allSatisfy { $1.seq.rawValue == $0.seq.rawValue + 1 }
    }

    // MARK: A terminal's history is bounded, and says so

    do {
        let directory = scratch.appendingPathComponent("terminal-bounded")
        let registry = TaskRegistry(directory: directory)
        await registry.load()
        let terminal = await registry.create(kind: .terminal, owner: nil)
        await registry.setHistoryBudget(
            terminal.taskID,
            rawBytes: 256 * 1024,
            storedBytes: 4 * 1024 * 1024,
            events: 64,
        )
        await registry.append(terminal.taskID, kind: "started", payload: .object([
            "pid": .number(Double(getpid())),
            "shell": .string("/bin/sh"),
            "cwd": .string(scratchPath),
        ]))
        for _ in 1 ... 128 {
            await registry.append(terminal.taskID, kind: "output", payload: output(8 * 1024))
        }

        let first = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        let marker = first.events.first
        check(marker?.kind == TaskRegistry.trimmedKind,
              "an attach from the start replays the trim first: \(marker?.kind ?? "none")")
        check(marker.map { $0.seq.rawValue + 1 } == first.events.dropFirst().first?.seq.rawValue,
              "the trim's own number is the one the events continue from")
        check(contiguous(first.events), "the replay is numbered with no gaps")
        check(first.events.filter { $0.kind == "output" }.count < 128, "the oldest output is gone")
        check(first.events.contains { $0.kind == "output" } && !first.events.contains { $0.kind == "started" },
              "what is kept is the newest output, and the oldest events are what went")
        check((marker?.payload?["throughSeq"]?.doubleValue).map { UInt64($0) } == marker?.seq.rawValue,
              "the trim names the number it covers")
        check(marker?.payload?["limit"]?.doubleValue == 256 * 1024, "and the budget it was trimmed to")
        check(first.lastSeq == EventSeq(129), "lastSeq is every event that was ever appended: \(first.lastSeq)")
        check(!first.finished, "a running terminal is not finished")

        let log = directory.appendingPathComponent("\(terminal.taskID.rawValue).events.jsonl")
        let kept = Array(first.events.dropFirst())
        check(lines(log) == kept.count, "the disk keeps exactly what memory keeps: \(lines(log)) vs \(kept.count)")
        let onDisk = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
        check(onDisk.first.flatMap { try? JSONCoding.decode(TaskEvent.self, from: Data($0.utf8)) }?.seq == kept.first?.seq,
              "the file now starts where the kept events start")
        check(((try? Data(contentsOf: log).count) ?? .max) <= 5 * 1024 * 1024, "the log on disk is bounded too")

        let atEnd = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: first.lastSeq, waitMilliseconds: 0)
        check(atEnd.events.isEmpty, "a cursor at the end waits rather than replaying")

        let inside = try await registry.attach(
            terminal.taskID,
            as: .ptyAttach,
            afterSeq: kept.first?.seq ?? .start,
            waitMilliseconds: 0,
        )
        check(!inside.events.contains { $0.kind == TaskRegistry.trimmedKind }, "a cursor past the trim is not told about it")
        check(inside.events.allSatisfy { ($0.seq > (kept.first?.seq ?? .start)) }, "and gets only what follows it")

        let record = await registry.record(terminal.taskID)
        check(record?.historyFloor == marker?.seq, "the record keeps the trim's floor")
        check(record?.historyBudget != nil, "and the budget it was given, so the next host bounds it too")

        await registry.finish(terminal.taskID, .succeeded)
        let ended = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        check(ended.finished && ended.state == .succeeded, "a finished terminal reads as finished")
        check(ended.events.last?.kind == TaskEvent.stateKind, "its final state is the last event, never trimmed")

        // The next host reads the floor back from the log itself.
        let restarted = TaskRegistry(directory: directory)
        let unfinished = await restarted.load()
        check(unfinished.isEmpty, "a finished terminal is not resumed")
        let again = try await restarted.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        check(again.events.first?.kind == TaskRegistry.trimmedKind && again.events.first?.seq == marker?.seq,
              "after a restart the trim is still where the log starts")
        check(again.lastSeq == EventSeq(130), "and the numbering carries on from where it was: \(again.lastSeq)")
        check(contiguous(again.events), "with no gap between the trim and the kept events")
        check(again.finished, "and the task is still finished")
        let reread = await restarted.record(terminal.taskID)
        check(reread?.historyFloor == marker?.seq, "the restarted host keeps the same floor")

        // A head the host could not finish writing: the floor is read from what
        // the log's own numbering says, so the tail is never taken for bad
        // lines and swallowed.
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        if let newline = text.firstIndex(of: "\n") {
            try ("{torn" + text[newline...]).write(to: log, atomically: true, encoding: .utf8)
        }
        let afterTear = TaskRegistry(directory: directory)
        await afterTear.load()
        let torn = try await afterTear.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        check(torn.events.first?.kind == TaskRegistry.trimmedKind && torn.events.first?.seq == marker?.seq,
              "a damaged first line does not lose the floor")
        check(torn.events.dropFirst().first?.kind == TaskRegistry.unreadableKind
                && torn.events.dropFirst().first?.seq == marker.map { $0.seq.next },
              "the damaged line stands as unreadable, at its own number")
        check(torn.events.count == again.events.count, "and nothing else is lost: \(torn.events.count) vs \(again.events.count)")
        check(torn.lastSeq == again.lastSeq && torn.finished, "the end is still the end")
    }

    // MARK: Only terminals are bounded; everything else keeps its log

    do {
        let registry = TaskRegistry(directory: scratch.appendingPathComponent("terminal-plain"))
        await registry.load()
        let build = await registry.create(kind: .build, owner: .build)
        for number in 1 ... 3000 {
            await registry.append(build.taskID, kind: "log", payload: .object(["line": .string("line-\(number)")]))
        }
        await registry.finish(build.taskID, .succeeded)
        var cursor = EventSeq.start
        var total = 0
        var finished = false
        while !finished {
            let batch = try await registry.attach(build.taskID, as: .buildAttach, afterSeq: cursor, waitMilliseconds: 0)
            if batch.events.isEmpty { break }
            check(batch.events.count <= TaskRegistry.maximumBatchEvents, "a batch stops at the batch limit")
            check(!batch.events.contains { $0.kind == TaskRegistry.trimmedKind }, "a build's log is never trimmed")
            total += batch.events.count
            cursor = batch.lastSeq
            finished = batch.finished
        }
        check(total == 3001 && cursor == EventSeq(3001), "every event of a build is still there: \(total) at \(cursor)")
    }

    // MARK: A drain: every batch after the first, until `finished`

    do {
        let registry = TaskRegistry(directory: scratch.appendingPathComponent("terminal-drain"))
        await registry.load()
        let terminal = await registry.create(kind: .terminal, owner: nil)
        await registry.setHistoryBudget(terminal.taskID, rawBytes: 2 * 1024 * 1024, storedBytes: 6 * 1024 * 1024, events: 4096)
        for _ in 1 ... 3000 {
            await registry.append(terminal.taskID, kind: "output", payload: output(64))
        }
        await registry.finish(terminal.taskID, .succeeded)
        var cursor = EventSeq.start
        var seen: [UInt64] = []
        var batches = 0
        var finished = false
        var snapshot: EventSeq?
        while !finished {
            let batch = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: cursor, waitMilliseconds: 0)
            if batch.events.isEmpty { break }
            snapshot = snapshot ?? batch.snapshotLastSeq
            seen += batch.events.map(\.seq.rawValue)
            batches += 1
            cursor = batch.lastSeq
            finished = batch.finished
        }
        check(snapshot == EventSeq(3001), "the first batch names where the history ended when it was taken: \(String(describing: snapshot))")
        check(batches >= 3, "a long history comes in several batches: \(batches)")
        check(seen == Array(1 ... 3001), "and every event arrives once, in order, with no gap")
        check(finished, "the last batch is the one that says finished")
        check(cursor == EventSeq(3001), "the cursor ends at the last event")
    }

    // MARK: The snapshot high-water, and every other task as it was

    do {
        let registry = TaskRegistry(directory: scratch.appendingPathComponent("terminal-snapshot"))
        await registry.load()
        let terminal = await registry.create(kind: .terminal, owner: nil)
        await registry.setHistoryBudget(terminal.taskID, rawBytes: 2 * 1024 * 1024, storedBytes: 6 * 1024 * 1024, events: 4096)
        for _ in 1 ... 3 {
            await registry.append(terminal.taskID, kind: "output", payload: output(16))
        }
        let first = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        check(first.snapshotLastSeq == EventSeq(3) && first.lastSeq == EventSeq(3),
              "a terminal's batch names the end of its history: \(String(describing: first.snapshotLastSeq))")
        // The shell writes on while the reader catches up.
        for _ in 1 ... 2 {
            await registry.append(terminal.taskID, kind: "output", payload: output(16))
        }
        let next = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: first.lastSeq, waitMilliseconds: 0)
        check(next.snapshotLastSeq == EventSeq(5), "and the next batch names a newer end")
        check(next.events.map(\.seq.rawValue) == [4, 5], "while its own cursor still pages from where it was")
        check(next.lastSeq == EventSeq(5), "the paging cursor is the last event it delivered")

        let build = await registry.create(kind: .build, owner: .build)
        await registry.append(build.taskID, kind: "log", payload: .object(["line": .string("one")]))
        let plain = try await registry.attach(build.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
        check(plain.snapshotLastSeq == nil, "a build's batch names no snapshot, as it always did")

        // The wire: a batch from before the field decodes, one with it too.
        let older = try? JSONCoding.decode(
            TaskEventBatch.self,
            from: Data(#"{"taskID":"t","events":[],"state":"running","lastSeq":4,"finished":false}"#.utf8),
        )
        check(older?.snapshotLastSeq == nil && older?.lastSeq == EventSeq(4),
              "a batch from before the snapshot decodes unchanged")
        let carried = try? JSONCoding.decode(
            TaskEventBatch.self,
            from: Data(#"{"taskID":"t","events":[],"state":"running","lastSeq":4,"finished":false,"snapshotLastSeq":4}"#.utf8),
        )
        check(carried?.snapshotLastSeq == EventSeq(4), "and one that names it is read")
    }

    // MARK: A `state` line in the middle does not pin the history

    do {
        let directory = scratch.appendingPathComponent("terminal-running-state")
        let registry = TaskRegistry(directory: directory)
        await registry.load()
        let terminal = await registry.create(kind: .terminal, owner: nil)
        await registry.setHistoryBudget(terminal.taskID, rawBytes: 64 * 1024, storedBytes: 512 * 1024, events: 32)
        await registry.append(terminal.taskID, kind: TaskEvent.stateKind, payload: .object(["state": .string("running")]))
        for _ in 1 ... 40 {
            await registry.append(terminal.taskID, kind: "output", payload: output(4 * 1024))
        }
        let batch = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        check(batch.events.first?.kind == TaskRegistry.trimmedKind, "a running state line is history like any other")
        check(!batch.events.contains { $0.kind == TaskEvent.stateKind }, "so it is dropped with the rest of the oldest events")
        check(batch.events.contains { $0.kind == "output" }, "and the output after it is what is kept")
    }

    // MARK: A log the folder will not let the host rewrite

    do {
        let directory = scratch.appendingPathComponent("terminal-unwritable")
        let registry = TaskRegistry(directory: directory)
        await registry.load()
        let terminal = await registry.create(kind: .terminal, owner: nil)
        let budget = TaskRegistry.HistoryBudget(rawBytes: 64 * 1024, storedBytes: 512 * 1024, events: 32)
        await registry.setHistoryBudget(
            terminal.taskID,
            rawBytes: budget.rawBytes,
            storedBytes: budget.storedBytes,
            events: budget.events,
        )
        for _ in 1 ... 12 {
            await registry.append(terminal.taskID, kind: "output", payload: output(8 * 1024))
        }
        let log = directory.appendingPathComponent("\(terminal.taskID.rawValue).events.jsonl")
        let boundedLines = lines(log)
        let boundedBytes = (try? Data(contentsOf: log).count) ?? .max
        // No temp file can be made here, so the atomic rewrite cannot happen.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        // Three rounds of the budget: the log is held at its size, and memory
        // stays inside the budget by dropping the oldest events.
        for _ in 1 ... 120 {
            await registry.append(terminal.taskID, kind: "output", payload: output(8 * 1024))
        }
        let during = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        let marker = during.events.first
        let held = await registry.record(terminal.taskID)
        let heldBytes = (try? Data(contentsOf: log).count) ?? .max
        check(lines(log) <= boundedLines + 2,
              "a log that cannot be rewritten stops growing: \(lines(log)) lines, held at \(boundedLines)")
        check(heldBytes <= budget.storedBytes,
              "and its file never holds more than the budget, in bytes: \(heldBytes)")
        check(heldBytes <= boundedBytes + 64 * 1024, "it did not grow with three rounds of output")
        check(marker?.kind == TaskRegistry.trimmedKind, "an attach is told the history was trimmed")
        check(marker?.payload?["stalled"]?.boolValue == true, "and that the log cannot be written back")
        let keptRaw = during.events.reduce(0) { total, event in
            total + TaskRegistry.rawBytes(of: event)
        }
        check(keptRaw <= budget.rawBytes, "memory is inside the budget too: \(keptRaw) bytes of output kept")
        check(during.events.count < budget.events, "and few enough events: \(during.events.count)")
        check(during.lastSeq == EventSeq(132), "the numbering is untouched: \(during.lastSeq)")
        check(held?.historyStalled == true, "the record says the log is held at its size")

        // The folder is writable again and the shell is closed: its last event
        // writes what memory holds back over the file, so the log is current and
        // bounded again without waiting for more output.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for _ in 1 ... 5 {
            await registry.append(terminal.taskID, kind: "output", payload: output(8 * 1024))
        }
        await registry.finish(terminal.taskID, .succeeded)
        let recovered = await registry.record(terminal.taskID)
        let after = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        let recoveredBytes = (try? Data(contentsOf: log).count) ?? .max
        let lastLine = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).last
            .flatMap { try? JSONCoding.decode(TaskEvent.self, from: Data($0.utf8)) }
        check(lines(log) == after.events.count - 1,
              "the file now holds exactly what the task kept: \(lines(log)) lines")
        check(recoveredBytes <= budget.storedBytes, "and is inside its stored budget: \(recoveredBytes) bytes")
        check(lastLine?.kind == TaskEvent.stateKind, "the file ends with the task's final state")
        check(after.finished, "the task reads as finished")
        check(after.events.first?.payload?["stalled"]?.boolValue != true, "and no longer says it is held at its size")
        check(recovered?.historyStalled == nil, "the record says so too")
        check(recovered?.historyFloor == after.events.first?.seq, "the record's floor is where the file starts")
        check(after.lastSeq == EventSeq(138), "every event is still numbered: \(after.lastSeq)")

        // A host that reads the task back finds the same log, the same end and
        // no note of a held log.
        let reloaded = TaskRegistry(directory: directory)
        let unfinished = await reloaded.load()
        check(unfinished.isEmpty, "a finished terminal is not resumed after a recovery")
        let reread = try await reloaded.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        let rereadRecord = await reloaded.record(terminal.taskID)
        check(reread.finished && reread.lastSeq == after.lastSeq, "a reload reads the same end: \(reread.lastSeq)")
        check(reread.events.first?.seq == after.events.first?.seq, "from the same place in its history")
        check(rereadRecord?.historyStalled == nil && rereadRecord?.historyFloor == after.events.first?.seq,
              "and nothing in the record says the log was ever held")
    }

    // MARK: Text that the log escapes costs what it really takes

    do {
        let directory = scratch.appendingPathComponent("terminal-escaped")
        let registry = TaskRegistry(directory: directory)
        await registry.load()
        let terminal = await registry.create(kind: .terminal, owner: nil)
        // The stored budget binds here: 4 KB of NULs is 6 bytes each once the
        // log JSON escapes them, so an estimate from the text's UTF-8 length
        // would let the file grow far past what was promised.
        let budget = TaskRegistry.HistoryBudget(rawBytes: 1024 * 1024, storedBytes: 256 * 1024, events: 4096)
        await registry.setHistoryBudget(
            terminal.taskID,
            rawBytes: budget.rawBytes,
            storedBytes: budget.storedBytes,
            events: budget.events,
        )
        for _ in 1 ... 30 {
            await registry.append(terminal.taskID, kind: "output", payload: .object([
                "base64": .string(Data(repeating: 0, count: 4096).base64EncodedString()),
                "text": .string(String(repeating: "\u{0}", count: 4096)),
            ]))
        }
        let log = directory.appendingPathComponent("\(terminal.taskID.rawValue).events.jsonl")
        let bytes = (try? Data(contentsOf: log).count) ?? .max
        let kept = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        check(bytes <= budget.storedBytes, "an escaped log is bounded by the bytes it really takes: \(bytes)")
        check(kept.events.filter { $0.kind == "output" }.count < 30, "and the oldest of it was dropped")
        check(kept.events.contains { $0.kind == TaskRegistry.trimmedKind }, "an attach is told")
        // What memory says it holds is what the file holds.
        // The trim marker is the batch's own, never written to the log.
        let counted = kept.events
            .filter { $0.kind != TaskRegistry.trimmedKind }
            .reduce(0) { total, event in total + (TaskRegistry.encoded(event)?.count ?? 0) }
        check(counted == bytes, "memory and the file hold the same bytes: \(counted) vs \(bytes)")
    }

    // MARK: The stored budget is the one that binds, and the file is checked
    // after every single append

    do {
        let directory = scratch.appendingPathComponent("terminal-stored-first")
        let registry = TaskRegistry(directory: directory)
        await registry.load()
        let terminal = await registry.create(kind: .terminal, owner: nil)
        // Raw and count are wide: only the bytes on disk can trip.
        let budget = TaskRegistry.HistoryBudget(rawBytes: 4 * 1024 * 1024, storedBytes: 64 * 1024, events: 4096)
        await registry.setHistoryBudget(
            terminal.taskID,
            rawBytes: budget.rawBytes,
            storedBytes: budget.storedBytes,
            events: budget.events,
        )
        let log = directory.appendingPathComponent("\(terminal.taskID.rawValue).events.jsonl")
        // 1 KB of NULs: about 6 KB once the log JSON escapes it, so the stored
        // budget fills before the raw one is anywhere near.
        func escaped() -> JSONValue {
            .object([
                "base64": .string(Data(repeating: 0, count: 1024).base64EncodedString()),
                "text": .string(String(repeating: "\u{0}", count: 1024)),
            ])
        }
        for step in 1 ... 20 {
            if step == 7 {
                // The log cannot be rewritten any more, but the file that is
                // there can still be appended to.
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            }
            await registry.append(terminal.taskID, kind: "output", payload: escaped())
            let size = (try? Data(contentsOf: log).count) ?? 0
            check(size <= budget.storedBytes, "step \(step): the file never holds more than \(budget.storedBytes): \(size)")
        }
        let held = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        let heldRecord = await registry.record(terminal.taskID)
        let heldRaw = held.events.reduce(0) { $0 + TaskRegistry.rawBytes(of: $1) }
        check(heldRaw <= budget.rawBytes, "and memory is inside the budget: \(heldRaw) bytes of output")
        check(held.events.contains { $0.kind == TaskRegistry.trimmedKind }, "the attach is told what was trimmed")
        check(heldRecord?.historyStalled == true, "and the record says the log is held")
        let size = (try? Data(contentsOf: log).count) ?? 0
        check(size <= budget.storedBytes, "with three rounds of output, the file never grew: \(size)")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        await registry.finish(terminal.taskID, .succeeded)
        let recovered = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        let lastLine = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).last
            .flatMap { try? JSONCoding.decode(TaskEvent.self, from: Data($0.utf8)) }
        check(recovered.finished && lastLine?.kind == TaskEvent.stateKind, "the recovered file ends with the task's state")
        check(((try? Data(contentsOf: log).count) ?? .max) <= budget.storedBytes, "and is inside its budget")
        let recoveredRecord = await registry.record(terminal.taskID)
        check(recoveredRecord?.historyStalled == nil, "and the record says it is no longer held")
    }

    // MARK: A count that fills first writes each event once

    do {
        let directory = scratch.appendingPathComponent("terminal-count-first")
        let registry = TaskRegistry(directory: directory)
        await registry.load()
        let terminal = await registry.create(kind: .terminal, owner: nil)
        // Raw and stored are wide: the event count is what fills.
        let budget = TaskRegistry.HistoryBudget(rawBytes: 4 * 1024 * 1024, storedBytes: 4 * 1024 * 1024, events: 16)
        await registry.setHistoryBudget(
            terminal.taskID,
            rawBytes: budget.rawBytes,
            storedBytes: budget.storedBytes,
            events: budget.events,
        )
        for _ in 1 ... 17 {
            await registry.append(terminal.taskID, kind: "output", payload: output(16))
        }
        let log = directory.appendingPathComponent("\(terminal.taskID.rawValue).events.jsonl")
        let onDisk = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? JSONCoding.decode(TaskEvent.self, from: Data($0.utf8)) }
            .map(\.seq.rawValue)
        check(Set(onDisk).count == onDisk.count, "no event is written twice: \(onDisk)")
        check(onDisk == onDisk.sorted(), "and the log is in order: \(onDisk)")
        let batch = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        let tail = batch.events.filter { $0.kind != TaskRegistry.trimmedKind }.map(\.seq.rawValue)
        check(tail == onDisk, "the replay's tail is exactly the file: \(tail) vs \(onDisk)")

        let reloaded = TaskRegistry(directory: directory)
        await reloaded.load()
        let reread = try await reloaded.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        check(reread.events.filter { $0.kind != TaskRegistry.trimmedKind }.map(\.seq.rawValue) == onDisk,
              "and a reload reads the same log, once per event")
        check(reread.lastSeq == batch.lastSeq, "with the same numbering: \(reread.lastSeq)")
    }

    // MARK: One event larger than the whole log

    do {
        let directory = scratch.appendingPathComponent("terminal-oversized")
        let registry = TaskRegistry(directory: directory)
        await registry.load()
        let terminal = await registry.create(kind: .terminal, owner: nil)
        let budget = TaskRegistry.HistoryBudget(rawBytes: 4 * 1024 * 1024, storedBytes: 64 * 1024, events: 4096)
        await registry.setHistoryBudget(
            terminal.taskID,
            rawBytes: budget.rawBytes,
            storedBytes: budget.storedBytes,
            events: budget.events,
        )
        let log = directory.appendingPathComponent("\(terminal.taskID.rawValue).events.jsonl")
        // 16 KB of NULs: about 98 KB once the log JSON escapes it, larger than
        // the whole budget.
        await registry.append(terminal.taskID, kind: "output", payload: .object([
            "base64": .string(Data(repeating: 0, count: 16 * 1024).base64EncodedString()),
            "text": .string(String(repeating: "\u{0}", count: 16 * 1024)),
        ]))
        let afterBig = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        check(((try? Data(contentsOf: log).count) ?? .max) <= budget.storedBytes,
              "an event larger than the whole log never reaches it")
        check(afterBig.events.contains { $0.kind == TaskRegistry.trimmedKind },
              "the attach says that history was trimmed")
        check(afterBig.lastSeq == EventSeq(1), "the event still had its number: \(afterBig.lastSeq)")

        // What comes after it is the log, and the replay goes on from there.
        await registry.append(terminal.taskID, kind: "output", payload: output(1024))
        let next = try await registry.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        check(next.events.last?.seq == EventSeq(2) && next.events.last?.kind == "output",
              "the next event is the file's own, at its own number")
        check(((try? Data(contentsOf: log).count) ?? .max) <= budget.storedBytes,
              "and the file is still inside its budget")
        check(contiguous(next.events), "the replay is numbered with no gaps")
    }

    // MARK: A terminal log written before histories were bounded, read at start

    do {
        let directory = scratch.appendingPathComponent("terminal-legacy")
        let first = TaskRegistry(directory: directory)
        await first.load()
        let terminal = await first.create(kind: .terminal, owner: nil)
        for _ in 1 ... 400 {
            await first.append(terminal.taskID, kind: "output", payload: output(8 * 1024))
        }
        let log = directory.appendingPathComponent("\(terminal.taskID.rawValue).events.jsonl")
        check(lines(log) == 400, "the log has everything it was given")
        let legacyRecord = directory.appendingPathComponent("\(terminal.taskID.rawValue).json")
        var record = try JSONCoding.decode(TaskRegistry.Record.self, from: Data(contentsOf: legacyRecord))
        check(record.historyBudget == nil && record.historyFloor == nil, "and a record from before the budget names neither")
        // As an older host would have left it: no budget, nothing trimmed.
        record.historyBudget = nil
        try JSONCoding.encode(record).write(to: legacyRecord)
        let next = TaskRegistry(directory: directory)
        await next.load()
        let bounded = try await next.attach(terminal.taskID, as: .ptyAttach, afterSeq: .start, waitMilliseconds: 0)
        check(lines(log) < 400, "the next host bounds the log it found: \(lines(log))")
        check(bounded.events.first?.kind == TaskRegistry.trimmedKind, "and an attach learns that it was trimmed")
        let boundedRecord = await next.record(terminal.taskID)
        check(boundedRecord?.historyBudget != nil, "the record now names the budget")
    }

    // MARK: Where a terminal starts

    do {
        let home = scratchPath + "/terminal-home"
        let project = home + "/Documents/wiki.qaq.apelin/Projects/Hello"
        let data = DataFolder(home: home)
        write(project + "/apelin-project.json", #"{"projectID": "p-1"}"#)
        try FileManager.default.createDirectory(atPath: project + "/Sources/Deep", withIntermediateDirectories: true)
        write(project + "/README.md", "readme\n")
        try FileManager.default.createDirectory(atPath: scratchPath + "/terminal-outside", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: project + "/escape",
            withDestinationPath: scratchPath + "/terminal-outside",
        )

        let registry = TaskRegistry(directory: scratch.appendingPathComponent("terminal-start"))
        await registry.load()
        let host = TerminalHost(
            installRoot: "/",
            home: home,
            scopes: FileScopes(installRoot: "/", dataFolder: data),
            registry: registry,
        )
        let projectPath = CanonicalPath.resolve(project)
        let outside = CanonicalPath.resolve(scratchPath + "/terminal-outside")

        let plain = try await host.directory(for: PtyOpenRequest())
        check(plain.path == CanonicalPath.resolve(home) && plain.project == nil && !plain.chosen,
              "with nothing named a terminal starts in mobile's home")

        let inProject = try await host.directory(for: PtyOpenRequest(projectID: "p-1"))
        check(inProject.path == projectPath && inProject.project == projectPath && inProject.chosen,
              "a project starts in its folder, with the project's environment")

        let deep = try await host.directory(for: PtyOpenRequest(projectID: "p-1", relativePath: "Sources/Deep"))
        check(deep.path == projectPath.map { $0 + "/Sources/Deep" } && deep.project == projectPath,
              "a relative path starts in that folder, still with the project's environment: \(deep.path)")
        let dot = try await host.directory(for: PtyOpenRequest(projectID: "p-1", relativePath: "."))
        check(dot.path == projectPath, "a dot is the project itself")
        let empty = try await host.directory(for: PtyOpenRequest(projectID: "p-1", relativePath: ""))
        check(empty.path == projectPath, "and so is an empty path")

        await expectErrorAsync("a relative path with no project", code: .badRequest) {
            _ = try await host.directory(for: PtyOpenRequest(relativePath: "Sources"))
        }
        await expectErrorAsync("a project and a chosen folder at once", code: .badRequest) {
            _ = try await host.directory(for: PtyOpenRequest(projectID: "p-1", workingDirectory: scratchPath))
        }
        await expectErrorAsync("a project that does not exist", code: .notFound) {
            _ = try await host.directory(for: PtyOpenRequest(projectID: "nope"))
        }
        await expectErrorAsync("a .. escape", code: .badRequest) {
            _ = try await host.directory(for: PtyOpenRequest(projectID: "p-1", relativePath: "../Hello"))
        }
        await expectErrorAsync("an absolute relativePath", code: .badRequest) {
            _ = try await host.directory(for: PtyOpenRequest(projectID: "p-1", relativePath: "/etc"))
        }
        await expectErrorAsync("a link out of the project", code: .denied) {
            _ = try await host.directory(for: PtyOpenRequest(projectID: "p-1", relativePath: "escape"))
        }
        await expectErrorAsync("a folder that is not there", code: .notFound) {
            _ = try await host.directory(for: PtyOpenRequest(projectID: "p-1", relativePath: "Sources/Nope"))
        }
        await expectErrorAsync("a file where a folder was asked for", code: .badRequest) {
            _ = try await host.directory(for: PtyOpenRequest(projectID: "p-1", relativePath: "README.md"))
        }

        let picked = try await host.directory(for: PtyOpenRequest(workingDirectory: scratchPath + "/terminal-outside"))
        check(picked.path == outside && picked.project == nil && picked.chosen,
              "a folder the app picked is used as it is")
        let throughLink = try await host.directory(for: PtyOpenRequest(workingDirectory: project + "/escape"))
        check(throughLink.path == outside, "a path through a link is resolved before anything is decided about it")
        await expectErrorAsync("a folder that is not there", code: .notFound) {
            _ = try await host.directory(for: PtyOpenRequest(workingDirectory: scratchPath + "/terminal-missing"))
        }
        await expectErrorAsync("a file as a working directory", code: .badRequest) {
            _ = try await host.directory(for: PtyOpenRequest(workingDirectory: project + "/README.md"))
        }
        await expectErrorAsync("a relative working directory", code: .badRequest) {
            _ = try await host.directory(for: PtyOpenRequest(workingDirectory: "home"))
        }
        await expectErrorAsync("a working directory with a NUL", code: .badRequest) {
            _ = try await host.directory(for: PtyOpenRequest(workingDirectory: scratchPath + "/a\u{0}b"))
        }

        // The wire: what an older app sends, and what the new keys add.
        let older = try? JSONCoding.decode(
            PtyOpenRequest.self,
            from: Data(#"{"columns": 120, "rows": 40, "initialInput": "ls\n"}"#.utf8),
        )
        check(older?.columns == 120 && older?.rows == 40 && older?.projectID == nil
                && older?.relativePath == nil && older?.workingDirectory == nil && older?.initialInput == "ls\n",
              "an older ptyOpen decodes unchanged")
        let newer = try? JSONCoding.decode(
            PtyOpenRequest.self,
            from: Data(#"{"projectID": "p-1", "relativePath": "Sources"}"#.utf8),
        )
        check(newer?.projectID == "p-1" && newer?.relativePath == "Sources" && newer?.columns == 80,
              "and the new keys are read")
        let oldAttach = try? JSONCoding.decode(
            PtyAttachRequest.self,
            from: Data(#"{"taskID": "t", "afterSeq": 3, "waitMilliseconds": 0, "wantsDescriptor": true}"#.utf8),
        )
        check(oldAttach?.inputOnly == false && oldAttach?.wantsDescriptor == true,
              "an older ptyAttach decodes as not input-only")
        let inputOnly = try? JSONCoding.decode(
            PtyAttachRequest.self,
            from: Data(#"{"taskID": "t", "wantsDescriptor": true, "inputOnly": true}"#.utf8),
        )
        check(inputOnly?.inputOnly == true && inputOnly?.afterSeq == .start && inputOnly?.waitMilliseconds
                == PtyAttachRequest.defaultWaitMilliseconds, "and the new key is read")
        check(CallerPolicy.allows(.app, .ptyOpen) && CallerPolicy.allows(.app, .ptyAttach)
                && !CallerPolicy.allows(.worker(.agent, instance: "s"), .ptyOpen)
                && !CallerPolicy.allows(.worker(.agent, instance: "s"), .ptyAttach),
              "a terminal stays the app's alone")
    }

    // MARK: A real pty, and a socket that carries only the typing

    // macOS keeps /bin/sh; a bootstrap's shell is somewhere else, and
    // build/termcheck passes the one it found.
    var shells: [String] = ["/bin/sh", "/usr/bin/sh", "/usr/bin/bash"]
    if let chosen = ProcessInfo.processInfo.environment["APELIN_TERMINAL_SHELL"], !chosen.isEmpty {
        shells.insert(chosen, at: 0)
    }
    let shell = shells.first { access($0, X_OK) == 0 }
    if let shell {
        let launch = TerminalSession.Launch(
            shell: shell,
            arguments: ["-i"],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": scratchPath, "PS1": "$ "],
            identity: nil,
            workingDirectory: scratchPath,
            fallbackDirectory: "/",
            columns: 80,
            rows: 24,
        )
        let queue = DispatchQueue(label: "terminal-checks")
        let session = try TerminalSession.spawn(launch, queue: queue)
        let output = NSMutableData()
        let ended = DispatchSemaphore(value: 0)
        var exitStatus: Int32 = -1
        session.start(onOutput: { output.append($0) }, onExit: { exitStatus = $0; ended.signal() })
        let peer = try session.attachPeer(inputOnly: true)
        _ = "echo typed-$((40+2))\n".withCString { Darwin.write(peer, $0, strlen($0)) }
        usleep(300_000)
        var live = [UInt8](repeating: 0, count: 4096)
        let heard = recv(peer, &live, live.count, MSG_DONTWAIT)
        check(heard <= 0, "an input-only socket carries no live output: \(heard)")
        _ = "exit 3\n".withCString { Darwin.write(peer, $0, strlen($0)) }
        check(ended.wait(timeout: .now() + 10) == .success, "the shell exits")
        let text = queue.sync { String(decoding: output as Data, as: UTF8.self) }
        check(text.contains("typed-42"), "what was typed on the socket reached the shell")
        check((exitStatus >> 8) & 0xFF == 3, "the exit status is reported")
        close(peer)

        // Paused while the shell floods and exits: what waited in the pty is
        // still the shell's output, and all of it is delivered.
        let flood = try TerminalSession.spawn(launch, queue: queue)
        let flooded = NSMutableData()
        let floodEnded = DispatchSemaphore(value: 0)
        flood.start(onOutput: { flooded.append($0) }, onExit: { _ in floodEnded.signal() })
        let floodPeer = try flood.attachPeer(inputOnly: true)
        flood.pauseOutput()
        // 1280 × 32 bytes: more than one piece, and enough to fill the pty while
        // nobody reads it.
        let command = "i=0; while [ $i -lt 1280 ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done; exit 0\n"
        _ = command.withCString { Darwin.write(floodPeer, $0, strlen($0)) }
        usleep(300_000)
        flood.resumeOutput()
        check(floodEnded.wait(timeout: .now() + 10) == .success, "the flooding shell exits")
        let floodData = queue.sync { flooded as Data }
        check(floodData.filter { $0 == UInt8(ascii: "x") }.count >= 1280 * 32,
              "every byte a paused terminal's shell wrote still arrives: \(floodData.count) bytes, \(floodData.filter { $0 == UInt8(ascii: "x") }.count) of x")
        close(floodPeer)

        // A terminal that has ended offers no socket, and its events are still
        // the answer.
        let goneRegistry = TaskRegistry(directory: scratch.appendingPathComponent("terminal-gone"))
        await goneRegistry.load()
        let hostGone = TerminalHost(
            installRoot: "/",
            home: scratchPath,
            scopes: FileScopes(installRoot: "/", dataFolder: DataFolder(home: scratchPath)),
            registry: goneRegistry,
        )
        let gone = await hostGone.descriptorIfOpen(for: TaskID("no-such-terminal"))
        check(gone == nil, "a terminal that is not open offers no socket")
        await expectErrorAsync("and asking for one strictly says which terminal", code: .notFound) {
            _ = try await hostGone.descriptor(for: TaskID("no-such-terminal"))
        }

        // A folder the terminal was told to use and cannot enter fails, rather
        // than starting quietly in home.
        var strict = launch
        strict.workingDirectory = scratchPath + "/terminal-not-there"
        strict.requiresDirectory = true
        var failure: String?
        do {
            _ = try TerminalSession.spawn(strict, queue: queue)
        } catch {
            failure = "\(error)"
        }
        check(failure?.contains("entering the terminal's folder") == true,
              "a terminal whose folder is not there and was asked for says so: \(failure ?? "it started")")
    } else {
        print("SKIP the real pty: no shell at /bin/sh, /usr/bin/sh or /usr/bin/bash")
    }
}
