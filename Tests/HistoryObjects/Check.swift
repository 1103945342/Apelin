import Foundation

/// Compile together with the production HistoryObjectStore.swift. No
/// provider or SwiftPM dependency is needed for this on-device storage check.
@main
struct HistoryObjectStoreCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let scratch = root.appendingPathComponent("build/history-object-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = HistoryObjectStore(directory: scratch.appendingPathComponent("objects"))
        let original = Data("model message with image and tool payload".utf8)
        let name = try store.put(original)
        precondition(tryValue { try store.get(name) } == original)
        precondition(tryValue { try store.put(original) } == name)
        precondition(tryValue { try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count } == 1)
        precondition(fails { _ = try store.get("../outside") })

        let file = store.directory.appendingPathComponent(name)
        let damaged = Data("damaged".utf8)
        try damaged.write(to: file)
        precondition(fails { _ = try store.get(name) })
        precondition(fails { _ = try store.put(original) })
        precondition(tryValue { try Data(contentsOf: file) } == damaged)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: scratch)
        precondition(fails { _ = try store.get(name) })
        precondition(fails { _ = try store.put(original) })
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: scratch.appendingPathComponent("missing"))
        precondition(tryValue { try HistoryObjectStore.itemExists(file) })
        precondition(fails { _ = try store.get(name) })
        precondition(fails { _ = try store.put(original) })

        let manifest = scratch.appendingPathComponent("manifest.json")
        try HistoryObjectStore.write(Data("first".utf8), to: manifest)
        try HistoryObjectStore.write(Data("second".utf8), to: manifest)
        precondition(tryValue { try Data(contentsOf: manifest) } == Data("second".utf8))
        print("PASS: 13 production HistoryObjectStore checks (round trip, deduplication, invalid name, corruption, symlinks, atomic replacement)")
    }

    private static func fails(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    private static func tryValue<T>(_ body: () throws -> T) -> T {
        do { return try body() } catch { fatalError("Unexpected error: \(error)") }
    }
}
