import ApelinProtocol
import Foundation
import KWWKAI

/// Which model a session talks to. Credentials are not part of this value:
/// they come from the session's `CredentialSource`, by kwwk store id.
public enum ProviderConfiguration: Sendable, Hashable, Codable {
    /// Anthropic's native Messages API with an API key
    /// (`anthropic-api-key`), or with an Anthropic OAuth sign-in
    /// (`anthropic`) when `oauth` is set.
    case anthropic(model: String, oauth: Bool = false)
    /// Any OpenAI-compatible Chat Completions endpoint. The base URL lives
    /// with the credential (kwwk's `baseUrl` extra) so an endpoint and its
    /// key cannot be mismatched.
    case openAICompatible(model: String)
    /// GitHub Copilot, through kwwk's Copilot provider: kwwk exchanges the
    /// stored GitHub token for a Copilot session token and routes each model
    /// to its wire format.
    case githubCopilot(model: String)
    /// Any other login kwwk stores, by its store id (`openai-codex`,
    /// `kimi-coding`, `google-api-key`, …), registered by kwwk's own
    /// `registerStored`, or Apelin's DeepSeek registration. A nil model is
    /// the provider's own default.
    case stored(storeID: String, model: String?)
    /// A model already registered on kwwk's `APIRegistry` (tests and
    /// in-process fakes). Needs no credential.
    case registered(Model)

    var storeID: String? {
        switch self {
        case let .anthropic(_, oauth):
            oauth ? CredentialProviderID.anthropicOAuth : CredentialProviderID.anthropicAPIKey
        case .openAICompatible: CredentialProviderID.openAICompatible
        case .githubCopilot: CredentialProviderID.githubCopilot
        case let .stored(storeID, _): storeID
        case .registered: nil
        }
    }

    /// Converts the protocol's provider choice for an auxiliary operation.
    /// Auxiliary defaults always carry a concrete model identifier.
    public static func auxiliary(provider: AgentProvider, model: String) -> Self {
        switch provider {
        case .githubCopilot: .githubCopilot(model: model)
        case .anthropic: .anthropic(model: model, oauth: false)
        case .anthropicOAuth: .anthropic(model: model, oauth: true)
        case .openAICompatible: .openAICompatible(model: model)
        case .openAICodex: .stored(storeID: "openai-codex", model: model)
        case .cursor: .stored(storeID: "cursor", model: model)
        case .devin: .stored(storeID: "devin", model: model)
        case .kiro: .stored(storeID: "kiro", model: model)
        case .antigravity: .stored(storeID: "antigravity", model: model)
        case .qoder: .stored(storeID: "qoder", model: model)
        case .qoderCN: .stored(storeID: "qoder-cn", model: model)
        case .workBuddy: .stored(storeID: "workbuddy", model: model)
        case .workBuddyAI: .stored(storeID: "workbuddy-ai", model: model)
        case .kimiCoding: .stored(storeID: "kimi-coding", model: model)
        case .kimiCodingGlobal: .stored(storeID: "kimi-coding-ai", model: model)
        case .xai: .stored(storeID: "xai", model: model)
        case .zai: .stored(storeID: "zai", model: model)
        case .zaiCodingCN: .stored(storeID: "zai-coding-cn", model: model)
        case .openRouter: .stored(storeID: "openrouter", model: model)
        case .openAI: .stored(storeID: "openai-api-key", model: model)
        case .google: .stored(storeID: "google-api-key", model: model)
        case .deepSeek: .stored(storeID: "deepseek-api-key", model: model)
        case .openCodeGo: .stored(storeID: "opencode-go", model: model)
        case .openCodeZen: .stored(storeID: "opencode", model: model)
        }
    }

    var modelID: String? {
        switch self {
        case let .anthropic(model, _), let .openAICompatible(model), let .githubCopilot(model): model
        case let .stored(_, model): model
        case let .registered(model): model.id
        }
    }
}

public enum ProviderResolutionError: Error, Equatable, LocalizedError {
    /// No credential for this provider; the session waits for the app to
    /// deliver or sign in again. Nothing is read from the environment.
    case missingCredentials(String)

    public var errorDescription: String? {
        switch self {
        case let .missingCredentials(id): "No saved sign-in for \(id). Sign in again in Apelin."
        }
    }
}

public struct ResolvedProvider: Sendable {
    public var model: Model
    public var authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    /// The stored sign-in it was resolved from; nil for one that needs none.
    public var credentials: OAuthCredentials?

    public init(
        model: Model,
        authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?,
        credentials: OAuthCredentials? = nil,
    ) {
        self.model = model
        self.authResolver = authResolver
        self.credentials = credentials
    }
}

public enum ProviderResolver {
    /// What the app's model settings override on the model's own record. A
    /// figure that is not positive leaves the record's alone; a switch that is
    /// absent leaves what the catalogs read; `followsCatalog` is decided when
    /// the provider is registered (`ModelResolver.resolving`), before this.
    public static func applying(_ parameters: AgentModelParameters, to model: Model) -> Model {
        var model = model
        if let window = parameters.contextWindow, window > 0 {
            model.contextWindow = window
        }
        if let tokens = parameters.maxTokens, tokens > 0 {
            model.maxTokens = tokens
        }
        if let acceptsImages = parameters.acceptsImages {
            model.input = acceptsImages ? [.text, .image] : [.text]
        }
        if let reasoning = parameters.reasoning {
            model.reasoning = reasoning
        }
        return model
    }

    /// Registers the provider on kwwk's registry from `credentials`, with
    /// the same model capabilities used when verifying the account.
    public static func resolve(
        _ configuration: ProviderConfiguration,
        credentials: any CredentialSource,
        modelParameters: AgentModelParameters? = nil,
        diagnostic: @Sendable (String) -> Void = { _ in },
    ) async throws -> ResolvedProvider {
        let reading = Date()
        let stored = try await storedCredentials(configuration, in: credentials)
        diagnostic("provider credentials read in \(elapsed(since: reading))")
        guard let storeID = configuration.storeID else {
            if case let .registered(model) = configuration {
                return ResolvedProvider(model: model, authResolver: nil)
            }
            preconditionFailure("unreachable")
        }
        // OAuthManager(source:) keeps refreshed tokens in its own memory and
        // never writes them anywhere. Only this account's refresher is made;
        // API keys need none, and Kimi's identity never reaches for ~/.kwwk.
        let preparing = Date()
        let manager = OAuthManager(source: credentials, providers: KimiIdentity.refreshers(for: storeID))
        diagnostic("provider refreshers prepared in \(elapsed(since: preparing))")
        let registering = Date()
        guard let resolved = try await ProviderRegistration.resolve(
            storeID: storeID,
            manager: manager,
            modelOverride: configuration.modelID,
            parameters: modelParameters,
        ) else {
            throw ProviderResolutionError.missingCredentials(storeID)
        }
        diagnostic("provider registered in \(elapsed(since: registering))")
        return ResolvedProvider(model: resolved.model, authResolver: resolved.authResolver, credentials: stored)
    }

    private static func elapsed(since start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start) * 1000)) ms"
    }

    /// The stored sign-in `configuration` needs, nil for one that needs
    /// none; missing, it is an error.
    static func storedCredentials(
        _ configuration: ProviderConfiguration,
        in credentials: any CredentialSource,
    ) async throws -> OAuthCredentials? {
        guard let storeID = configuration.storeID else { return nil }
        guard let stored = try await credentials.credentials(for: storeID) else {
            throw ProviderResolutionError.missingCredentials(storeID)
        }
        return stored
    }
}
