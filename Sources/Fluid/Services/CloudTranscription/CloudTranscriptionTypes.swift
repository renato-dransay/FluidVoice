import Foundation

nonisolated enum CloudDictationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One transcription request and nothing else: Cleanup Styles are ignored for dictation.
    case transcriptionOnly
    /// A transcription request, then the Cleanup Style through the configured text AI provider.
    case transcriptionThenCleanup
    /// Audio and the Cleanup Style in one chat request to an audio model.
    case transcribeAndStyle

    var id: String { self.rawValue }
}

nonisolated struct CloudAudioDictationModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String

    static let defaultID = "google/gemini-2.5-flash"
    /// These Gemini models accept WAV input and structured output. They are always offered, so
    /// combined dictation works before the first catalog fetch and while offline.
    static let builtIn: [CloudAudioDictationModel] = [
        .init(id: defaultID, name: "Gemini 2.5 Flash"),
        .init(id: "google/gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite"),
        .init(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro"),
    ]
    /// Built-in models followed by every other chat model OpenRouter last listed with audio input,
    /// text output and structured outputs.
    static var catalog: [CloudAudioDictationModel] { CloudTranscriptionCatalogStore.shared.audioDictationModels }
}

nonisolated struct CloudAudioDictationInstructions: Codable, Equatable, Sendable {
    let modelID: String
    let promptText: String?
    let appContext: String
    let precedingText: String
    let spokenSendPhrase: String?

    init(modelID: String, promptText: String?, appContext: String = "", precedingText: String = "", spokenSendPhrase: String? = nil) {
        self.modelID = modelID
        self.promptText = promptText
        self.appContext = appContext
        self.precedingText = precedingText
        self.spokenSendPhrase = spokenSendPhrase
    }
}

nonisolated struct CloudAudioDictationOutput: Codable, Equatable, Sendable {
    let transcript: String
    let text: String
    let modelID: String
    let styleApplied: Bool
    let processingDuration: TimeInterval
}

nonisolated struct CloudTranscriptionConfiguration: Codable, Equatable, Sendable {
    let modelID: String
    let languageCode: String?
    let audioDictation: CloudAudioDictationInstructions?
    let primaryLanguageCode: String?
    let secondaryLanguageCode: String?

    init(modelID: String = CloudTranscriptionModel.defaultDictationID, languageCode: String? = nil, primaryLanguageCode: String? = nil, secondaryLanguageCode: String? = nil, audioDictation: CloudAudioDictationInstructions? = nil) {
        self.modelID = modelID
        self.audioDictation = audioDictation
        self.languageCode = Self.normalizedLanguageCode(languageCode)
        self.primaryLanguageCode = Self.normalizedLanguageCode(primaryLanguageCode)
        let secondary = Self.normalizedLanguageCode(secondaryLanguageCode)
        self.secondaryLanguageCode = secondary != self.primaryLanguageCode ? secondary : nil
    }

    static let meetingDefault = CloudTranscriptionConfiguration(modelID: CloudTranscriptionModel.defaultMeetingID)

    func validate(wordTimings: Bool) throws {
        for code in [self.languageCode, self.primaryLanguageCode, self.secondaryLanguageCode].compactMap({ $0 }) where !Self.supportedLanguageCodes.contains(code) {
            throw CloudTranscriptionError.invalidLanguage
        }
        if let audioDictation {
            guard CloudAudioDictationModel.catalog.contains(where: { $0.id == audioDictation.modelID }) else {
                throw CloudTranscriptionError.unsupportedModel
            }
            if wordTimings { throw CloudTranscriptionError.unsupportedWordTimings }
            return
        }
        guard let model = CloudTranscriptionModel.catalog.first(where: { $0.id == self.modelID }) else {
            throw CloudTranscriptionError.unsupportedModel
        }
        if wordTimings, !model.supportsWordTimings { throw CloudTranscriptionError.unsupportedWordTimings }
    }

    var languageHintPrompt: String? {
        let locale = Locale(identifier: "en_US")
        let languages = [self.primaryLanguageCode, self.secondaryLanguageCode].compactMap { code in
            code.map { locale.localizedString(forLanguageCode: $0) ?? $0 }
        }
        guard !languages.isEmpty else { return nil }
        return "The speaker commonly uses \(languages.joined(separator: " and ")). Other languages may also be spoken."
    }

    private static func normalizedLanguageCode(_ value: String?) -> String? {
        let code = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return code?.isEmpty == false && code != "auto" && code != "none" ? code : nil
    }

    // OpenRouter accepts ISO-639-1 hints; model language coverage is provider-dependent.
    static let supportedLanguageCodes: Set<String> = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 })
}

nonisolated enum CloudWordTimingSupport: String, Codable, Sendable {
    case supported
    case unsupported
    /// Listed by OpenRouter, but no check on this Mac has asked the model for word timings yet.
    case unverified
}

nonisolated struct CloudTranscriptionModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let wordTimingSupport: CloudWordTimingSupport
    // Provider tags and prompt support verified against the provider and OpenRouter STT docs.
    // DeepInfra is deliberately omitted: its prompt forwarding has not been verified.
    // Models discovered from the catalog have no verified tags, so they receive no prompt.
    let languageHintProviderTags: [String]

    var supportsWordTimings: Bool { self.wordTimingSupport == .supported }

    static let defaultDictationID = "openai/whisper-large-v3-turbo"
    static let defaultMeetingID = "openai/whisper-large-v3"
    /// Capabilities verified against provider documentation. These are always offered, so cloud
    /// transcription works before the first catalog fetch and while offline.
    static let builtIn: [CloudTranscriptionModel] = [
        .init(id: defaultDictationID, name: "Whisper Large v3 Turbo", wordTimingSupport: .supported, languageHintProviderTags: ["groq", "together"]),
        .init(id: defaultMeetingID, name: "Whisper Large v3", wordTimingSupport: .supported, languageHintProviderTags: ["groq", "together"]),
        .init(id: "openai/gpt-4o-transcribe", name: "GPT-4o Transcribe", wordTimingSupport: .unsupported, languageHintProviderTags: ["openai"]),
        .init(id: "openai/gpt-4o-mini-transcribe", name: "GPT-4o Mini Transcribe", wordTimingSupport: .unsupported, languageHintProviderTags: ["openai"]),
    ]
    /// Built-in models followed by every other model OpenRouter last listed. Catalog discovery
    /// cannot prove word-timing support, so a listed model stays unverified until a check on
    /// this Mac receives usable timings from it.
    static var catalog: [CloudTranscriptionModel] { CloudTranscriptionCatalogStore.shared.models }
}

nonisolated struct CloudTranscriptionWord: Codable, Equatable, Sendable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
}

nonisolated struct CloudTranscriptionUsage: Codable, Equatable, Sendable {
    let seconds: Double?
    let cost: Double?
}

nonisolated struct CloudTranscriptionResult: Codable, Equatable, Sendable {
    let text: String
    // Nil means timings were not supplied; [] is a valid timed silence result.
    // swiftlint:disable:next discouraged_optional_collection
    let words: [CloudTranscriptionWord]?
    let usage: CloudTranscriptionUsage?
    let requestID: String?
    let processingDuration: TimeInterval
    let dictationOutput: CloudAudioDictationOutput?

    // Preserve missing timings instead of fabricating a timed silence result.
    // swiftlint:disable:next discouraged_optional_collection
    init(text: String, words: [CloudTranscriptionWord]?, usage: CloudTranscriptionUsage?, requestID: String?, processingDuration: TimeInterval, dictationOutput: CloudAudioDictationOutput? = nil) {
        self.text = text
        self.words = words
        self.usage = usage
        self.requestID = requestID
        self.processingDuration = processingDuration
        self.dictationOutput = dictationOutput
    }

    func validateTimings(duration: TimeInterval) throws {
        guard let words else { throw CloudTranscriptionError.invalidWordTimings }
        if words.isEmpty, !self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CloudTranscriptionError.invalidWordTimings
        }
        var lastStart = -Double.infinity
        for word in words {
            guard !word.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  word.start.isFinite, word.end.isFinite,
                  word.start >= 0, word.end > word.start,
                  word.start >= lastStart, word.end <= duration + 0.05
            else { throw CloudTranscriptionError.invalidWordTimings }
            lastStart = word.start
        }
    }
}

nonisolated enum CloudTranscriptionError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey, authentication, creditsExhausted, rateLimited, timeout, network
    case unsupportedModel, modelUnavailable, unsupportedWordTimings, invalidLanguage, invalidAudio, oversizedAudio
    case malformedResponse, invalidWordTimings, server(Int), catalogUnavailable, liveTranscriptionUnavailable
    case wordTimingCheckSpeechUnavailable, wordTimingCheckInconclusive
    case dictationTooLong, truncatedDictationResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an OpenRouter API key in Voice Engine settings before using cloud transcription."
        case .authentication: "OpenRouter rejected the API key. Update it in Voice Engine settings and retry."
        case .creditsExhausted: "OpenRouter has insufficient credits. Add credits or explicitly choose local transcription."
        case .rateLimited: "OpenRouter is rate limiting requests. Wait before retrying, or choose local transcription."
        case .timeout: "OpenRouter transcription timed out. Retry to resume completed chunks, or choose local transcription."
        case .network: "Could not reach OpenRouter. Check your connection and retry, or choose local transcription."
        case .unsupportedModel: "This transcription model is not supported by this build. Select a supported Voice Engine model."
        case .modelUnavailable: "OpenRouter cannot route this model with your account settings. Check model availability and allowed providers at https://openrouter.ai/settings/privacy, or select another model."
        case .unsupportedWordTimings: "This model has no verified word timings. Choose a Whisper model, or run the word-timing check in meeting settings."
        case .invalidLanguage: "Choose Automatic or a supported two-letter language code."
        case .invalidAudio: "The recording contains invalid audio samples or could not be decoded."
        case .oversizedAudio: "The audio chunk exceeds the cloud upload limit. Split the recording and retry."
        case .malformedResponse: "OpenRouter returned an unreadable transcription response. Retry or choose local transcription."
        case .invalidWordTimings: "OpenRouter returned missing or invalid word timings. Transcription is incomplete; retry or choose local transcription."
        case .server(let status): "OpenRouter transcription failed (HTTP \(status)). Retry or choose local transcription."
        case .catalogUnavailable: "OpenRouter did not list a supported transcription model. Try validation again later."
        case .liveTranscriptionUnavailable: "Cloud transcription runs after recording stops. Select a local model for live captions."
        case .wordTimingCheckSpeechUnavailable: "Could not generate the spoken test clip for the word-timing check. Confirm a system voice is installed, then try again."
        case .wordTimingCheckInconclusive: "The model returned no text for the spoken test clip, so its word timings could not be checked. Try again or choose another model."
        case .dictationTooLong: "Transcribe + Style supports recordings up to 120 seconds. Record a shorter dictation or choose Transcription Only for longer recordings."
        case .truncatedDictationResponse: "OpenRouter stopped before completing the transcription and style response. Record a shorter dictation or choose another audio model."
        }
    }
}

nonisolated struct CloudTranscriptionUsageRecord: Codable, Equatable, Sendable {
    let modelID: String
    let costUSD: Double?
    let audioSeconds: Double
    let processingDuration: TimeInterval
    let requestID: String?
    var date = Date()
}

extension Notification.Name {
    nonisolated static let cloudTranscriptionCompleted = Notification.Name("cloudTranscriptionCompleted")
}
