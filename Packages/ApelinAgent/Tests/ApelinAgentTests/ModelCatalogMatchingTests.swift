import Testing
@testable import ApelinAgent

/// What a name finds in the catalogs: a model id, or the name a catalog gives
/// the model it files differently.
struct ModelCatalogMatchingTests {
    private static func entry(
        _ id: String,
        _ provider: String,
        _ name: String,
        window: Int = 0,
        tokens: Int = 0,
    ) -> ModelCatalogIndex.Entry {
        ModelCatalogIndex.Entry(
            id: id,
            provider: provider,
            name: name,
            contextWindow: window,
            maxTokens: tokens,
            acceptsImages: true,
            reasoning: true,
            efforts: ["high"],
            thinkingLevelMap: nil,
            fromSnapshot: false,
        )
    }

    /// What kwwk ships: the model a relay calls `deepseek-v4.1-flash` is filed
    /// as `deepseek-flash` and named in words.
    private static let bundled = ModelCatalogIndex.table([
        (
            provider: "deepseek",
            models: [
                (
                    id: "deepseek-flash",
                    entry: entry("deepseek-flash", "deepseek", "DeepSeek V4.1 Flash", window: 1_000_000, tokens: 64_000),
                ),
                (
                    id: "deepseek-v4-pro",
                    entry: entry("deepseek-v4-pro", "deepseek", "DeepSeek V4 Pro", window: 256_000, tokens: 64_000),
                ),
            ],
        ),
    ])

    private static let none = ModelCatalogIndex.Table()

    @Test func `a relay's name finds the model a catalog names in words`() {
        let found = ModelCatalogIndex.entry(for: "cn:deepseek-v4.1-flash", catalogKey: nil, bundled: bundled, snapshot: none)
        #expect(found?.id == "deepseek-flash")
        #expect(found?.contextWindow == 1_000_000)
        #expect(found?.maxTokens == 64_000)
    }

    @Test func `a provider's own key is asked first and finds the same entry`() {
        let found = ModelCatalogIndex.entry(for: "cn:deepseek-v4.1-flash", catalogKey: "deepseek", bundled: bundled, snapshot: none)
        #expect(found?.id == "deepseek-flash")
    }

    @Test func `a relay's spelling with a space after the prefix still finds it`() {
        let found = ModelCatalogIndex.entry(for: "free: deepseek-v4.1-flash", catalogKey: nil, bundled: bundled, snapshot: none)
        #expect(found?.id == "deepseek-flash")
    }

    @Test func `a version alone is not a model`() {
        #expect(ModelCatalogIndex.entry(for: "v4.1", catalogKey: nil, bundled: bundled, snapshot: none) == nil)
        #expect(ModelCatalogIndex.entry(for: "flash", catalogKey: nil, bundled: bundled, snapshot: none) == nil)
        #expect(ModelCatalogIndex.entry(for: "cn:", catalogKey: nil, bundled: bundled, snapshot: none) == nil)
    }

    @Test func `a name the catalog files as itself keeps its own entry`() {
        let found = ModelCatalogIndex.entry(for: "deepseek-v4-pro", catalogKey: "deepseek", bundled: bundled, snapshot: none)
        #expect(found?.id == "deepseek-v4-pro")
    }

    @Test func `a model only models.dev names is read from that copy`() {
        let snapshot = ModelCatalogIndex.table([
            (
                provider: "acme",
                models: [
                    (id: "acme-mk2", entry: entry("acme-mk2", "acme", "Acme MK2", window: 128_000, tokens: 8_000)),
                ],
            ),
        ])
        let found = ModelCatalogIndex.entry(for: "acme-mk2", catalogKey: nil, bundled: bundled, snapshot: snapshot)
        #expect(found?.id == "acme-mk2")
        #expect(found?.contextWindow == 128_000)
    }

    @Test func `a model neither copy names is left alone`() {
        #expect(ModelCatalogIndex.entry(for: "anthropic/claude-sonnet-4.5", catalogKey: nil, bundled: bundled, snapshot: none) == nil)
    }

    /// The account list reads a whole set at once; every model in it must be
    /// what the single lookup answers, or a batch would be a second rule.
    @Test func `a batch answers each model exactly as a single lookup does`() {
        let snapshot = ModelCatalogIndex.table([
            (
                provider: "acme",
                models: [
                    (id: "acme-mk2", entry: entry("acme-mk2", "acme", "Acme MK2", window: 128_000, tokens: 8_000)),
                ],
            ),
        ])
        let ids = [
            "cn:deepseek-v4.1-flash", "free: deepseek-v4.1-flash", "deepseek-v4-pro",
            "acme-mk2", "anthropic/claude-sonnet-4.5", "", "cn:", "v4.1",
        ]
        for key in [String?.none, "deepseek", "acme"] {
            let batch = ModelCatalogIndex.entries(for: ids, catalogKey: key, bundled: bundled, snapshot: snapshot)
            for id in ids {
                #expect(
                    batch[id] == ModelCatalogIndex.entry(for: id, catalogKey: key, bundled: bundled, snapshot: snapshot),
                    "\(id) under \(key ?? "-")",
                )
            }
            #expect(batch["anthropic/claude-sonnet-4.5"] == nil)
        }
    }

    @Test func `a batch answers one entry per id asked for`() {
        let batch = ModelCatalogIndex.entries(
            for: ["deepseek-flash", "deepseek-flash"],
            catalogKey: nil, bundled: bundled, snapshot: none,
        )
        #expect(batch.count == 1)
        #expect(batch["deepseek-flash"]?.id == "deepseek-flash")
        // Two spellings of one model are two ids, and the account list asks by
        // the id it was given, so each is answered under its own.
        let spelled = ModelCatalogIndex.entries(
            for: ["deepseek-flash", "cn:deepseek-v4.1-flash"],
            catalogKey: nil, bundled: bundled, snapshot: none,
        )
        #expect(spelled.count == 2)
        #expect(spelled["cn:deepseek-v4.1-flash"]?.id == "deepseek-flash")
        #expect(ModelCatalogIndex.entries(for: [], catalogKey: "deepseek", bundled: bundled, snapshot: none).isEmpty)
    }

    /// The order a lookup keeps, kept: a provider's own models.dev copy is
    /// asked before another provider's bundled row, and a batch must not push
    /// models.dev's copy behind them to save a walk.
    @Test func `a provider's snapshot copy still answers before another provider's bundled row`() {
        // The bundled rows know this id under acme alone; models.dev's copy is
        // deepseek's own. Asked by deepseek's key, its copy must answer.
        let bundledElsewhere = ModelCatalogIndex.table([
            (
                provider: "acme",
                models: [(id: "deepseek-flash", entry: entry("deepseek-flash", "acme", "Acme Flash", window: 8_000))],
            ),
        ])
        let snapshot = ModelCatalogIndex.table([
            (
                provider: "deepseek",
                models: [(id: "deepseek-flash", entry: entry("deepseek-flash", "deepseek", "DeepSeek V4.1 Flash", window: 32_000))],
            ),
        ])
        let found = ModelCatalogIndex.entries(for: ["deepseek-flash"], catalogKey: "deepseek", bundled: bundledElsewhere, snapshot: snapshot)
        #expect(found["deepseek-flash"]?.provider == "deepseek")
        #expect(found["deepseek-flash"]?.contextWindow == 32_000)
        #expect(ModelCatalogIndex.entry(for: "deepseek-flash", catalogKey: "deepseek", bundled: bundledElsewhere, snapshot: snapshot)?.provider == "deepseek")
        // Without a key, every bundled provider is asked before models.dev.
        #expect(ModelCatalogIndex.entries(for: ["deepseek-flash"], catalogKey: nil, bundled: bundledElsewhere, snapshot: snapshot)["deepseek-flash"]?.provider == "acme")
    }

    @Test func `a provider's snapshot copy answers a name before the other providers' bundled rows`() {
        let bundledElsewhere = ModelCatalogIndex.table([
            (
                provider: "acme",
                models: [(id: "deepseek-v4.1-flash", entry: entry("deepseek-v4.1-flash", "acme", "Acme Flash", window: 8_000))],
            ),
        ])
        let snapshot = ModelCatalogIndex.table([
            (
                provider: "deepseek",
                models: [(id: "ds-41f", entry: entry("ds-41f", "deepseek", "DeepSeek V4.1 Flash", window: 32_000))],
            ),
        ])
        let found = ModelCatalogIndex.entries(for: ["deepseek-v4.1-flash"], catalogKey: "deepseek", bundled: bundledElsewhere, snapshot: snapshot)
        #expect(found["deepseek-v4.1-flash"]?.id == "ds-41f")
        #expect(found["deepseek-v4.1-flash"]?.provider == "deepseek")
    }
}
