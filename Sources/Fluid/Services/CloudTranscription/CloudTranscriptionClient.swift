import Foundation

/// One Cloud transcription vendor: it uploads a finished recording and returns its transcript (CLD-1).
/// Clients build their own requests and never reference the live adapters, so this directory keeps
/// compiling in the Swift 6 cloud harness.
nonisolated protocol CloudTranscriptionClient: Sendable {
    /// The registry ID, which is also the Keychain entry the key comes from.
    var providerID: String { get }
    var providerName: String { get }
    /// The longest piece of audio sent in one request. Longer recordings are chunked.
    var maximumRequestSeconds: Int { get }
    /// A request without audio that succeeds only for a key the vendor accepts.
    func checkKey(apiKey: String) async throws
    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult
}

/// The client for each Cloud transcription provider.
nonisolated enum CloudTranscriptionClients {
    /// Every provider that has a client, OpenRouter first.
    static let providerIDs: [String] = [
        CloudTranscriptionCatalog.openRouterID,
        DeepgramTranscriptionClient.id,
        ElevenLabsTranscriptionClient.id,
        MistralTranscriptionClient.id,
        SpeechmaticsTranscriptionClient.id,
        SonioxTranscriptionClient.id,
        AssemblyAITranscriptionClient.id,
        GladiaTranscriptionClient.id,
    ]

    /// The shared client of a provider, or nil when no client serves that ID.
    static func client(for providerID: String) -> (any CloudTranscriptionClient)? {
        switch providerID {
        case CloudTranscriptionCatalog.openRouterID: OpenRouterTranscriptionClient.shared
        case DeepgramTranscriptionClient.id: DeepgramTranscriptionClient.shared
        case ElevenLabsTranscriptionClient.id: ElevenLabsTranscriptionClient.shared
        case MistralTranscriptionClient.id: MistralTranscriptionClient.shared
        case SpeechmaticsTranscriptionClient.id: SpeechmaticsTranscriptionClient.shared
        case SonioxTranscriptionClient.id: SonioxTranscriptionClient.shared
        case AssemblyAITranscriptionClient.id: AssemblyAITranscriptionClient.shared
        case GladiaTranscriptionClient.id: GladiaTranscriptionClient.shared
        default: nil
        }
    }

    /// The client of a provider. An unknown ID gets a client that refuses every request, so a stale
    /// stored provider can never send audio or a key to another vendor (KEY-8).
    static func make(_ providerID: String) -> any CloudTranscriptionClient {
        self.client(for: providerID) ?? UnavailableCloudTranscriptionClient(providerID: providerID)
    }

    static func providerName(for providerID: String) -> String {
        self.make(providerID).providerName
    }

    /// The provider string history and analytics record: `openrouter` as before, `cloud-<id>` for the
    /// others, mirroring `live-<raw>` for Live cloud.
    static func historyProviderName(for providerID: String) -> String {
        providerID == CloudTranscriptionCatalog.openRouterID ? providerID : "cloud-\(providerID)"
    }
}

/// Stands in for a provider ID that has no client. Nothing is ever sent.
nonisolated struct UnavailableCloudTranscriptionClient: CloudTranscriptionClient {
    let providerID: String
    var providerName: String { self.providerID }
    var maximumRequestSeconds: Int { CloudAudioChunker.maximumSamples / CloudAudioChunker.sampleRate }

    func checkKey(apiKey: String) async throws { throw CloudTranscriptionError.unsupportedModel }

    func transcribe(samples: [Float], configuration: CloudTranscriptionConfiguration, apiKey: String, wordTimings: Bool) async throws -> CloudTranscriptionResult {
        throw CloudTranscriptionError.unsupportedModel
    }
}

/// The speech models each Cloud provider offers (CLD-4). OpenRouter's list is fetched and cached; the
/// others are fixed, taken from each vendor's documentation, default model first.
nonisolated enum CloudTranscriptionCatalog {
    static let openRouterID = "openrouter"
    static let openRouterName = "OpenRouter"

    static func models(for providerID: String) -> [CloudTranscriptionModel] {
        switch providerID {
        case self.openRouterID: CloudTranscriptionModel.catalog
        case DeepgramTranscriptionClient.id: DeepgramTranscriptionClient.models
        case ElevenLabsTranscriptionClient.id: ElevenLabsTranscriptionClient.models
        case MistralTranscriptionClient.id: MistralTranscriptionClient.models
        case SpeechmaticsTranscriptionClient.id: SpeechmaticsTranscriptionClient.models
        case SonioxTranscriptionClient.id: SonioxTranscriptionClient.models
        case AssemblyAITranscriptionClient.id: AssemblyAITranscriptionClient.models
        case GladiaTranscriptionClient.id: GladiaTranscriptionClient.models
        default: []
        }
    }

    /// The model a provider uses until the user picks another.
    static func defaultModelID(for providerID: String) -> String? {
        providerID == self.openRouterID ? CloudTranscriptionModel.defaultDictationID : self.models(for: providerID).first?.id
    }
}
