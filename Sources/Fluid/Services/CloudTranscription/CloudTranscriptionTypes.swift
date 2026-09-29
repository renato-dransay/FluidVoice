import Foundation

nonisolated struct CloudTranscriptionConfiguration: Codable, Equatable, Sendable {
    let modelID: String
    let languageCode: String?

    init(modelID: String = CloudTranscriptionModel.defaultDictationID, languageCode: String? = nil) {
        self.modelID = modelID
        let language = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.languageCode = language?.isEmpty == false ? language : nil
    }

    static let meetingDefault = CloudTranscriptionConfiguration(modelID: CloudTranscriptionModel.defaultMeetingID)

    func validate(wordTimings: Bool) throws {
        guard let model = CloudTranscriptionModel.catalog.first(where: { $0.id == self.modelID }) else {
            throw CloudTranscriptionError.unsupportedModel
        }
        if wordTimings, !model.supportsWordTimings { throw CloudTranscriptionError.unsupportedWordTimings }
        if let languageCode, !Self.supportedLanguageCodes.contains(languageCode) { throw CloudTranscriptionError.invalidLanguage }
    }

    // OpenRouter accepts ISO-639-1 hints; model language coverage is provider-dependent.
    static let supportedLanguageCodes: Set<String> = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 })
}

nonisolated struct CloudTranscriptionModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let supportsWordTimings: Bool

    static let defaultDictationID = "openai/whisper-large-v3-turbo"
    static let defaultMeetingID = "openai/whisper-large-v3"
    // Capability allowlist is deliberate: catalog discovery cannot prove word-timing support.
    static let catalog: [CloudTranscriptionModel] = [
        .init(id: defaultDictationID, name: "Whisper Large v3 Turbo", supportsWordTimings: true),
        .init(id: defaultMeetingID, name: "Whisper Large v3", supportsWordTimings: true),
        .init(id: "openai/gpt-4o-transcribe", name: "GPT-4o Transcribe", supportsWordTimings: false),
        .init(id: "openai/gpt-4o-mini-transcribe", name: "GPT-4o Mini Transcribe", supportsWordTimings: false),
    ]
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
        case .unsupportedWordTimings: "This model does not support validated word timings. Choose a Whisper model."
        case .invalidLanguage: "Choose Automatic or a supported two-letter language code."
        case .invalidAudio: "The recording contains invalid audio samples or could not be decoded."
        case .oversizedAudio: "The audio chunk exceeds the cloud upload limit. Split the recording and retry."
        case .malformedResponse: "OpenRouter returned an unreadable transcription response. Retry or choose local transcription."
        case .invalidWordTimings: "OpenRouter returned missing or invalid word timings. Transcription is incomplete; retry or choose local transcription."
        case .server(let status): "OpenRouter transcription failed (HTTP \(status)). Retry or choose local transcription."
        case .catalogUnavailable: "OpenRouter did not list a supported transcription model. Try validation again later."
        case .liveTranscriptionUnavailable: "Cloud transcription runs after recording stops. Select a local model for live captions."
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
