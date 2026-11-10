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
}
