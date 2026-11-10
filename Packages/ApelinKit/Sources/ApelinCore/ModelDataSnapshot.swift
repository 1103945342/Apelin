import Foundation

/// models.dev's catalog as Apelin keeps it on the device: what a conversation
/// reads a model against — its window, its reply ceiling, what it accepts,
/// whether it reasons — trimmed to those fields and written beside the rest of
/// the app's data, so the agent reads a model it has never heard of without
/// reaching the network.
///
/// The file is `ModelData/models.json` in the data folder, written by the app
/// when the user updates it and read by the agent, which finds the newest
/// models through the same normalization a relay's own names go through.
public struct ModelDataSnapshot: Codable, Sendable, Equatable {
    /// One model, as models.dev lists it.
    public struct Model: Codable, Sendable, Equatable {
        public var name: String?
        /// Tokens a conversation may take.
        public var context: Int?
        /// The most a reply may be.
        public var output: Int?
        /// Input modalities, models.dev's own words: `text`, `image`, `pdf`.
        public var input: [String]?
        public var reasoning: Bool?
        /// The efforts the provider lists for it (`low`, `high`, `max`), in
        /// the order it lists them.
        public var efforts: [String]?
        public var cost: Cost?

        public init(
            name: String? = nil,
            context: Int? = nil,
            output: Int? = nil,
            input: [String]? = nil,
            reasoning: Bool? = nil,
            efforts: [String]? = nil,
            cost: Cost? = nil,
        ) {
            self.name = name
            self.context = context
            self.output = output
            self.input = input
            self.reasoning = reasoning
            self.efforts = efforts
            self.cost = cost
        }
    }

    /// Per million tokens, as models.dev prices it.
    public struct Cost: Codable, Sendable, Equatable {
        public var input: Double?
        public var output: Double?
        public var cacheRead: Double?
        public var cacheWrite: Double?

        public init(input: Double? = nil, output: Double? = nil, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    /// When this copy was written.
    public var generatedAt: Date?
    /// The address it came from, for the settings page to name.
    public var source: String?
    /// `<provider>/<model>`, both as models.dev spells them.
    public var models: [String: [String: Model]]

    public init(
        generatedAt: Date? = nil,
        source: String? = nil,
        models: [String: [String: Model]] = [:],
    ) {
        self.generatedAt = generatedAt
        self.source = source
        self.models = models
    }

    /// How many models the copy names.
    public var count: Int {
        models.values.reduce(0) { $0 + $1.count }
    }
}

// MARK: - Where it lives

extension ModelDataSnapshot {
    /// The folder inside the data folder: `ModelData/`.
    public static let folderName = "ModelData"
    /// The file inside it.
    public static let fileName = "models.json"
    /// models.dev's whole catalog, the one the app downloads.
    public static let remoteURL = URL(string: "https://models.dev/api.json")!
    /// The copy this repository's daily update keeps, already in this shape.
    /// models.dev answers from Japan and is slow from China; the repository's
    /// copy comes through jsDelivr, which is reachable there.
    public static let mirrorURL =
        URL(string: "https://cdn.jsdelivr.net/gh/1103945342/Apelin@main/Apelin/Resources/models.dev.json")!
    /// How old the copy may be before the app looks for a newer one.
    public static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    /// `<data folder>/ModelData/models.json`, the one file the app writes and
    /// the agent reads.
    public static func url(in dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

// MARK: - Reading and writing

extension ModelDataSnapshot {
    /// The copy at `url`, nil when it is missing or does not read: a snapshot
    /// that cannot be read is never a reason to fail a conversation, which
    /// falls back to the catalog kwwk ships.
    public static func read(_ url: URL) -> ModelDataSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// The copy `data` holds, nil when it is not this shape: the app reads
    /// models.dev's trimmed form and its own bundled copy the same way.
    public static func decode(_ data: Data) -> ModelDataSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ModelDataSnapshot.self, from: data)
    }

    /// The copy the app ships, read from its own bundle: what a device reads
    /// before it has ever reached the network, and what it falls back to when a
    /// copy it downloaded does not read.
    public static func bundled(in bundle: Bundle = .main) -> ModelDataSnapshot? {
        guard let url = bundle.url(forResource: bundledResource, withExtension: "json") else { return nil }
        return read(url)
    }

    /// The bundled copy's file name without its extension.
    public static let bundledResource = "models.dev"

    /// Whether a newer copy is worth asking for: one that never says when it
    /// was written is always stale, and a copy the clock puts in the future is
    /// not.
    public func isStale(now: Date = Date(), interval: TimeInterval = ModelDataSnapshot.refreshInterval) -> Bool {
        guard let generatedAt else { return true }
        return now.timeIntervalSince(generatedAt) > interval
    }

    /// Writes the copy beside the others, making `ModelData/` on the way.
    /// `makeLevels` makes the levels below a data folder the package already
    /// made; without one, the file's own folder is made if missing.
    public func write(to url: URL, makeLevels: ((URL) throws -> Void)? = nil) throws {
        let folder = url.deletingLastPathComponent()
        if let makeLevels {
            try makeLevels(folder)
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - models.dev

extension ModelDataSnapshot {
    /// models.dev's `api.json`, trimmed to what Apelin reads: every provider it
    /// names, every model, and the fields `Model` keeps. A provider or a model
    /// without a number Apelin uses is still written, so a later edit of
    /// models.dev's shape cannot silently empty the file.
    public static func parse(modelsDev data: Data, source: String = ModelDataSnapshot.remoteURL.absoluteString) throws -> ModelDataSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var models: [String: [String: Model]] = [:]
        for (providerID, value) in root {
            guard let provider = value as? [String: Any],
                  let listed = provider["models"] as? [String: Any]
            else { continue }
            var entries: [String: Model] = [:]
            for (modelID, raw) in listed {
                guard let raw = raw as? [String: Any] else { continue }
                entries[modelID] = model(raw)
            }
            if !entries.isEmpty {
                models[providerID] = entries
            }
        }
        guard !models.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return ModelDataSnapshot(generatedAt: Date(), source: source, models: models)
    }

    private static func model(_ raw: [String: Any]) -> Model {
        let limit = raw["limit"] as? [String: Any]
        let modalities = raw["modalities"] as? [String: Any]
        let cost = raw["cost"] as? [String: Any]
        let input = (modalities?["input"] as? [String]) ?? (raw["input"] as? [String])
        return Model(
            name: raw["name"] as? String,
            context: integer(limit?["context"] ?? raw["context"] ?? raw["context_window"]),
            output: integer(limit?["output"] ?? raw["output"] ?? raw["max_tokens"]),
            input: input?.filter { !$0.isEmpty },
            reasoning: raw["reasoning"] as? Bool,
            efforts: efforts(raw["reasoning_options"]),
            cost: cost.map {
                Cost(
                    input: double($0["input"]),
                    output: double($0["output"]),
                    cacheRead: double($0["cache_read"]),
                    cacheWrite: double($0["cache_write"]),
                )
            },
        )
    }

    /// models.dev's `reasoning_options`: an `effort` entry lists the levels the
    /// model takes, a `toggle` entry none Apelin can grade.
    private static func efforts(_ value: Any?) -> [String]? {
        guard let options = value as? [[String: Any]] else { return nil }
        for option in options where (option["type"] as? String) == "effort" {
            guard let values = option["values"] as? [String], !values.isEmpty else { continue }
            return values.map { $0.lowercased() }
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int, number > 0 { return number }
        if let number = value as? Double, number > 0 { return Int(number) }
        if let text = value as? String, let number = Int(text), number > 0 { return number }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let text = value as? String, let number = Double(text) { return number }
        return nil
    }
}
