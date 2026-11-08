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
        let store = try HistoryObjectStore(directory: scratch.appendingPathComponent("objects"))
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
        // Two ancestor manifests sharing an object copy it once. Removing
        // the source after the first batch proves the second does not reread
        // it, while a new object still must pass validation before caching.
        let source = try HistoryObjectStore(directory: scratch.appendingPathComponent("source"))
        var destination = try HistoryObjectStore(directory: scratch.appendingPathComponent("destination"))
        let shared = try source.put(Data("shared ancestor".utf8))
        let other = try source.put(Data("second ancestor".utf8))
        var copied: Set<String> = []
        try destination.copy([shared, shared], from: source, copied: &copied)
        precondition(copied == [shared])
        try FileManager.default.removeItem(at: source.directory.appendingPathComponent(shared))
        try destination.copy([shared, other, shared], from: source, copied: &copied)
        precondition(copied == [shared, other])
        precondition(tryValue { try destination.get(shared) } == Data("shared ancestor".utf8))
        let corrupt = try source.put(Data("must be checked".utf8))
        try Data("changed".utf8).write(to: source.directory.appendingPathComponent(corrupt))
        precondition(fails { try destination.copy([corrupt], from: source, copied: &copied) })
        precondition(!copied.contains(corrupt))
        precondition(fails { try destination.copy([corrupt], from: source, copied: &copied) })
        // A new transaction has no trust inherited from the last one.
        var fresh: Set<String> = []
        precondition(fails { try destination.copy([shared], from: source, copied: &fresh) })
        let existing = try source.put(Data("existing destination".utf8))
        _ = try destination.put(Data("existing destination".utf8))
        try Data("bad destination".utf8).write(to: destination.directory.appendingPathComponent(existing))
        precondition(fails { try destination.copy([existing], from: source, copied: &copied) })
        precondition(!copied.contains(existing))
        // Packed inheritance survives reopening and source removal, while
        // newly captured objects may still be loose beside the archive.
        let reopened = try HistoryObjectStore(directory: destination.directory)
        precondition(tryValue { try reopened.get([shared, other, shared]) } == [Data("shared ancestor".utf8), Data("second ancestor".utf8), Data("shared ancestor".utf8)])
        let known = try source.put(Data("abc".utf8))
        precondition(known == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let archiveURL = destination.directory.appendingPathComponent(HistoryObjectStore.archiveName)
        let goodArchive = try Data(contentsOf: archiveURL)
        precondition(fails { try destination.copy([known], from: source, copied: &copied, preloaded: [known: Data("wrong bytes".utf8)]) })
        precondition(!copied.contains(known))
        precondition(tryValue { try Data(contentsOf: archiveURL) } == goodArchive)
        try FileManager.default.removeItem(at: source.directory.appendingPathComponent(known))
        try destination.copy([known], from: source, copied: &copied, preloaded: [known: Data("abc".utf8)])
        precondition(tryValue { try HistoryObjectStore(directory: destination.directory).get(known) } == Data("abc".utf8))
        let loose = try destination.put(Data("later snapshot".utf8))
        let mixed = try HistoryObjectStore(directory: destination.directory)
        precondition(tryValue { try mixed.get([shared, known, loose]) } == [Data("shared ancestor".utf8), Data("abc".utf8), Data("later snapshot".utf8)])
        var grandchild = try HistoryObjectStore(directory: scratch.appendingPathComponent("grandchild"))
        var inherited: Set<String> = []
        try grandchild.copy([shared, known, loose], from: mixed, copied: &inherited)
        try FileManager.default.removeItem(at: source.directory)
        try FileManager.default.removeItem(at: destination.directory)
        let independent = try HistoryObjectStore(directory: grandchild.directory)
        precondition(tryValue { try independent.get([shared, known, loose]) } == [Data("shared ancestor".utf8), Data("abc".utf8), Data("later snapshot".utf8)])
        precondition(tryValue { try FileManager.default.contentsOfDirectory(atPath: grandchild.directory.path) } == [HistoryObjectStore.archiveName])

        let packedFile = grandchild.directory.appendingPathComponent(HistoryObjectStore.archiveName)
        let intact = try Data(contentsOf: packedFile)
        for bad: [String: Any] in [
            ["version": 2, "objects": [known: Data("abc".utf8)]],
            ["version": 1, "objects": [known: Data("wrong digest".utf8)]],
            ["version": 1, "objects": ["../escape": Data("abc".utf8)]],
        ] {
            try PropertyListSerialization.data(fromPropertyList: bad, format: .binary, options: 0).write(to: packedFile)
            for _ in 0..<2 { precondition(fails { _ = try HistoryObjectStore(directory: grandchild.directory) }) }
        }
        try Data("truncated archive".utf8).write(to: packedFile)
        precondition(fails { _ = try HistoryObjectStore(directory: grandchild.directory) })
        try FileManager.default.removeItem(at: packedFile)
        let outside = scratch.appendingPathComponent("outside.plist")
        try intact.write(to: outside)
        try FileManager.default.createSymbolicLink(at: packedFile, withDestinationURL: outside)
        precondition(fails { _ = try HistoryObjectStore(directory: grandchild.directory) })
        precondition(tryValue { try Data(contentsOf: outside) } == intact)
        try FileManager.default.removeItem(at: packedFile)
        try intact.write(to: packedFile)
        precondition(tryValue { try HistoryObjectStore(directory: grandchild.directory).get(known) } == Data("abc".utf8))
        print("PASS: production HistoryObjectStore checks: loose and packed objects, verified preloads, independent descendants, reopen, corruption, symlinks and retry")
    }

    private static func fails(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    private static func tryValue<T>(_ body: () throws -> T) -> T {
        do { return try body() } catch { fatalError("Unexpected error: \(error)") }
    }
}
