import Foundation

/// A conversation's storage: the record without its events, the events beside
/// it, the one-time move out of a record that still carries them, and what a
/// launch cut off between the two reads. Run by `Scripts/test-chat-store.sh
/// --device` on the device's own toolchain.
func checkChatStore(_ scratch: URL, check: (Bool, String) -> Void) async throws {
    let home = scratch.appendingPathComponent("store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let folder = DataFolder(root: home)
    let chats = folder.root.appendingPathComponent("Chats")
    try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    func recordURL(_ id: UUID) -> URL { chats.appendingPathComponent(id.uuidString + ".json") }
    func eventsURL(_ id: UUID) -> URL { chats.appendingPathComponent(id.uuidString + ".events.jsonl") }
    func event(_ number: UInt64, _ kind: String = "prompt") -> TaskEvent {
        TaskEvent(seq: EventSeq(number), kind: kind, payload: .object(["text": .string("e\(number)")]))
    }

    // A record from before the split is moved out once, and reads back whole.
    let legacyID = UUID()
    var legacy = ChatRecord(summary: .untitled(lastInteraction: Date(), projectName: nil))
    legacy.summary.id = legacyID
    legacy.events = [event(1), event(2)]
    try JSONEncoder().encode(legacy).write(to: recordURL(legacyID))
    var store = ChatStore(folder: folder)
    var loaded = try await store.load()
    check(loaded.records.count == 1 && loaded.unreadable.isEmpty, "a legacy record loads")
    check(loaded.records.first?.events.map(\.seq.rawValue) == [1, 2], "its events come back in order")
    check(FileManager.default.fileExists(atPath: eventsURL(legacyID).path), "the split wrote the events file")
    let headText = String(decoding: try Data(contentsOf: recordURL(legacyID)), as: UTF8.self)
    check(!headText.contains("\"events\""), "the record no longer carries the events")
    check(headText.contains("\"eventCount\":2"), "the record counts them")

    // What a run added is appended, not rewritten.
    store = ChatStore(folder: folder)
    loaded = try await store.load()
    var grown = loaded.records[0]
    grown.events.append(event(3, "text"))
    try await store.save(grown, revision: 1)
    let appended = String(decoding: try Data(contentsOf: eventsURL(legacyID)), as: UTF8.self)
    check(appended.split(separator: "\n").count == 3, "a save appends the events it gained")
    store = ChatStore(folder: folder)
    loaded = try await store.load()
    check(loaded.records.first?.events.map(\.seq.rawValue) == [1, 2, 3], "the appended events read back")

    // History that went backwards is written out whole.
    store = ChatStore(folder: folder)
    loaded = try await store.load()
    var shrunk = loaded.records[0]
    shrunk.events = [event(1)]
    try await store.save(shrunk, revision: 2)
    let rewritten = String(decoding: try Data(contentsOf: eventsURL(legacyID)), as: UTF8.self)
    check(rewritten.split(separator: "\n").count == 1, "a shorter history replaces the file")
    store = ChatStore(folder: folder)
    loaded = try await store.load()
    check(loaded.records.first?.events.map(\.seq.rawValue) == [1], "the shortened history reads back")

    // A record with no events migrates to a head alone.
    let emptyID = UUID()
    var empty = ChatRecord(summary: .untitled(lastInteraction: Date(), projectName: nil))
    empty.summary.id = emptyID
    try JSONEncoder().encode(empty).write(to: recordURL(emptyID))
    store = ChatStore(folder: folder)
    loaded = try await store.load()
    check(loaded.records.count == 2, "an empty legacy record loads")
    check(!FileManager.default.fileExists(atPath: eventsURL(emptyID).path), "nothing is written for a chat with no events")
    check(
        String(decoding: try Data(contentsOf: recordURL(emptyID)), as: UTF8.self).contains("\"eventCount\":0"),
        "its head says none",
    )

    // Damage in the middle of the events is damage, never an empty history.
    let brokenID = UUID()
    var broken = ChatRecord(summary: .untitled(lastInteraction: Date(), projectName: nil))
    broken.summary.id = brokenID
    broken.events = [event(1), event(2)]
    try JSONEncoder().encode(broken).write(to: recordURL(brokenID))
    _ = try await ChatStore(folder: folder).load()
    var lines = String(decoding: try Data(contentsOf: eventsURL(brokenID)), as: UTF8.self)
    lines = lines.replacingOccurrences(of: "\"seq\":1", with: "\"seq\":not-a-number")
    try Data(lines.utf8).write(to: eventsURL(brokenID))
    store = ChatStore(folder: folder)
    loaded = try await store.load()
    check(loaded.unreadable.contains { $0.name.hasPrefix(brokenID.uuidString) }, "a broken event line sets the record aside")
    check(FileManager.default.fileExists(atPath: eventsURL(brokenID).path), "the events file is kept as it was")

    // Deleting a conversation deletes both files.
    store = ChatStore(folder: folder)
    try await store.remove(legacyID)
    check(!FileManager.default.fileExists(atPath: recordURL(legacyID).path), "a delete removes the record")
    check(!FileManager.default.fileExists(atPath: eventsURL(legacyID).path), "a delete removes the events")
}
