import Foundation

// MARK: - Provider kinds

enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openRouter
    case gemini
    case nineRouter
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic:        return "Anthropic"
        case .openRouter:       return "OpenRouter"
        case .gemini:           return "Gemini"
        case .nineRouter:       return "9Router"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    /// Short label that fits in the segmented picker.
    var pickerLabel: String {
        switch self {
        case .openAICompatible: return "OpenAI"
        default:                return displayName
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic:        return "claude-sonnet-4-6"
        case .openRouter:       return "anthropic/claude-sonnet-4"
        case .gemini:           return "gemini-2.5-flash"
        case .nineRouter:       return "kr/claude-sonnet-4.5"
        case .openAICompatible: return "gpt-4o-mini"
        }
    }

    /// Keychain key holding this provider's API key.
    var keychainKey: String {
        switch self {
        case .anthropic:        return "anthropic-api-key"
        case .openRouter:       return "openrouter-api-key"
        case .gemini:           return "gemini-api-key"
        case .nineRouter:       return "ninerouter-api-key"
        case .openAICompatible: return "openaicomp-api-key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic:        return "API key (sk-ant-...)"
        case .openRouter:       return "API key (sk-or-v1-...)"
        case .gemini:           return "API key (AIza...)"
        case .nineRouter:       return "API key (from 9Router dashboard)"
        case .openAICompatible: return "API key"
        }
    }

    /// Providers that talk to a configurable HTTP base URL.
    var needsBaseURL: Bool {
        switch self {
        case .nineRouter, .openAICompatible: return true
        default: return false
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .nineRouter: return "http://localhost:20128/v1"
        default:          return ""
        }
    }

}

// MARK: - Persisted settings (UserDefaults; secrets stay in the Keychain)

struct AIProviderSettings: Codable {
    var activeKindRaw: String = AIProviderKind.anthropic.rawValue
    var models: [String: String] = [:]   // kind rawValue -> model id
    var baseURLs: [String: String] = [:] // kind rawValue -> base URL (providers with needsBaseURL)
    var customBaseURL: String = ""       // legacy (openAICompatible); migrated into baseURLs on load
}

@MainActor
final class AIProviderStore {
    static let shared = AIProviderStore()

    private let defaultsKey = "coucou.ai-provider-settings"
    private var settings: AIProviderSettings

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AIProviderSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AIProviderSettings()
        }
        // Migrate legacy single customBaseURL into per-provider baseURLs.
        if !settings.customBaseURL.isEmpty
            && settings.baseURLs[AIProviderKind.openAICompatible.rawValue] == nil {
            settings.baseURLs[AIProviderKind.openAICompatible.rawValue] = settings.customBaseURL
            settings.customBaseURL = ""
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    var activeKind: AIProviderKind {
        get { AIProviderKind(rawValue: settings.activeKindRaw) ?? .anthropic }
        set { settings.activeKindRaw = newValue.rawValue; save() }
    }

    func model(for kind: AIProviderKind) -> String {
        let custom = settings.models[kind.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        return kind.defaultModel
    }

    func setModel(_ model: String, for kind: AIProviderKind) {
        settings.models[kind.rawValue] = model
        save()
    }

    /// Base URL for providers with `needsBaseURL`; falls back to the kind's default.
    func baseURL(for kind: AIProviderKind) -> String {
        let saved = settings.baseURLs[kind.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty { return saved }
        return kind.defaultBaseURL
    }

    func setBaseURL(_ url: String, for kind: AIProviderKind) {
        settings.baseURLs[kind.rawValue] = url
        save()
    }

    func apiKey(for kind: AIProviderKind) -> String? {
        KeychainStore.shared.get(kind.keychainKey)
    }
}

// MARK: - Normalized chat types

struct AIToolCall {
    let id: String
    let name: String
    /// Raw JSON string of the tool arguments.
    let argumentsJSON: String
}

enum AIProviderError: LocalizedError {
    case missingKey(String)
    case missingBaseURL
    case httpError(Int, String)
    case badResponse(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingKey(let name):   return "\(name) API key missing. Open settings."
        case .missingBaseURL:         return "Base URL missing. Open settings."
        case .httpError(let c, let m): return "HTTP \(c): \(m)"
        case .badResponse(let m):     return "Unexpected API response: \(m)"
        case .timeout:                return "Request timed out."
        }
    }
}

// MARK: - Provider client (@MainActor; two wire protocols)

/// Speaks either the Anthropic Messages API or the OpenAI Chat Completions API
/// (used directly and via OpenRouter). Tool calls are normalized so the rest
/// of the app never cares which provider answered.
@MainActor
final class AIProviderClient {
    static let shared = AIProviderClient()

    struct NormalizedResponse {
        let text: String
        let toolCalls: [AIToolCall]
        /// Provider-native assistant message, appended verbatim for multi-turn.
        let nativeAssistantMessage: [String: Any]
    }

    private let anthropicEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"
    private let openRouterBaseURL = "https://openrouter.ai/api/v1"
    /// Google's OpenAI-compatible endpoint (key goes in x-goog-api-key, not Bearer).
    private let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"

    /// - Parameters:
    ///   - messages: internal format. User/assistant content is an array of
    ///     Anthropic-style blocks. Tool results use
    ///     `["role": "tool", "tool_call_id": id, "content": text]`.
    ///   - tools: MCP tool definitions, converted to the provider's format.
    ///   - webSearch: Anthropic-only web search tool (ignored by other providers).
    func complete(messages: [[String: Any]],
                  system: String,
                  tools: [MCPToolDefinition],
                  maxTokens: Int,
                  webSearch: Bool = false) async throws -> NormalizedResponse {
        let store = AIProviderStore.shared
        let kind = store.activeKind
        guard let key = store.apiKey(for: kind), !key.isEmpty else {
            throw AIProviderError.missingKey(kind.displayName)
        }
        let model = store.model(for: kind)

        switch kind {
        case .anthropic:
            return try await anthropicComplete(key: key, model: model, messages: messages,
                                               system: system, tools: tools,
                                               maxTokens: maxTokens, webSearch: webSearch)
        case .openRouter:
            return try await chatCompletionsComplete(
                key: key, model: model, baseURL: openRouterBaseURL,
                authHeaders: ["Authorization": "Bearer \(key)"],
                messages: messages,
                system: system, tools: tools, maxTokens: maxTokens,
                extraHeaders: ["HTTP-Referer": "https://github.com/Louis-CFM/coucou",
                               "X-Title": "Coucou"])
        case .gemini:
            // Gemini's OpenAI-compatible endpoint: same wire format, key via x-goog-api-key.
            return try await chatCompletionsComplete(
                key: key, model: model, baseURL: geminiBaseURL,
                authHeaders: ["x-goog-api-key": key],
                messages: messages,
                system: system, tools: tools, maxTokens: maxTokens,
                extraHeaders: [:])
        case .nineRouter:
            // 9Router (decolua/9router): local OpenAI-compatible gateway, default http://localhost:20128/v1.
            let base = store.baseURL(for: .nineRouter)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { throw AIProviderError.missingBaseURL }
            return try await chatCompletionsComplete(
                key: key, model: model, baseURL: base,
                authHeaders: ["Authorization": "Bearer \(key)"],
                messages: messages,
                system: system, tools: tools, maxTokens: maxTokens,
                extraHeaders: [:])
        case .openAICompatible:
            let base = store.baseURL(for: .openAICompatible)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { throw AIProviderError.missingBaseURL }
            return try await chatCompletionsComplete(
                key: key, model: model, baseURL: base,
                authHeaders: ["Authorization": "Bearer \(key)"],
                messages: messages,
                system: system, tools: tools, maxTokens: maxTokens,
                extraHeaders: [:])
        }
    }

    // MARK: - Model listing & connection test

    /// Sorted model ids from the provider's `/models` endpoint.
    /// Backs the "Load models" and "Test connection" buttons in Settings.
    func listModels(kind: AIProviderKind) async throws -> [String] {
        let store = AIProviderStore.shared
        guard let key = store.apiKey(for: kind), !key.isEmpty else {
            throw AIProviderError.missingKey(kind.displayName)
        }

        let endpoint: URL
        var headers: [String: String] = [:]
        switch kind {
        case .anthropic:
            endpoint = URL(string: "https://api.anthropic.com/v1/models")!
            headers = ["x-api-key": key, "anthropic-version": anthropicVersion]
        case .openRouter:
            endpoint = URL(string: openRouterBaseURL + "/models")!
            headers = ["Authorization": "Bearer \(key)"]
        case .gemini:
            endpoint = URL(string: geminiBaseURL + "/models")!
            headers = ["x-goog-api-key": key]
        case .nineRouter, .openAICompatible:
            let base = store.baseURL(for: kind)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { throw AIProviderError.missingBaseURL }
            guard let url = URL(string: base + "/models") else {
                throw AIProviderError.badResponse("invalid base URL")
            }
            endpoint = url
            headers = ["Authorization": "Bearer \(key)"]
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw AIProviderError.httpError(http.statusCode, "\(kind.displayName): request rejected")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw AIProviderError.badResponse("unrecognized model list format")
        }
        return items.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: Anthropic Messages API

    private func anthropicComplete(key: String, model: String,
                                  messages: [[String: Any]], system: String,
                                  tools: [MCPToolDefinition], maxTokens: Int,
                                  webSearch: Bool) async throws -> NormalizedResponse {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map(convertToAnthropicMessage),
        ]
        var betaHeaders: [String] = []
        var apiTools: [[String: Any]] = tools.map { t in
            ["name": t.name, "description": t.description, "input_schema": t.inputSchema]
        }
        if webSearch {
            apiTools.append(["type": "web_search_20250305", "name": "web_search", "max_uses": 5])
            betaHeaders.append("web-search-2025-03-05")
        }
        if !apiTools.isEmpty { body["tools"] = apiTools }

        var request = URLRequest(url: anthropicEndpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !betaHeaders.isEmpty {
            request.setValue(betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90

        let data = try await perform(request: request, providerName: "Anthropic")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AIProviderError.badResponse("missing content blocks")
        }

        var textParts: [String] = []
        var toolCalls: [AIToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String, !t.isEmpty { textParts.append(t) }
            case "tool_use":
                if let id = block["id"] as? String, let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                    toolCalls.append(AIToolCall(id: id, name: name,
                                                argumentsJSON: String(data: argsData, encoding: .utf8) ?? "{}"))
                }
            default:
                break
            }
        }
        return NormalizedResponse(text: textParts.joined(separator: "\n"),
                                  toolCalls: toolCalls,
                                  nativeAssistantMessage: ["role": "assistant", "content": content])
    }

    /// Converts internal messages to Anthropic wire format.
    /// Internal tool results become `user` messages with `tool_result` blocks.
    private func convertToAnthropicMessage(_ message: [String: Any]) -> [String: Any] {
        guard (message["role"] as? String) == "tool",
              let toolID = message["tool_call_id"] as? String else {
            return message
        }
        let text = message["content"] as? String ?? ""
        return ["role": "user",
                "content": [["type": "tool_result", "tool_use_id": toolID, "content": text]]]
    }

    // MARK: OpenAI Chat Completions API (direct, OpenRouter, Ollama, Groq, ...)

    private func chatCompletionsComplete(key: String, model: String, baseURL: String,
                                         authHeaders: [String: String],
                                         messages: [[String: Any]], system: String,
                                         tools: [MCPToolDefinition], maxTokens: Int,
                                         extraHeaders: [String: String]) async throws -> NormalizedResponse {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            throw AIProviderError.badResponse("invalid base URL")
        }
        var wireMessages: [[String: Any]] = [["role": "system", "content": system]]
        wireMessages += messages.map(convertToOpenAIMessage)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": wireMessages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t -> [String: Any] in
                ["type": "function",
                 "function": ["name": t.name,
                              "description": t.description,
                              "parameters": t.inputSchema]]
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in authHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90

        let data = try await perform(request: request, providerName: "API")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any] else {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errDict = json["error"] as? [String: Any],
           let errMsg = errDict["message"] as? String {
            throw AIProviderError.badResponse(errMsg)
        }
        throw AIProviderError.badResponse("missing choices")
        }

        let text = (msg["content"] as? String) ?? ""
        var toolCalls: [AIToolCall] = []
        var rawToolCalls: [[String: Any]] = []
        if let tcList = msg["tool_calls"] as? [[String: Any]] {
            for tc in tcList {
                guard let id = tc["id"] as? String,
                      let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                rawToolCalls.append(tc)
                toolCalls.append(AIToolCall(id: id, name: name,
                                            argumentsJSON: (fn["arguments"] as? String) ?? "{}"))
            }
        }
        var native: [String: Any] = ["role": "assistant", "content": text]
        if !rawToolCalls.isEmpty { native["tool_calls"] = rawToolCalls }
        return NormalizedResponse(text: text, toolCalls: toolCalls, nativeAssistantMessage: native)
    }

    /// Converts internal messages to OpenAI wire format.
    private func convertToOpenAIMessage(_ message: [String: Any]) -> [String: Any] {
        let role = message["role"] as? String ?? "user"
        if role == "tool" {
            return ["role": "tool",
                    "tool_call_id": message["tool_call_id"] as? String ?? "",
                    "content": message["content"] as? String ?? ""]
        }
        if role == "assistant" {
            // Already native (from a previous NormalizedResponse).
            return message
        }
        // User message: content blocks -> OpenAI parts.
        var parts: [[String: Any]] = []
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                let type = block["type"] as? String ?? "text"
                switch type {
                case "text":
                    parts.append(["type": "text", "text": block["text"] as? String ?? ""])
                case "image":
                    if let src = block["source"] as? [String: Any],
                       let data = src["data"] as? String,
                       let media = src["media_type"] as? String {
                        parts.append(["type": "image_url",
                                      "image_url": ["url": "data:\(media);base64,\(data)"]])
                    }
                default:
                    parts.append(["type": "text",
                                  "text": "[Attachment of type '\(type)' is not supported by this provider and was omitted.]"])
                }
            }
        } else if let text = message["content"] as? String {
            parts.append(["type": "text", "text": text])
        }
        return ["role": "user", "content": parts]
    }

    // MARK: HTTP

    private func perform(request: URLRequest, providerName: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            var detail = "unknown error"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let err = json["error"] as? [String: Any], let m = err["message"] as? String {
                    detail = m
                } else if let err = json["error"] as? String {
                    detail = err
                }
            } else if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                detail = String(s.prefix(300))
            }
            throw AIProviderError.httpError(http.statusCode, detail)
        }
        return data
    }
}
