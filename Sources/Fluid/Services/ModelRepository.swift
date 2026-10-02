//
//  ModelRepository.swift
//  Fluid
//
//  Single source of truth for default model lists and base URLs per provider.
//  All views (AISettings, ContentView, CommandMode, RewriteMode) should use this
//  instead of maintaining their own hardcoded lists.
//

import Foundation

final class ModelRepository {
    static let shared = ModelRepository()

    private init() {}

    /// All built-in provider IDs (not including custom/saved providers)
    static var builtInProviderIDs: [String] {
        var providers = [
            "openai", "anthropic", "xai", "groq", "cerebras", "google", "openrouter", "ollama", "lmstudio",
            "mistral", "assemblyai",
        ]
        if PrivateFeatures.privateAIProvider {
            providers.insert(PrivateAIProviderFeature.shared.providerID, at: 0)
        }
        return providers
    }

    /// Returns the default models for a given provider ID.
    /// This is used when the user has not added any custom models for that provider.
    func defaultModels(for providerID: String) -> [String] {
        if PrivateFeatures.privateAIProvider, providerID == PrivateAIProviderFeature.shared.providerID {
            return PrivateAIProviderFeature.shared.modelIDs()
        }

        switch providerID {
        case "openai":
            return ["gpt-4.1"]
        case "anthropic":
            return ["claude-sonnet-4-20250514"]
        case "xai":
            return ["grok-3-fast"]
        case "groq":
            return ["openai/gpt-oss-120b"]
        case "cerebras":
            return ["gpt-oss-120b"]
        case "google":
            return ["gemini-2.5-flash"]
        case "openrouter":
            return ["openai/gpt-oss-20b"]
        case "ollama", "lmstudio":
            // Local providers - models vary per user, they must add their own
            return []
        case "mistral":
            return ["mistral-small-latest"]
        case "assemblyai":
            // Offered offline and before the first refresh; Refresh replaces it with the gateway's own list.
            return Self.assemblyAIGatewayModels
        default:
            // Custom providers start with no default models; user must add them
            return []
        }
    }

    /// Returns models eligible for one app mode. Remote providers keep their
    /// normal model list; Fluid Intelligence supplies task-scoped local models.
    func defaultModels(for providerID: String, task: PrivateAIModelTask) -> [String] {
        if PrivateFeatures.privateAIProvider, providerID == PrivateAIProviderFeature.shared.providerID {
            return PrivateAIProviderFeature.shared.modelIDs(for: task)
        }
        return self.defaultModels(for: providerID)
    }

    /// AssemblyAI LLM Gateway models offered before the first refresh, default first, then by vendor.
    /// EVIDENCE: https://www.assemblyai.com/docs/llm-gateway/available-models (checked 2026-10-02): every model in
    /// the documented table except those that need a provider switched on under Dashboard > Data Controls
    /// (DeepSeek V4.1 Flash, GLM-5.3, GLM-5.3 Flash, Kimi K3, Minimax M3, Nemotron Lightning 3.5,
    /// https://www.assemblyai.com/docs/llm-gateway/providers) and Gemini 3.1 Flash Lite, which retires on
    /// 2027-05-07. The docs name no default; `gpt-5-mini` stays the app's.
    static let assemblyAIGatewayModels = [
        "gpt-5-mini",
        "gpt-5-nano", "gpt-5", "gpt-5.1", "gpt-5.2", "gpt-5.5", "gpt-5.6-luna", "gpt-5.6-sol", "gpt-5.6-terra",
        "gpt-6-luna", "gpt-6-sol", "gpt-6-astra", "gpt-4.1", "gpt-oss-120b", "gpt-oss-20b",
        "claude-haiku-4-5-20251001", "claude-sonnet-4-5-20250929", "claude-sonnet-4-6", "claude-sonnet-5",
        "claude-opus-4-5-20251101", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5",
        "gemini-2.5-flash-lite", "gemini-2.5-flash", "gemini-2.5-pro", "gemini-3.5-flash-lite", "gemini-3.5-flash",
        "gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash", "gemma-4-31b",
        "qwen3.5-4b-32k-fast", "qwen3-32B", "qwen3-next-80b-a3b",
        "nemotron-nano-9b-v2", "nemotron-3-nano-30b-a3b", "nemotron-3-super-120b-a12b",
    ]

    /// Gateway providers that stay off until the user turns them on under Data Controls in the AssemblyAI
    /// dashboard. EVIDENCE: https://www.assemblyai.com/docs/llm-gateway/providers (checked 2026-10-02).
    static let assemblyAIOptInGatewayProviders: Set<String> = ["fireworks", "digital_ocean", "together", "together_ai"]

    /// The models a gateway `/v1/models` answer offers this app, default first: none whose `retirement_date`
    /// has passed, none outside the US or global region the app's endpoint serves, and none served only by an
    /// opt-in provider. Nil when the answer is not that list.
    /// EVIDENCE: https://www.assemblyai.com/docs/llm-gateway/api-reference/list-available-models (checked 2026-10-02):
    /// entries carry `id`, `retirement_date` (Unix seconds, 0 for none), `available_regions` and `providers[].id`.
    static func assemblyAIGatewayModelIDs(in json: [String: Any], now: Date = Date()) -> [String]? { // swiftlint:disable:this discouraged_optional_collection
        guard let entries = json["data"] as? [[String: Any]] else { return nil }
        let ids = entries.compactMap { entry -> String? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let retirement = (entry["retirement_date"] as? NSNumber)?.doubleValue ?? 0
            if retirement > 0, retirement <= now.timeIntervalSince1970 { return nil }
            if let regions = entry["available_regions"] as? [String], !regions.isEmpty, !regions.contains("us"), !regions.contains("global") {
                return nil
            }
            let providers = (entry["providers"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            if !providers.isEmpty, providers.allSatisfy(self.assemblyAIOptInGatewayProviders.contains) { return nil }
            return id
        }
        let defaultID = self.assemblyAIGatewayModels[0]
        return (ids.contains(defaultID) ? [defaultID] : []) + Set(ids).subtracting([defaultID]).sorted()
    }

    /// What an AssemblyAI refresh leaves in the list: the gateway's models, default first, then every ID the
    /// user added (any listed ID that is neither built in nor in the new answer), then the selected model if
    /// the gateway no longer lists it, so a refresh never drops the user's choice.
    static func assemblyAIRefreshedModels(fetched: [String], existing: [String], selected: String?) -> [String] {
        var models = fetched
        for id in existing where !models.contains(id) && !self.assemblyAIGatewayModels.contains(id) {
            models.append(id)
        }
        if let selected, !selected.isEmpty, !models.contains(selected) {
            models.append(selected)
        }
        return models
    }

    static func eligibleModel(preferred: String?, from models: [String]) -> String? {
        if let preferred, models.contains(preferred) {
            return preferred
        }
        return models.first
    }

    /// Returns the default base URL for a given provider ID.
    func defaultBaseURL(for providerID: String) -> String {
        switch providerID {
        case "openai":
            return "https://api.openai.com/v1"
        case "anthropic":
            return "https://api.anthropic.com/v1"
        case "xai":
            return "https://api.x.ai/v1"
        case "groq":
            return "https://api.groq.com/openai/v1"
        case "cerebras":
            return "https://api.cerebras.ai/v1"
        case "google":
            return "https://generativelanguage.googleapis.com/v1beta/openai"
        case "openrouter":
            return "https://openrouter.ai/api/v1"
        case "ollama":
            return "http://localhost:11434/v1"
        case "lmstudio":
            return "http://localhost:1234/v1"
        // EVIDENCE: https://docs.mistral.ai/api (checked 2026-10-02): OpenAI-style `POST /v1/chat/completions`
        // with `Authorization: Bearer <key>` and `GET /v1/models`.
        case "mistral":
            return "https://api.mistral.ai/v1"
        // EVIDENCE: https://www.assemblyai.com/docs/llm-gateway/api-reference/list-available-models (checked 2026-10-02):
        // the gateway answers `GET /v1/models` in the OpenAI `{"data": [{"id": ...}]}` shape without auth (since
        // 2026-09-09), so Refresh lists its models like any other provider's.
        // EVIDENCE: https://www.assemblyai.com/docs/llm-gateway/quickstart (checked 2026-10-02): the gateway is used
        // through the OpenAI SDK with this base URL and the AssemblyAI key as `api_key`, so it accepts
        // `Authorization: Bearer <key>` as well as the bare key its HTTP examples send.
        case "assemblyai":
            return "https://llm-gateway.assemblyai.com/v1"
        default:
            return ""
        }
    }

    /// Returns the display name for a provider ID
    func displayName(for providerID: String) -> String {
        if PrivateFeatures.privateAIProvider, providerID == PrivateAIProviderFeature.shared.providerID {
            return PrivateAIProviderFeature.shared.providerName
        }

        switch providerID {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "xai": return "xAI"
        case "groq": return "Groq"
        case "cerebras": return "Cerebras"
        case "google": return "Google"
        case "openrouter": return "OpenRouter"
        case "ollama": return "Ollama"
        case "lmstudio": return "LM Studio"
        case "mistral": return "Mistral"
        case "assemblyai": return "AssemblyAI"
        default: return providerID.capitalized
        }
    }

    /// Check if a provider ID is a built-in provider
    func isBuiltIn(_ providerID: String) -> Bool {
        Self.builtInProviderIDs.contains(providerID)
    }

    /// Returns the website URL for getting an API key or downloading the provider software.
    /// Returns nil for providers that don't have a relevant URL.
    func providerWebsiteURL(for providerID: String) -> (url: String, label: String)? {
        Self.providerWebsiteURL(for: providerID)
    }

    /// Pure lookup, also read by `ProviderRegistry` outside the main actor.
    nonisolated static func providerWebsiteURL(for providerID: String) -> (url: String, label: String)? {
        switch providerID {
        case "openai":
            return ("https://platform.openai.com/api-keys", "Get API Key")
        case "anthropic":
            return ("https://platform.claude.com/settings/keys", "Get API Key")
        case "xai":
            return ("https://console.x.ai/", "Get API Key")
        case "groq":
            return ("https://console.groq.com/keys", "Get API Key")
        case "cerebras":
            return ("https://cloud.cerebras.ai/platform", "Get API Key")
        case "google":
            return ("https://aistudio.google.com/apikey", "Get API Key")
        case "openrouter":
            return ("https://openrouter.ai/settings/keys", "Get API Key")
        case "ollama":
            return ("https://docs.ollama.com/api/openai-compatibility", "Setup Guide")
        case "lmstudio":
            return ("https://lmstudio.ai/docs/local-server", "Setup Guide")
        case "mistral":
            // The key pages come from the live catalog, which already links them.
            return LiveTranscriptionCatalog.info(for: .mistral).keyURL.map { (url: $0.absoluteString, label: "Get API Key") }
        case "assemblyai":
            return LiveTranscriptionCatalog.info(for: .assemblyAI).keyURL.map { (url: $0.absoluteString, label: "Get API Key") }
        default:
            return nil
        }
    }

    /// Check if a URL represents a local endpoint (localhost, local IP)
    func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host else { return false }
        let hostLower = host.lowercased()
        if hostLower == "localhost" || hostLower == "127.0.0.1" { return true }
        if hostLower.hasPrefix("127.") || hostLower.hasPrefix("10.") || hostLower.hasPrefix("192.168.") { return true }
        if hostLower.hasPrefix("172.") {
            let components = hostLower.split(separator: ".")
            if components.count >= 2, let secondOctet = Int(components[1]), secondOctet >= 16 && secondOctet <= 31 {
                return true
            }
        }
        return false
    }

    /// Returns the list of built-in providers for UI pickers
    func builtInProvidersList() -> [(id: String, name: String)] {
        var list: [(id: String, name: String)] = [
            ("openai", "OpenAI"),
            ("anthropic", "Anthropic"),
            ("xai", "xAI"),
            ("groq", "Groq"),
            ("cerebras", "Cerebras"),
            ("google", "Google"),
            ("openrouter", "OpenRouter"),
            ("ollama", "Ollama"),
            ("lmstudio", "LM Studio"),
            ("mistral", "Mistral"),
            ("assemblyai", "AssemblyAI"),
        ]

        if PrivateFeatures.privateAIProvider {
            list.insert((PrivateAIProviderFeature.shared.providerID, PrivateAIProviderFeature.shared.providerName), at: 0)
        }

        return list
    }

    /// Converts a provider ID to a storage key for UserDefaults and the Keychain.
    /// Registry and built-in providers use their ID directly; custom providers get the custom prefix.
    func providerKey(for providerID: String) -> String {
        ProviderRegistry.providerKey(for: providerID, isBuiltIn: self.isBuiltIn)
    }

    /// The storage key for a key read back from a stored model dictionary. Known IDs are matched
    /// case-insensitively, as the dictionaries have always been normalised.
    func normalizedStoredProviderKey(_ storedKey: String) -> String {
        let lowercased = self.providerKey(for: storedKey.lowercased())
        return ProviderRegistry.isCustomProviderKey(lowercased) ? self.providerKey(for: storedKey) : lowercased
    }

    /// Returns all possible keys for a provider (for looking up stored settings)
    func providerKeys(for providerID: String) -> [String] {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return [providerID]
        }

        let key = self.providerKey(for: trimmed)
        // Registry and built-in providers: just use the ID
        guard ProviderRegistry.isCustomProviderKey(key) else { return [key] }

        // Custom providers: try both with and without prefix
        return Array(Set([key, ProviderRegistry.savedProviderID(fromProviderKey: key)]))
    }

    // MARK: - Fetch Models from API

    /// Fetches available models from the provider's API
    /// - Parameters:
    ///   - providerID: The provider identifier
    ///   - baseURL: The base URL for the API (e.g., "https://api.openai.com/v1")
    ///   - apiKey: Optional API key for authentication
    /// - Returns: Array of model IDs sorted alphabetically
    func fetchModels(for providerID: String, baseURL: String, apiKey: String?) async throws -> [String] {
        if PrivateFeatures.privateAIProvider, providerID == PrivateAIProviderFeature.shared.providerID {
            return PrivateAIProviderFeature.shared.modelIDs()
        }

        let isAnthropic = providerID == "anthropic" || baseURL.contains("anthropic.com")

        // Construct the models endpoint URL
        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)models" : "\(baseURL)/models"
        guard let url = URL(string: urlString) else {
            DebugLogger.shared.error(
                "fetchModels: Invalid URL constructed from baseURL='\(baseURL)' -> '\(urlString)'",
                source: "ModelRepository"
            )
            throw FetchError.invalidURL(details: "Could not construct valid URL from base: \(baseURL)")
        }

        DebugLogger.shared.debug(
            "fetchModels: Fetching models for '\(providerID)' from \(urlString) (isAnthropic=\(isAnthropic))",
            source: "ModelRepository"
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        // Add authentication headers (different for Anthropic)
        if let key = apiKey, !key.isEmpty {
            if isAnthropic {
                // Anthropic uses x-api-key header and requires anthropic-version
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let errorDetails = self.detailedNetworkError(error)
            DebugLogger.shared.error(
                "fetchModels: Network error for '\(providerID)': \(errorDetails)",
                source: "ModelRepository"
            )
            throw FetchError.networkError(details: errorDetails)
        }

        // Check for HTTP errors and preserve the provider body for the UI.
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let bodyString = String(data: data, encoding: .utf8) ?? "<unable to decode response body>"
            let errorDetails = self.rawHTTPErrorDetails(responseBody: bodyString)
            DebugLogger.shared.error(
                "fetchModels: HTTP \(httpResponse.statusCode) for '\(providerID)': \(errorDetails)\nResponse body: \(bodyString.prefix(500))",
                source: "ModelRepository"
            )
            throw FetchError.httpError(statusCode: httpResponse.statusCode, details: errorDetails)
        }

        // Parse the response - OpenAI format: { "data": [{ "id": "model-name" }, ...] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary data>"
            DebugLogger.shared.error(
                "fetchModels: Failed to parse JSON for '\(providerID)'. Response preview: \(bodyPreview)",
                source: "ModelRepository"
            )
            throw FetchError.invalidResponse(details: "Response is not valid JSON. Check if the base URL '\(baseURL)' is correct.")
        }

        if providerID == "assemblyai", let models = Self.assemblyAIGatewayModelIDs(in: json) {
            DebugLogger.shared.debug("fetchModels: Found \(models.count) usable AssemblyAI gateway models", source: "ModelRepository")
            return models
        }

        // Try OpenAI/Groq/Cerebras format first
        if let dataArray = json["data"] as? [[String: Any]] {
            let models = dataArray.compactMap { $0["id"] as? String }
            DebugLogger.shared.debug(
                "fetchModels: Found \(models.count) models for '\(providerID)' (OpenAI format)",
                source: "ModelRepository"
            )
            return models.sorted()
        }

        // Try Google format: { "models": [{ "name": "models/gemini-pro" }, ...] }
        if let modelsArray = json["models"] as? [[String: Any]] {
            let models = modelsArray.compactMap { dict -> String? in
                if let name = dict["name"] as? String {
                    // Google returns "models/gemini-pro", extract just the model name
                    return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                }
                return nil
            }
            DebugLogger.shared.debug(
                "fetchModels: Found \(models.count) models for '\(providerID)' (Google format)",
                source: "ModelRepository"
            )
            return models.sorted()
        }

        // Log what we actually received
        let topLevelKeys = json.keys.joined(separator: ", ")
        DebugLogger.shared.error(
            "fetchModels: Unknown response format for '\(providerID)'. Top-level keys: [\(topLevelKeys)]. Expected 'data' or 'models' array.",
            source: "ModelRepository"
        )
        throw FetchError.invalidResponse(details: "Unknown response format. Top-level keys: [\(topLevelKeys)]. Expected 'data' or 'models'.")
    }

    private func rawHTTPErrorDetails(responseBody: String) -> String {
        let trimmed = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "<empty response body>" : trimmed
    }

    /// Provides detailed network error messages
    private func detailedNetworkError(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut:
            return "Connection timed out - The server didn't respond in time. Check if the base URL is correct and the service is running."
        case NSURLErrorCannotConnectToHost:
            return "Cannot connect to host - Check if the base URL is correct. For local providers (Ollama, LM Studio), ensure the server is running."
        case NSURLErrorNetworkConnectionLost:
            return "Network connection lost - Check your internet connection."
        case NSURLErrorNotConnectedToInternet:
            return "No internet connection - Check your network settings."
        case NSURLErrorSecureConnectionFailed:
            return "SSL/TLS error - The server's security certificate may be invalid or expired."
        case NSURLErrorCannotFindHost:
            return "Cannot find host - The domain name doesn't exist. Check if the base URL is spelled correctly."
        default:
            return "\(error.localizedDescription) (Error code: \(nsError.code))"
        }
    }

    enum FetchError: LocalizedError {
        case invalidURL(details: String)
        case httpError(statusCode: Int, details: String)
        case invalidResponse(details: String)
        case networkError(details: String)

        var errorDescription: String? {
            switch self {
            case let .invalidURL(details):
                return "Invalid API URL: \(details)"
            case let .httpError(code, details):
                return "API error (HTTP \(code)): \(details)"
            case let .invalidResponse(details):
                return "Invalid response: \(details)"
            case let .networkError(details):
                return "Network error: \(details)"
            }
        }
    }
}
