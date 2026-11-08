@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

@Suite("Native image generation")
struct NativeImageGenerationTests {
    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="

    @Test
    func knownNativeProvidersSelectTheirNativeBackend() {
        #expect(NativeImageGeneration.backend(for: .stored(storeID: "openai-api-key", model: "gpt-image-1"), model: Model(id: "gpt-image-1", api: "openai", provider: "openai", baseURL: "https://api.openai.com")) == .openAI)
        #expect(NativeImageGeneration.backend(for: .stored(storeID: "google-api-key", model: "gemini-2.0-flash-exp-image-generation"), model: Model(id: "gemini-2.0-flash-exp-image-generation", api: "gemini", provider: "google", baseURL: "https://generativelanguage.googleapis.com")) == .gemini)
        #expect(NativeImageGeneration.backend(for: .stored(storeID: "openai-api-key", model: "gpt-4o"), model: Model(id: "gpt-4o", api: "openai", provider: "openai", baseURL: "https://api.openai.com")) == nil)
        #expect(NativeImageGeneration.backend(for: .stored(storeID: "anthropic-api-key", model: "claude"), model: Model(id: "claude", api: "anthropic", provider: "anthropic", baseURL: "https://api.anthropic.com")) == nil)
    }

    @Test
    func endpointAppendsProviderPathWithoutDuplicatingVersion() throws {
        let openAI = try NativeImageGeneration.endpoint(
            baseURL: "https://api.openai.com/v1",
            suffix: ["images", "generations"],
            prefix: "v1"
        )
        #expect(openAI.absoluteString == "https://api.openai.com/v1/images/generations")

        let gemini = try NativeImageGeneration.endpoint(
            baseURL: "https://generativelanguage.googleapis.com/v1beta/",
            suffix: ["models", "gemini-2.0-flash-exp-image-generation:generateContent"],
            prefix: "v1beta"
        )
        #expect(gemini.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp-image-generation:generateContent")
    }

    @Test
    func nativeImageBytesKeepTheirRealMIMEType() throws {
        let image = try NativeImageGeneration.image(
            fromBase64: "data:image/png;base64,\(Self.png)",
            preferredMIMEType: "image/jpeg"
        )
        #expect(image.data == Self.png)
        #expect(image.mimeType == "image/png")
    }

    @Test
    func invalidOrNonImageNativeDataIsRejected() {
        #expect(throws: NativeImageGeneration.Failure.invalidImage) {
            try NativeImageGeneration.image(fromBase64: "not-base64", preferredMIMEType: "image/png")
        }
        #expect(throws: NativeImageGeneration.Failure.invalidImage) {
            try NativeImageGeneration.image(
                fromBase64: Data("plain text".utf8).base64EncodedString(),
                preferredMIMEType: "text/plain"
            )
        }
    }
}
