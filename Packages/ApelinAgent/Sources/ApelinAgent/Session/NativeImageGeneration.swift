import Foundation
import KWWKAI

/// Calls a provider's native image endpoint and normalizes its response into
/// the same base64 image payload the agent protocol already carries.
///
/// Providers without a native image endpoint keep the legacy SVG fallback in
/// `AgentSession`; a native request never falls back after it has been sent.
enum NativeImageGeneration {
    enum Backend: Sendable, Equatable {
        case openAI
        case gemini
    }

    enum Failure: Error, LocalizedError, Sendable, Equatable {
        case unsupported
        case missingAuthentication
        case invalidEndpoint
        case requestFailed(status: Int, message: String?)
        case malformedResponse
        case invalidImage
        case imageTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupported:
                "This provider does not expose a native image-generation endpoint."
            case .missingAuthentication:
                "The image provider did not return authentication credentials."
            case .invalidEndpoint:
                "The image provider has an invalid endpoint."
            case let .requestFailed(status, message):
                if let message, !message.isEmpty { return "Image generation failed (HTTP \(status)): \(message)" }
                return "Image generation failed (HTTP \(status))."
            case .malformedResponse:
                "The image provider returned an invalid response."
            case .invalidImage:
                "The image provider returned data that is not a supported image."
            case .imageTooLarge:
                "The generated image is too large to display."
            }
        }
    }

    private struct OpenAIRequest: Encodable {
        let model: String
        let prompt: String
        let n: Int
        let responseFormat: String?

        enum CodingKeys: String, CodingKey {
            case model, prompt, n
            case responseFormat = "response_format"
        }
    }

    private struct OpenAIResponse: Decodable {
        struct Item: Decodable {
            let b64JSON: String?
            let url: String?

            enum CodingKeys: String, CodingKey {
                case b64JSON = "b64_json"
                case url
            }
        }

        let data: [Item]
    }

    private static let maximumImageBytes = 16 * 1024 * 1024

    static func backend(for provider: ProviderConfiguration, model: Model) -> Backend? {
        let modelID = model.id.lowercased()
        switch provider {
        case .stored("openai-api-key", _):
            return modelID.hasPrefix("gpt-image") || modelID.hasPrefix("dall-e") ? .openAI : nil
        case .stored("google-api-key", _):
            return modelID.contains("image") || modelID.contains("imagen") ? .gemini : nil
        case .openAICompatible:
            // A custom OpenAI-compatible account is opt-in only through a
            // clearly image-capable model ID; arbitrary chat models must keep
            // the SVG compatibility path.
            return modelID.hasPrefix("gpt-image") || modelID.hasPrefix("dall-e") ? .openAI : nil
        default:
            return nil
        }
    }

    static func generate(
        backend: Backend,
        model: Model,
        auth: ResolvedProviderAuth?,
        prompt: String
    ) async throws -> AgentGeneratedImage {
        guard let auth else { throw Failure.missingAuthentication }
        switch backend {
        case .openAI:
            return try await generateOpenAI(model: model, auth: auth, prompt: prompt)
        case .gemini:
            return try await generateGemini(model: model, auth: auth, prompt: prompt)
        }
    }

    private static func generateOpenAI(
        model: Model,
        auth: ResolvedProviderAuth,
        prompt: String
    ) async throws -> AgentGeneratedImage {
        let endpoint = try endpoint(baseURL: model.baseURL, suffix: ["images", "generations"], prefix: "v1")
        let isGPTImage = model.id.lowercased().hasPrefix("gpt-image")
        let requestBody = OpenAIRequest(
            model: model.id,
            prompt: prompt,
            n: 1,
            // GPT Image always returns base64 and rejects response_format;
            // DALL-E and most compatible gateways need it explicitly.
            responseFormat: isGPTImage ? nil : "b64_json"
        )
        let body = try JSONEncoder().encode(requestBody)
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, body: data)
        let decoded: OpenAIResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        } catch {
            throw Failure.malformedResponse
        }
        guard let item = decoded.data.first else { throw Failure.malformedResponse }
        if let encoded = item.b64JSON, !encoded.isEmpty {
            return try image(fromBase64: encoded, preferredMIMEType: "image/png")
        }
        guard let imageURL = item.url else { throw Failure.malformedResponse }
        return try await downloadImage(from: imageURL)
    }

    private static func generateGemini(
        model: Model,
        auth: ResolvedProviderAuth,
        prompt: String
    ) async throws -> AgentGeneratedImage {
        let modelID = model.id.hasPrefix("models/") ? String(model.id.dropFirst("models/".count)) : model.id
        let endpoint = try endpoint(
            baseURL: model.baseURL,
            suffix: ["models", "\(modelID):generateContent"],
            prefix: "v1beta"
        )
        let requestBody: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            // Gemini's image-capable models only emit image inlineData when
            // IMAGE is explicitly requested in the response modalities.
            "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]],
        ]
        let body = try JSONSerialization.data(withJSONObject: requestBody)
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(auth.token, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, body: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inline = firstInlineImage(in: object),
              !inline.data.isEmpty
        else { throw Failure.malformedResponse }
        return try image(fromBase64: inline.data, preferredMIMEType: inline.mimeType)
    }

    static func endpoint(
        baseURL: String,
        suffix: [String],
        prefix: String? = nil
    ) throws -> URL {
        guard let base = URL(string: baseURL),
              let scheme = base.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw Failure.invalidEndpoint }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let alreadyHasPrefix = prefix.map { path == $0 || path.hasSuffix("/\($0)") } ?? false
        if let prefix, !alreadyHasPrefix {
            path = path.isEmpty ? prefix : "\(path)/\(prefix)"
        }
        path = ([path] + suffix).filter { !$0.isEmpty }.joined(separator: "/")
        components.path = "/" + path
        guard let url = components.url else { throw Failure.invalidEndpoint }
        return url
    }

    private static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
                .flatMap { errorObject in
                    (errorObject["error"] as? [String: Any])?["message"] as? String
                        ?? errorObject["message"] as? String
                }
                ?? String(decoding: body.prefix(500), as: UTF8.self)
            throw Failure.requestFailed(status: http.statusCode, message: message)
        }
    }

    private static func downloadImage(from string: String) async throws -> AgentGeneratedImage {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { throw Failure.invalidImage }
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, body: data)
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        return try image(from: data, preferredMIMEType: header)
    }

    static func image(fromBase64 encoded: String, preferredMIMEType: String?) throws -> AgentGeneratedImage {
        let payload: String
        if let comma = encoded.firstIndex(of: ","), encoded[..<comma].lowercased().hasPrefix("data:") {
            payload = String(encoded[encoded.index(after: comma)...])
        } else {
            payload = encoded
        }
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
            throw Failure.invalidImage
        }
        return try image(from: data, preferredMIMEType: preferredMIMEType)
    }

    private static func image(from data: Data, preferredMIMEType: String?) throws -> AgentGeneratedImage {
        guard !data.isEmpty else { throw Failure.invalidImage }
        guard data.count <= maximumImageBytes else { throw Failure.imageTooLarge }
        guard let mimeType = imageMIMEType(data: data, preferred: preferredMIMEType) else {
            throw Failure.invalidImage
        }
        return AgentGeneratedImage(data: data.base64EncodedString(), mimeType: mimeType)
    }

    private static func imageMIMEType(data: Data, preferred: String?) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12,
           bytes.starts(with: Array("RIFF".utf8)),
           Array(bytes[8 ..< 12]) == Array("WEBP".utf8) { return "image/webp" }
        if let preferred,
           let type = preferred.split(separator: ";", maxSplits: 1).first.map(String.init),
           type.lowercased().hasPrefix("image/")
        {
            return type
        }
        return nil
    }

    private static func firstInlineImage(in value: Any) -> (data: String, mimeType: String)? {
        if let dictionary = value as? [String: Any] {
            for key in ["inlineData", "inline_data"] {
                if let inline = dictionary[key] as? [String: Any],
                   let data = inline["data"] as? String
                {
                    let mime = (inline["mimeType"] as? String) ?? (inline["mime_type"] as? String)
                    return (data, mime ?? "image/png")
                }
            }
            for child in dictionary.values {
                if let found = firstInlineImage(in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstInlineImage(in: child) { return found }
            }
        }
        return nil
    }
}
