import ApelinCore
import Foundation
import KWWKAI

/// The catalogs Apelin reads a model against, and the one lookup that answers
/// what a model is.
///
/// Two copies are read: the catalog kwwk ships (which describes the models of
/// the providers it signs in to) and models.dev's, trimmed to the fields a
/// conversation uses and kept on the device (`ModelDataSnapshot`). A provider's
/// own copy is asked first — `deepseek`'s entry for `deepseek-v4.1-flash`
/// before the same name under a reseller — and then every copy of every
/// provider, so a relay's model is read as itself even when the relay is not
/// one the catalog keys.
public struct ModelCatalogIndex: Sendable {
    /// One model as a catalog lists it.
    public struct Entry: Sendable, Hashable {
        /// The model's name in the catalog.
        public var id: String
        /// The provider the catalog files it under.
        public var provider: String
        /// Its display name.
        public var name: String
        /// Tokens a conversation may take.
        public var contextWindow: Int
        /// The most a reply may be.
        public var maxTokens: Int
        /// Whether it takes images.
        public var acceptsImages: Bool
        /// Whether it thinks before it answers.
        public var reasoning: Bool
        /// The levels it takes, in the catalog's own words (`low`, `high`).
        public var efforts: [String]
        /// What each level is called on the wire. Absent leaves the provider's
        /// own defaults.
        public var thinkingLevelMap: [String: String?]?
        /// Read from models.dev's copy rather than the one kwwk ships.
        public var fromSnapshot: Bool

        /// The catalog to name on screen.
        public var source: String { fromSnapshot ? "models.dev" : "catalog" }
    }

    /// What this index reads. Built once and shared; one that is rebuilt (the
    /// app wrote a newer copy, or deleted it) replaces the other.
    private static let shared = SharedIndex()

    public init() {}

    /// The entry for a model, or nil when no catalog knows it.
    ///
    /// `catalogKey` is the provider key to ask first — kwwk's own
    /// (`deepseek`, `anthropic`, `openai`), or nil for an endpoint the
    /// catalogs do not key, which is read from every provider's copy.
    public func entry(for id: String, catalogKey: String? = nil) -> Entry? {
        let candidates = ModelIdentity.candidates(id)
        guard !candidates.isEmpty else { return nil }
        let bundled = Self.shared.bundled
        let snapshot = Self.shared.snapshot()
        if let key = catalogKey?.lowercased(), !key.isEmpty {
            if let entry = Self.best(in: bundled.byProvider[key] ?? [:], for: candidates)
                ?? Self.best(in: snapshot.byProvider[key] ?? [:], for: candidates) {
                return entry
            }
        }
        if let entry = Self.best(in: bundled.byID, for: candidates) {
            return entry
        }
        return Self.best(in: snapshot.byID, for: candidates)
    }

    /// Every model a catalog keys under `catalogKey`, as that catalog names
    /// them the provider's own list does not.
    public func entries(catalogKey: String) -> [Entry] {
        let key = catalogKey.lowercased()
        let bundled = Self.shared.bundled.byProvider[key] ?? [:]
        return bundled.values.sorted { $0.id < $1.id }
    }

    // MARK: - Lookup

    /// The first candidate that answers, longest stretch of it first.
    private static func best(in rows: [String: Entry], for candidates: [String]) -> Entry? {
        for candidate in candidates {
            for stretch in ModelIdentity.stretches(candidate) {
                if let entry = rows[stretch] { return entry }
            }
        }
        return nil
    }

    /// The best of several providers' copies of one name: the provider the name
    /// itself mentions (`deepseek-v4.1-flash` is DeepSeek's), then the first by
    /// provider key, so the choice never depends on a dictionary's order.
    private static func best(in rows: [String: [Entry]], for candidates: [String]) -> Entry? {
        for candidate in candidates {
            for stretch in ModelIdentity.stretches(candidate) {
                if let entries = rows[stretch], let entry = entries.first { return entry }
            }
        }
        return nil
    }

    // MARK: - The tables

    struct Table: Sendable {
        /// Provider key → lowercased model id → entry.
        var byProvider: [String: [String: Entry]] = [:]
        /// Lowercased model id → every provider's entry, best first.
        var byID: [String: [Entry]] = [:]

        /// Files each entry under its name, once, with every provider's copies
        /// of a name ordered: the provider the name mentions first, then by
        /// provider key.
        mutating func indexByID() {
            var byID: [String: [Entry]] = [:]
            for (_, rows) in byProvider {
                for (key, entry) in rows {
                    byID[key, default: []].append(entry)
                }
            }
            for key in byID.keys {
                byID[key]?.sort { left, right in
                    let named = key.contains(left.provider.lowercased())
                    let otherNamed = key.contains(right.provider.lowercased())
                    if named != otherNamed { return named }
                    return left.provider < right.provider
                }
            }
            self.byID = byID
        }
    }

    /// Builds the table over whatever a caller hands it, so the same rules file
    /// kwwk's catalog and models.dev's copy alike.
    static func table(_ providers: [(provider: String, models: [(id: String, entry: Entry)])]) -> Table {
        var table = Table()
        for row in providers {
            var rows: [String: Entry] = [:]
            for model in row.models {
                rows[model.id.lowercased()] = model.entry
            }
            if !rows.isEmpty {
                table.byProvider[row.provider.lowercased()] = rows
            }
        }
        table.indexByID()
        return table
    }

    /// kwwk's bundled catalog, as entries.
    static func bundledTable() -> Table {
        var providers: [(provider: String, models: [(id: String, entry: Entry)])] = []
        for provider in ModelsCatalog.providers {
            let models = ModelsCatalog.models(for: provider).map { model in
                (id: model.id, entry: entry(for: model, provider: provider))
            }
            providers.append((provider: provider, models: models))
        }
        return table(providers)
    }

    private static func entry(for model: Model, provider: String) -> Entry {
        Entry(
            id: model.id,
            provider: provider,
            name: model.name,
            contextWindow: model.contextWindow,
            maxTokens: model.maxTokens,
            acceptsImages: model.input.contains(.image),
            reasoning: model.reasoning,
            efforts: supportedThinkingLevels(model).map(\.rawValue),
            thinkingLevelMap: model.thinkingLevelMap,
            fromSnapshot: false,
        )
    }

    /// models.dev's copy, as entries.
    static func snapshotTable(_ snapshot: ModelDataSnapshot) -> Table {
        var providers: [(provider: String, models: [(id: String, entry: Entry)])] = []
        for (provider, models) in snapshot.models {
            let rows = models.map { id, model in
                (id: id, entry: Entry(
                    id: id,
                    provider: provider,
                    name: model.name ?? id,
                    contextWindow: model.context ?? 0,
                    maxTokens: model.output ?? 0,
                    acceptsImages: (model.input ?? []).contains { $0.lowercased() == "image" },
                    reasoning: model.reasoning ?? false,
                    efforts: model.efforts ?? [],
                    thinkingLevelMap: nil,
                    fromSnapshot: true,
                ))
            }
            providers.append((provider: provider, models: rows))
        }
        return table(providers)
    }
}

// MARK: - The shared copy

/// The bundled table and the one read from `ModelData/models.json`, held
/// together so a lookup allocates nothing but its candidates.
private final class SharedIndex: @unchecked Sendable {
    /// kwwk's catalog: a constant of the build, read once.
    let bundled: ModelCatalogIndex.Table

    private let lock = NSLock()
    private var signature: String?
    private var table = ModelCatalogIndex.Table()

    init() {
        bundled = ModelCatalogIndex.bundledTable()
    }

    /// models.dev's copy at `ModelData/models.json`, re-read only when the file
    /// it was read from changed. A file that does not read is no copy at all:
    /// a conversation falls back to the catalog kwwk ships rather than fail.
    func snapshot() -> ModelCatalogIndex.Table {
        let url = ApelinDataRoot.current.modelDataFile
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let signature = [
            String(attributes?[.size] as? Int ?? -1),
            String((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1),
        ].joined(separator: "-")
        lock.lock()
        defer { lock.unlock() }
        if signature == self.signature {
            return table
        }
        let table = ModelDataSnapshot.read(url).map(ModelCatalogIndex.snapshotTable) ?? ModelCatalogIndex.Table()
        self.signature = signature
        self.table = table
        return table
    }
}
