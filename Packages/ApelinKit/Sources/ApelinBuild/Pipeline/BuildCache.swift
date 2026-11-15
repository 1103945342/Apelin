import ApelinProject
import Foundation

/// Compiled code kept between builds of one project.
///
/// A build wipes its own work directory (`BuildService`), so nothing written
/// there survives to the next one, and every compile used to start from the
/// sources again. This cache sits beside the builds
/// (`Builds/.build-cache/<projectID>/`) and is content addressed: an entry is
/// used only when its key — the toolchain and SDK digests, the target, the
/// optimisation, the flags and defines that compile passes, every source's
/// SHA-256 and the keys of the modules it imports — is exactly the one this
/// build would compile with. Nothing is keyed on a modification time, a build
/// ID or a path that moves when roothide renames its root.
///
/// Every byte read back is checked against the digest it was stored with. An
/// entry that does not read, a file that is missing or a digest that differs
/// is a miss: the unit is compiled again and the entry replaced. A cache the
/// build cannot write is never a failed build — it is a slower one.
///
/// What is deliberately absent from a key: the build ID (Swift never sees
/// `APELIN_BUILD_ID`; C-family compiles do, and their key carries the whole
/// define list instead), the work directory, `-module-cache-path`, and any
/// path under the project or the install root, which `stablePath` spells
/// relative.
final class BuildCache {
    enum Kind: String {
        case swiftModule = "module"
        case swiftProduct = "swift"
        case clangObject = "clang"
    }

    struct Unit: Hashable {
        var kind: Kind
        var name: String
        var arch: String

        /// The folder a unit's entries live in. The name is hashed: a clang
        /// unit's name carries a source path, which no folder should.
        var identifier: String {
            let digest = CanonicalJSON.sha256Hex(Data(name.utf8))
            return "\(kind.rawValue)-\(String(digest.prefix(16)))-\(arch)"
        }
    }

    struct Output {
        /// The file's name inside the entry.
        var name: String
        /// Where this build expects it.
        var destination: String
    }

    /// Bumped whenever the shape of a key or an entry changes: nothing older
    /// is read, and `prune` reaps it.
    static let version = 1
    /// What the cache may take on disk before its least recently used entries go.
    static let budget = 1 << 30
    /// Entries kept per unit, the most recently used ones.
    static let entriesPerUnit = 2

    let root: URL
    let projectRoot: String
    let installRoot: String
    private(set) var hits = 0
    private(set) var misses = 0
    /// Told once when an entry could not be written, so a cache that never
    /// fills says why instead of only being slow.
    var log: ((String) -> Void)?
    private var reportedFailure = false

    init(root: URL, projectRoot: String, installRoot: String) {
        self.root = root
        self.projectRoot = projectRoot.hasSuffix("/") ? String(projectRoot.dropLast()) : projectRoot
        self.installRoot = installRoot
    }

    // MARK: Keys

    /// The digest of everything a compile was given. Members are ordered by
    /// the caller and made canonical by `CanonicalJSON`, so the same inputs
    /// give the same key whatever order the project file listed them in.
    func key(_ unit: Unit, _ members: [(String, JSONDocument)]) -> String {
        var entries: [(key: String, value: JSONDocument)] = [
            ("format", .integer(Int64(Self.version))),
            ("kind", .string(unit.kind.rawValue)),
            ("unit", .string(unit.name)),
            ("arch", .string(unit.arch)),
        ]
        entries += members.map { (key: $0.0, value: $0.1) }
        return CanonicalJSON.digest(.object(JSONObject(entries)))
    }

    /// A path as a key may spell it: under the project or the install root it
    /// is relative to it, so a renamed jbroot keeps what the last boot
    /// compiled.
    func stablePath(_ path: String) -> String {
        for (prefix, name) in [(projectRoot, "<project>"), (installRoot, "<root>")] where !prefix.isEmpty {
            if path == prefix {
                return name
            }
            if path.hasPrefix(prefix + "/") {
                return name + String(path.dropFirst(prefix.count))
            }
        }
        return path
    }

    /// Every source of a compile, with the digest of its bytes, in the order
    /// the compile lists them.
    func sourceDigests(_ sources: [ProjectGlob.Match]) throws -> JSONDocument {
        var entries: [JSONDocument] = []
        for source in sources {
            let digest = try Self.fileDigest(source.path)
            entries.append(.array([.string(source.relative), .string(digest)]))
        }
        return .array(entries)
    }

    /// The files under each declared header search path, with the digest of
    /// their bytes: a header is an input of a compile the project description
    /// never names one by one, so a header that changes must rebuild what
    /// imports it.
    func headerDigests(_ directories: [String]) throws -> JSONDocument {
        var files: [(path: String, digest: String)] = []
        for directory in directories {
            let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            guard let walker = FileManager.default.enumerator(atPath: base) else { continue }
            for case let relative as String in walker {
                let candidate = base + "/" + relative
                var info = stat()
                guard lstat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                files.append((stablePath(candidate), try Self.fileDigest(candidate)))
            }
        }
        files.sort { $0.path < $1.path }
        return .array(files.map { .array([.string($0.path), .string($0.digest)]) })
    }

    static func fileDigest(_ path: String) throws -> String {
        CanonicalJSON.sha256Tag(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    // MARK: Entries

    /// Puts a stored entry's files where this build expects them, or answers
    /// false and leaves the work directory alone.
    func restore(_ unit: Unit, key: String, outputs: [Output]) -> Bool {
        let directory = entryDirectory(unit, key: key)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              manifest["version"] as? Int == Self.version,
              manifest["key"] as? String == key,
              let files = manifest["outputs"] as? [[String: Any]]
        else {
            return false
        }
        var plans: [(source: String, destination: String)] = []
        for output in outputs {
            guard let file = files.first(where: { $0["name"] as? String == output.name }),
                  let digest = file["sha256"] as? String
            else {
                return false
            }
            let source = directory.appendingPathComponent(output.name).path
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: source)),
                  CanonicalJSON.sha256Tag(bytes) == digest
            else {
                return false
            }
            plans.append((source, output.destination))
        }
        for plan in plans {
            let parent = (plan.destination as NSString).deletingLastPathComponent
            guard (try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)) != nil else {
                return false
            }
            try? FileManager.default.removeItem(atPath: plan.destination)
            guard (try? FileManager.default.copyItem(atPath: plan.source, toPath: plan.destination)) != nil else {
                return false
            }
        }
        touch(directory)
        hits += 1
        return true
    }

    /// Keeps what a compile just made for the next build with the same inputs.
    /// Written in a temporary directory beside the entry and renamed into
    /// place, so a build killed mid-write never leaves a half entry that
    /// reads; two builds racing for one key keep whichever landed first.
    func store(_ unit: Unit, key: String, outputs: [Output], members: [(String, JSONDocument)]) {
        let unitDirectory = root.appendingPathComponent(unit.identifier, isDirectory: true)
        let temporary = unitDirectory.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        var total = 0
        do {
            try FileManager.default.createDirectory(at: unitDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            var files: [[String: Any]] = []
            for output in outputs {
                let data = try Data(contentsOf: URL(fileURLWithPath: output.destination))
                try data.write(to: temporary.appendingPathComponent(output.name), options: .atomic)
                files.append([
                    "name": output.name,
                    "sha256": CanonicalJSON.sha256Tag(data),
                    "bytes": data.count,
                ])
                total += data.count
            }
            let now = Int(Date().timeIntervalSince1970)
            let manifest: [String: Any] = [
                "version": Self.version,
                "kind": unit.kind.rawValue,
                "unit": unit.name,
                "arch": unit.arch,
                "key": key,
                "createdAt": now,
                "lastUsedAt": now,
                "bytes": total,
                "outputs": files,
                "inputs": members.map { ["name": $0.0, "value": CanonicalJSON.string($0.1)] },
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            try data.write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            report("compile cache: \(unit.name) could not be kept: \(error.localizedDescription)")
            misses += 1
            return
        }
        misses += 1
        let destination = entryDirectory(unit, key: key)
        if rename(temporary.path, destination.path) != 0 {
            // An entry for this key is already there: one an earlier build
            // left, or one whose output did not verify. Replace it, and keep
            // the old one if the rename still fails (another build wrote a
            // good entry for the same key in between).
            try? FileManager.default.removeItem(at: destination)
            if rename(temporary.path, destination.path) != 0 {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
    }

    /// Removes what this project's builds no longer need: all but the two most
    /// recently used entries of each unit, then the least recently used until
    /// the cache fits its budget. Entries of an older format go first.
    func prune() {
        var kept: [(url: URL, lastUsed: Int, bytes: Int)] = []
        for unit in contents(of: root) where Self.isDirectory(unit) {
            var survivors: [(url: URL, lastUsed: Int, bytes: Int)] = []
            for entry in contents(of: unit) {
                guard !entry.lastPathComponent.hasPrefix(".") else {
                    // An abandoned write: only one a day old is certainly not
                    // a build still writing it.
                    if Self.isOlderThanADay(entry) {
                        try? FileManager.default.removeItem(at: entry)
                    }
                    continue
                }
                guard Self.isDirectory(entry),
                      let data = try? Data(contentsOf: entry.appendingPathComponent("manifest.json")),
                      let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else {
                    try? FileManager.default.removeItem(at: entry)
                    continue
                }
                survivors.append((
                    entry,
                    manifest["lastUsedAt"] as? Int ?? 0,
                    manifest["bytes"] as? Int ?? 0
                ))
            }
            survivors.sort { $0.lastUsed > $1.lastUsed }
            for (index, entry) in survivors.enumerated() {
                if index < Self.entriesPerUnit {
                    kept.append(entry)
                } else {
                    try? FileManager.default.removeItem(at: entry.url)
                }
            }
            if Self.isEmpty(unit) {
                try? FileManager.default.removeItem(at: unit)
            }
        }
        var total = kept.reduce(0) { $0 + $1.bytes }
        for entry in kept.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > Self.budget {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }

    // MARK: The disk

    private func entryDirectory(_ unit: Unit, key: String) -> URL {
        root.appendingPathComponent(unit.identifier, isDirectory: true)
            .appendingPathComponent(key.hasPrefix("sha256:") ? String(key.dropFirst("sha256:".count)) : key, isDirectory: true)
    }

    private func touch(_ directory: URL) {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return
        }
        manifest["lastUsedAt"] = Int(Date().timeIntervalSince1970)
        guard let updated = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) else {
            return
        }
        try? updated.write(to: url, options: .atomic)
    }

    private func report(_ line: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        log?(line)
    }

    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    private static func isEmpty(_ directory: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? false
    }

    private static func isOlderThanADay(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else {
            return false
        }
        return modified.timeIntervalSinceNow < -86400
    }
}
