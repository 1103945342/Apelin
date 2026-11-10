import Foundation
import Testing
@testable import ApelinCore

/// The copy the app ships and the agent reads: the shape models.dev's trimmed
/// form and this repository's own file share, and when it counts as old.
struct ModelDataSnapshotTests {
    private static let json = Data("""
    {
      "generatedAt": "2026-11-10T12:00:00Z",
      "source": "https://models.dev/api.json",
      "models": {
        "deepseek": {
          "deepseek-flash": {
            "name": "DeepSeek V4.1 Flash",
            "context": 1000000,
            "output": 64000,
            "input": ["text", "image"],
            "reasoning": true,
            "efforts": ["high", "low"],
            "cost": {"input": 0.14, "output": 0.28}
          }
        }
      }
    }
    """.utf8)

    @Test func `the shipped shape decodes`() {
        let snapshot = ModelDataSnapshot.decode(Self.json)
        #expect(snapshot?.count == 1)
        let model = snapshot?.models["deepseek"]?["deepseek-flash"]
        #expect(model?.name == "DeepSeek V4.1 Flash")
        #expect(model?.context == 1_000_000)
        #expect(model?.output == 64_000)
        #expect(model?.input == ["text", "image"])
        #expect(model?.reasoning == true)
        #expect(model?.efforts == ["high", "low"])
        #expect(model?.cost?.input == 0.14)
    }

    @Test func `a copy is old after a week and not before`() {
        let written = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ModelDataSnapshot(generatedAt: written, models: [:])
        #expect(snapshot.isStale(now: written.addingTimeInterval(6 * 24 * 60 * 60)) == false)
        #expect(snapshot.isStale(now: written.addingTimeInterval(8 * 24 * 60 * 60)) == true)
    }

    @Test func `a copy that does not say when it was written is always old`() {
        #expect(ModelDataSnapshot(models: [:]).isStale() == true)
    }

    @Test func `data that is not a copy decodes to nothing`() {
        #expect(ModelDataSnapshot.decode(Data("{}".utf8)) == nil)
        #expect(ModelDataSnapshot.decode(Data("not json".utf8)) == nil)
    }
}
