import Foundation

/// What a recording freezes when Cloud is the engine (CLD-6): the configuration, the speech key of that
/// configuration's own provider and that provider's client. Retry rebuilds one from the frozen
/// configuration, so it reaches the same provider with that provider's current key.
nonisolated struct CloudTranscriptionSession: Sendable {
    let configuration: CloudTranscriptionConfiguration
    let apiKey: String
    let client: any CloudTranscriptionClient

    /// - Parameters:
    ///   - speechAPIKey: reads the speech key of a provider ID (`SettingsStore.speechAPIKey(for:)`).
    ///   - clients: the client of a provider ID; tests inject stubbed ones.
    init(
        configuration: CloudTranscriptionConfiguration,
        speechAPIKey: (String) -> String,
        clients: (String) -> any CloudTranscriptionClient = CloudTranscriptionClients.make
    ) {
        self.configuration = configuration
        self.apiKey = speechAPIKey(configuration.providerID)
        self.client = clients(configuration.providerID)
    }

    private init(configuration: CloudTranscriptionConfiguration, apiKey: String, client: any CloudTranscriptionClient) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.client = client
    }

    /// The same provider, key and client with changed request settings, such as a new language or the
    /// style instructions added at stop.
    func with(configuration: CloudTranscriptionConfiguration) -> CloudTranscriptionSession {
        CloudTranscriptionSession(configuration: configuration, apiKey: self.apiKey, client: self.client)
    }

    var providerID: String { self.configuration.providerID }
    var isOpenRouter: Bool { self.providerID == CloudTranscriptionCatalog.openRouterID }

    /// OpenRouter's transcript is used as it arrives (its style model already applied any Cleanup Style).
    /// Every other provider's transcript gets the local text processing Local and Live cloud output get
    /// (CLD-5).
    var appliesLocalTextProcessing: Bool { !self.isOpenRouter }

    @MainActor
    func provider(cacheDirectory: URL? = nil, persistChunks: Bool) -> CloudTranscriptionProvider {
        CloudTranscriptionProvider(
            configuration: self.configuration,
            apiKey: self.apiKey,
            cacheDirectory: cacheDirectory,
            persistChunks: persistChunks,
            client: self.client
        )
    }

    /// Opens OpenRouter's connection while the user is still speaking. Any other provider is left
    /// alone: the prewarm request goes to openrouter.ai and must never carry another vendor's key (KEY-8).
    func prewarm() async {
        guard self.isOpenRouter, let openRouter = self.client as? OpenRouterTranscriptionClient else { return }
        await openRouter.prewarmIfIdle(apiKey: self.apiKey)
    }
}
