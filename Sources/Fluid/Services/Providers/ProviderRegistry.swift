import Foundation

/// What a provider can do in FluidVoice. A capability is listed only once the code serving it has shipped.
nonisolated enum ProviderCapability: String, CaseIterable, Sendable {
    case text
    case cloudTranscription
    case liveTranscription
}

/// One record per vendor the user connects with a key or a local server address.
nonisolated struct ProviderDescriptor: Identifiable, Sendable {
    /// The AI Providers ID and the Keychain entry name, lowercase.
    let id: String
    let name: String
    let capabilities: Set<ProviderCapability>
    let requiresAPIKey: Bool
    let keyURL: URL?
    let usageURL: URL?
}

/// Every provider FluidVoice knows by ID. Custom providers (`custom:<id>`) are not listed; they have Text only.
nonisolated enum ProviderRegistry {
    /// Prefix of the dictionary key for a provider the registry and the built-in list do not know.
    static let customProviderKeyPrefix = "custom:"

    static let all: [ProviderDescriptor] = [
        Self.textProvider("openai", name: "OpenAI", live: .openAI),
        Self.textProvider("anthropic", name: "Anthropic"),
        Self.textProvider("xai", name: "xAI"),
        Self.textProvider("groq", name: "Groq"),
        Self.textProvider("cerebras", name: "Cerebras"),
        Self.textProvider("google", name: "Google"),
        Self.textProvider("openrouter", name: "OpenRouter", cloudTranscription: true, usageURL: URL(string: "https://openrouter.ai/activity")),
        Self.textProvider("ollama", name: "Ollama", requiresAPIKey: false),
        Self.textProvider("lmstudio", name: "LM Studio", requiresAPIKey: false),
        // A vendor gains Cloud transcription once its client ships (CLD-3); Mistral and AssemblyAI gain
        // Text with their text clients (CLD-7, CLD-8).
        Self.liveProvider(.mistral, cloudTranscription: true),
        Self.liveProvider(.assemblyAI),
        Self.liveProvider(.soniox),
        Self.liveProvider(.deepgram, cloudTranscription: true),
        Self.liveProvider(.elevenLabs, cloudTranscription: true),
        Self.liveProvider(.speechmatics),
        Self.liveProvider(.gladia),
    ]

    static func descriptor(for id: String) -> ProviderDescriptor? {
        self.all.first { $0.id == id }
    }

    static func providers(with capability: ProviderCapability) -> [ProviderDescriptor] {
        self.all.filter { $0.capabilities.contains(capability) }
    }

    /// The registry ID of a live vendor. Stored `LiveTranscriptionProviderID` raw values never change.
    static func providerID(for live: LiveTranscriptionProviderID) -> String {
        switch live {
        case .openAI: "openai"
        case .assemblyAI: "assemblyai"
        case .elevenLabs: "elevenlabs"
        case .soniox: "soniox"
        case .deepgram: "deepgram"
        case .mistral: "mistral"
        case .speechmatics: "speechmatics"
        case .gladia: "gladia"
        }
    }

    static func liveProviderID(for providerID: String) -> LiveTranscriptionProviderID? {
        LiveTranscriptionProviderID.allCases.first { self.providerID(for: $0) == providerID }
    }

    /// The dictionary key for stored keys, models and verification records. Registry and built-in IDs
    /// are used unchanged; any other ID is a custom provider and gets the custom prefix once. Every
    /// provider-key implementation and model-dictionary normaliser goes through this function.
    static func providerKey(for providerID: String, isBuiltIn: (String) -> Bool = { _ in false }) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if self.descriptor(for: trimmed) != nil || isBuiltIn(trimmed) || self.isCustomProviderKey(trimmed) {
            return trimmed
        }
        return self.customProviderKeyPrefix + trimmed
    }

    static func isCustomProviderKey(_ key: String) -> Bool {
        key.hasPrefix(self.customProviderKeyPrefix)
    }

    /// The saved provider's own ID for a custom provider key; any other value is returned unchanged.
    static func savedProviderID(fromProviderKey key: String) -> String {
        self.isCustomProviderKey(key) ? String(key.dropFirst(self.customProviderKeyPrefix.count)) : key
    }

    private static func textProvider(
        _ id: String,
        name: String,
        requiresAPIKey: Bool = true,
        cloudTranscription: Bool = false,
        live: LiveTranscriptionProviderID? = nil,
        usageURL: URL? = nil
    ) -> ProviderDescriptor {
        var capabilities: Set<ProviderCapability> = [.text]
        if cloudTranscription { capabilities.insert(.cloudTranscription) }
        if live != nil { capabilities.insert(.liveTranscription) }
        let website = ModelRepository.providerWebsiteURL(for: id)
        let liveInfo = live.map(LiveTranscriptionCatalog.info(for:))
        return ProviderDescriptor(
            id: id,
            name: name,
            capabilities: capabilities,
            requiresAPIKey: requiresAPIKey,
            keyURL: website.flatMap { URL(string: $0.url) } ?? liveInfo?.keyURL,
            usageURL: usageURL ?? liveInfo?.usageURL
        )
    }

    private static func liveProvider(_ live: LiveTranscriptionProviderID, cloudTranscription: Bool = false) -> ProviderDescriptor {
        let info = LiveTranscriptionCatalog.info(for: live)
        var capabilities: Set<ProviderCapability> = [.liveTranscription]
        if cloudTranscription { capabilities.insert(.cloudTranscription) }
        return ProviderDescriptor(
            id: self.providerID(for: live),
            name: info.name,
            capabilities: capabilities,
            requiresAPIKey: true,
            keyURL: info.keyURL,
            usageURL: info.usageURL
        )
    }
}
