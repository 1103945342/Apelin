import Foundation
import UIKit

/// Whose model a name is, for the mark the composer draws beside the draft.
///
/// A relay serves names of its own — `cn:deepseek-v4.1-flash`, `claude-opus-5`,
/// `gpt-6-astra` — and one generic "compatible" mark for every one of them says
/// nothing about what will answer. The name's words are compared with the
/// families Apelin draws, so the row shows the model's own mark where the
/// bundle has one, and the provider's where it does not.
///
/// The art is the official mark of each family, from Simple Icons
/// (https://simpleicons.org, CC0 for the artwork; the marks are their owners')
/// and drawn in the brand's own colour, as the provider marks in `Provider*`
/// are: `deepseek`, `anthropic`, `openai` and `google` reuse the drawings
/// already in the bundle.
enum ModelBrand: String, CaseIterable {
    case deepSeek
    case claude
    case openAI
    case gemini
    case grok
    case kimi
    case glm
    case qwen
    case mistral
    case llama
    case ernie
    case doubao
    case miniMax
    case nova
    case phi
    case granite
    case perplexity
    case nvidia

    /// The words that name a family. A word matches when it is the keyword, or
    /// begins with it once the keyword is long enough to be no accident
    /// (`deepseek-v4.1-flash`, `claude-sonnet-5`, `gpt-6-astra`).
    private var keywords: [String] {
        switch self {
        case .deepSeek: ["deepseek"]
        case .claude: ["claude", "sonnet", "opus", "haiku", "anthropic"]
        case .openAI: ["gpt", "chatgpt", "openai", "o1", "o3", "o4", "codex", "davinci"]
        case .gemini: ["gemini", "gemma", "palm"]
        case .grok: ["grok", "xai"]
        case .kimi: ["kimi", "moonshot"]
        case .glm: ["glm", "chatglm", "zhipu", "bigmodel", "zai"]
        case .qwen: ["qwen", "qwq", "tongyi"]
        case .mistral: ["mistral", "mixtral", "codestral", "devstral", "magistral", "pixtral"]
        case .llama: ["llama", "meta"]
        case .ernie: ["ernie", "wenxin"]
        case .doubao: ["doubao", "bytedance", "volcengine"]
        case .miniMax: ["minimax", "abab"]
        case .nova: ["nova"]
        case .phi: ["phi"]
        case .granite: ["granite"]
        case .perplexity: ["perplexity", "sonar"]
        case .nvidia: ["nemotron", "nvidia"]
        }
    }

    /// The imageset this family is drawn from.
    var iconName: String {
        switch self {
        case .deepSeek: "ProviderDeepSeek"
        case .claude: "ProviderClaude"
        case .openAI: "ProviderOpenAIAPI"
        case .gemini: "ProviderGoogleAI"
        case .grok: "ProviderGrok"
        case .kimi: "ProviderKimi"
        case .glm: "ProviderZai"
        case .qwen: "ProviderQwen"
        case .mistral: "ProviderMistral"
        case .llama: "ProviderLlama"
        case .ernie: "ProviderErnie"
        case .doubao: "ProviderDoubao"
        case .miniMax: "ProviderMiniMax"
        case .nova: "ProviderNova"
        case .phi: "ProviderPhi"
        case .granite: "ProviderGranite"
        case .perplexity: "ProviderPerplexity"
        case .nvidia: "ProviderNvidia"
        }
    }

    /// The mark in the colours it was drawn with: a mark read as a template
    /// would be one flat silhouette, and a black one in light mode.
    var icon: UIImage? {
        UIImage(named: iconName)?.withRenderingMode(.alwaysOriginal)
    }

    /// The family `model` names, nil when its words name none Apelin draws.
    static func brand(for model: String) -> ModelBrand? {
        let words = model.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return nil }
        for brand in allCases {
            for keyword in brand.keywords {
                let named = words.contains { word in
                    word == keyword || (keyword.count >= 4 && word.hasPrefix(keyword))
                }
                if named { return brand }
            }
        }
        return nil
    }
}
