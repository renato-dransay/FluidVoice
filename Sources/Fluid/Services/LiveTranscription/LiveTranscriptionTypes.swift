import Foundation

/// Streaming speech-to-text vendors reached directly with the user's own key.
nonisolated enum LiveTranscriptionProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case soniox
    case deepgram
    case assemblyAI
    case elevenLabs
    case mistral
    case openAI
    case speechmatics

    var id: String { self.rawValue }
    /// Voice engine keys live under their own ids and are never shared with AI Providers keys.
    var keychainID: String { "live-transcription.\(self.rawValue)" }
}

nonisolated struct LiveTranscriptionModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

nonisolated struct LiveTranscriptionProviderInfo: Identifiable, Sendable {
    let id: LiveTranscriptionProviderID
    let name: String
    /// The first model is the default.
    let models: [LiveTranscriptionModel]
    /// False means the provider needs one language per session, so the Primary language is required.
    let detectsLanguageAutomatically: Bool
    /// ISO 639-1 codes the streaming model lists. Nil means the list is longer than the app's picker.
    let languageCodes: Set<String>? // swiftlint:disable:this discouraged_optional_collection
    let keyURL: URL?
    let usageURL: URL?
    /// False when the realtime API takes no language at all, so a language choice changes nothing.
    var sendsLanguageChoice = true

    var defaultModelID: String { self.models.first?.id ?? "" }

    func supports(languageCode: String) -> Bool {
        self.languageCodes?.contains(languageCode) ?? true
    }

    /// True when this provider cannot run until a Primary language is set.
    func needsPrimaryLanguage(primaryLanguageCode: String?) -> Bool {
        !self.detectsLanguageAutomatically && primaryLanguageCode == nil
    }
}

/// Frozen per recording, like `CloudTranscriptionConfiguration`.
nonisolated struct LiveTranscriptionConfiguration: Equatable, Sendable {
    let provider: LiveTranscriptionProviderID
    let modelID: String
    /// A language picked for this recording; nil means automatic detection.
    let languageCode: String?
    /// Primary and Secondary languages, used as hints during automatic detection.
    let languageHints: [String]

    func with(languageCode: String?) -> Self {
        Self(provider: self.provider, modelID: self.modelID, languageCode: languageCode, languageHints: self.languageHints)
    }
}

nonisolated enum LiveTransportMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

nonisolated struct LiveTranscriptSegment: Equatable, Sendable {
    let id: String
    let text: String
    let isFinal: Bool
    /// End of the audio this segment covers, in milliseconds from the first sample sent on its connection.
    let audioEndMilliseconds: Int?
}

nonisolated enum LiveTranscriptUpdate: Equatable, Sendable {
    /// Adds the segment, or replaces the one with the same id. Order is first appearance.
    case segment(LiveTranscriptSegment)
    /// Replaces the provisional tail shown after every segment.
    case pending(String)
    /// The provider's complete transcript of this connection; replaces its segments.
    case replaceAll(String)
    /// Messages to send in answer, such as a configuration after the server's greeting.
    case reply([LiveTransportMessage])
    /// The server accepted the configuration; audio may flow.
    case ready
    /// Every audio frame sent is transcribed and final.
    case finished
    case failure(LiveTranscriptionError)
}

nonisolated enum LiveTranscriptionError: Error, Equatable, Sendable, LocalizedError {
    case missingAPIKey
    case authentication
    case quotaExhausted
    case rateLimited
    case connectionFailed
    case connectionLost
    case finalTimeout
    /// A provider error code, never a server message: those can quote audio content.
    case sessionClosed(String)
    case unsupportedLanguage(String)
    /// The provider needs one set language per session and none was chosen or set as Primary.
    case languageRequired

    func message(providerName: String) -> String {
        switch self {
        case .missingAPIKey: "Add a \(providerName) API key in Voice Engine settings before using live transcription."
        case .authentication: "\(providerName) rejected the API key. Update it in Voice Engine settings and retry."
        case .quotaExhausted: "\(providerName) has no remaining credits or quota. Add credits, or activate another voice engine."
        case .rateLimited: "\(providerName) is limiting requests. Wait before retrying, or activate another voice engine."
        case .connectionFailed: "Could not reach \(providerName). Check your connection and retry, or activate another voice engine."
        case .connectionLost: "The connection to \(providerName) dropped and could not be restored. Your recording is kept; retry, transcribe locally, or discard it."
        case .finalTimeout: "\(providerName) did not return the final text in time. Your recording is kept; retry, transcribe locally, or discard it."
        case .sessionClosed(let code): "\(providerName) ended the session early (\(code)). Your recording is kept; retry, transcribe locally, or discard it."
        case .unsupportedLanguage(let language): "\(providerName) can't transcribe \(language) with this model. Choose another language or provider."
        case .languageRequired:
            "\(providerName) needs one set language. Choose a Primary language under Dictation language in Voice Engine settings, or activate another provider."
        }
    }

    var errorDescription: String? { self.message(providerName: "The live provider") }

    /// A rejected key, an empty account or an unsupported language fails the same way on a new
    /// connection, so the session does not reconnect for these.
    var isPermanent: Bool {
        switch self {
        case .authentication, .quotaExhausted, .unsupportedLanguage, .languageRequired: true
        default: false
        }
    }

    /// Short kind for logs, matching `CloudTranscriptionFailureSummary` style.
    var kind: String {
        switch self {
        case .sessionClosed(let code): "sessionClosed(\(code))"
        case .unsupportedLanguage: "unsupportedLanguage"
        default: String(describing: self)
        }
    }
}
