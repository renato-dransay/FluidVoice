import Foundation

nonisolated struct CloudAudioDictationModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String

    // EVIDENCE: Google deprecated gemini-2.5-flash, flash-lite and pro (earliest shutdown 16 October 2026,
    // https://github.com/llm-exe/llm-exe/issues/476), so the offline fallback uses current releases.
    private static let fallbackDefaultID = "google/gemini-3.8-flash"
    /// A styled dictation always sends the whole recording in one request, so the limit is set by
    /// what one request can carry. EVIDENCE: OpenRouter's audio input cap is 25 MB, about 13 minutes of
    /// 16 kHz mono WAV (https://openrouter.ai/blog/tutorials/transcription-on-openrouter/).
    /// JUDGMENT: 8 minutes of 16-bit WAV is 15.4 MB, 20.5 MB once base64-encoded in the JSON body,
    /// which stays under that cap and leaves the response inside the 8192-token output budget.
    static let maximumSamples = 8 * 60 * CloudAudioChunker.sampleRate

    /// The newest Gemini Flash OpenRouter lists, which `current` always sorts first.
    static var defaultID: String { self.catalog.first?.id ?? self.fallbackDefaultID }
    /// The stored choice that follows the OpenRouter model selected in AI Providers.
    static let automaticID = "automatic"
    /// Always offered, so dictation works before the first catalog fetch and while offline.
    static let builtIn: [CloudAudioDictationModel] = [
        .init(id: fallbackDefaultID, name: "Gemini 3.8 Flash"),
        .init(id: "google/gemini-3.5-flash-lite", name: "Gemini 3.5 Flash Lite"),
    ]
    /// Current audio chat models: built-in ones plus every model OpenRouter last listed with audio
    /// input, text output and structured outputs, reduced to the newest release of each family.
    static var catalog: [CloudAudioDictationModel] { CloudTranscriptionCatalogStore.shared.audioDictationModels }

    /// Any model OpenRouter last listed for audio dictation, including older releases `catalog` hides,
    /// so a model inherited from AI Providers can run even when the picker does not offer it.
    static func listed(_ id: String) -> CloudAudioDictationModel? {
        CloudTranscriptionCatalogStore.shared.audioDictationModel(id: id)
    }

    static func isListed(_ id: String) -> Bool { self.listed(id) != nil }

    /// Automatic uses the AI Providers OpenRouter model when it accepts audio, otherwise the default.
    static func automaticModelID(inheriting providerModel: String?) -> String {
        let model = providerModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return self.isListed(model) ? model : self.defaultID
    }

    /// Keeps the newest release of each model family, preferring a stable release over a preview of
    /// the same version, and orders Gemini Flash, Flash Lite and Pro first, then the rest by id.
    /// JUDGMENT: OpenRouter publishes no quality ranking for audio dictation, so recency is the
    /// only signal that reliably hides deprecated generations without hiding other vendors.
    static func current(_ models: [CloudAudioDictationModel]) -> [CloudAudioDictationModel] {
        var newest: [String: (model: CloudAudioDictationModel, rank: ReleaseRank)] = [:]
        for model in models where !model.id.contains("customtools") {
            let release = ReleaseRank(id: model.id)
            if let current = newest[release.family], !(current.rank < release) { continue }
            newest[release.family] = (model, release)
        }
        return newest.values.map(\.model).sorted {
            let left = Self.displayOrder($0.id), right = Self.displayOrder($1.id)
            return left == right ? $0.id < $1.id : left < right
        }
    }

    private static func displayOrder(_ id: String) -> Int {
        switch ReleaseRank(id: id).family {
        case "google/gemini-flash": 0
        case "google/gemini-flash-lite": 1
        case "google/gemini-pro": 2
        default: 3
        }
    }

    /// `google/gemini-3.1-pro-preview` has family `google/gemini-pro`, version [3, 1] and is a preview.
    private struct ReleaseRank: Comparable {
        let family: String
        let version: [Int]
        let isPreview: Bool

        init(id: String) {
            let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
            let vendor = parts.count == 2 ? parts[0] + "/" : ""
            var name = parts.last ?? id
            self.isPreview = name.contains("-preview")
            name = name.replacingOccurrences(of: "-preview", with: "")
            self.version = name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            let stripped = name.replacingOccurrences(of: "[0-9]+(\\.[0-9]+)*", with: "", options: .regularExpression)
            let family = stripped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
            self.family = vendor + family
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.version != rhs.version { return lhs.version.lexicographicallyPrecedes(rhs.version) }
            return lhs.isPreview && !rhs.isPreview
        }
    }
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
    /// The Cloud provider whose client, catalog and key serve this configuration.
    let providerID: String
    let modelID: String
    let languageCode: String?
    let audioDictation: CloudAudioDictationInstructions?
    let primaryLanguageCode: String?
    let secondaryLanguageCode: String?
    /// True for the user's stored choice of a model the provider's catalog no longer lists. Such a model
    /// is still sent, so an app update never switches a user's model silently; its word timings count
    /// as unchecked. A model typed anywhere else must be listed.
    let allowsUnlistedModel: Bool

    init(
        providerID: String = CloudTranscriptionCatalog.openRouterID,
        modelID: String = CloudTranscriptionModel.defaultDictationID,
        languageCode: String? = nil,
        primaryLanguageCode: String? = nil,
        secondaryLanguageCode: String? = nil,
        audioDictation: CloudAudioDictationInstructions? = nil,
        allowsUnlistedModel: Bool = false
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.allowsUnlistedModel = allowsUnlistedModel
        self.audioDictation = audioDictation
        self.languageCode = Self.normalizedLanguageCode(languageCode)
        self.primaryLanguageCode = Self.normalizedLanguageCode(primaryLanguageCode)
        let secondary = Self.normalizedLanguageCode(secondaryLanguageCode)
        self.secondaryLanguageCode = secondary != self.primaryLanguageCode ? secondary : nil
    }

    /// Configurations saved before other Cloud providers existed carry no provider and were OpenRouter's.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.providerID = try values.decodeIfPresent(String.self, forKey: .providerID) ?? CloudTranscriptionCatalog.openRouterID
        self.modelID = try values.decode(String.self, forKey: .modelID)
        self.languageCode = try values.decodeIfPresent(String.self, forKey: .languageCode)
        self.audioDictation = try values.decodeIfPresent(CloudAudioDictationInstructions.self, forKey: .audioDictation)
        self.primaryLanguageCode = try values.decodeIfPresent(String.self, forKey: .primaryLanguageCode)
        self.secondaryLanguageCode = try values.decodeIfPresent(String.self, forKey: .secondaryLanguageCode)
        self.allowsUnlistedModel = try values.decodeIfPresent(Bool.self, forKey: .allowsUnlistedModel) ?? false
    }

    /// The flag is written only when set, so a listed model encodes as before and keeps its chunk cache.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.providerID, forKey: .providerID)
        try values.encode(self.modelID, forKey: .modelID)
        try values.encodeIfPresent(self.languageCode, forKey: .languageCode)
        try values.encodeIfPresent(self.audioDictation, forKey: .audioDictation)
        try values.encodeIfPresent(self.primaryLanguageCode, forKey: .primaryLanguageCode)
        try values.encodeIfPresent(self.secondaryLanguageCode, forKey: .secondaryLanguageCode)
        if self.allowsUnlistedModel { try values.encode(true, forKey: .allowsUnlistedModel) }
    }

    private enum CodingKeys: String, CodingKey {
        case providerID, modelID, languageCode, audioDictation, primaryLanguageCode, secondaryLanguageCode, allowsUnlistedModel
    }

    static let meetingDefault = CloudTranscriptionConfiguration(modelID: CloudTranscriptionModel.defaultMeetingID)

    /// The same request settings with another model or language, for the provider already chosen. Another
    /// model must be listed; only the stored choice may be unlisted.
    func with(
        modelID: String? = nil,
        languageCode: String?? = nil,
        audioDictation: CloudAudioDictationInstructions?? = nil
    ) -> CloudTranscriptionConfiguration {
        let newModelID = modelID ?? self.modelID
        return CloudTranscriptionConfiguration(
            providerID: self.providerID,
            modelID: newModelID,
            languageCode: languageCode ?? self.languageCode,
            primaryLanguageCode: self.primaryLanguageCode,
            secondaryLanguageCode: self.secondaryLanguageCode,
            audioDictation: audioDictation ?? self.audioDictation,
            allowsUnlistedModel: self.allowsUnlistedModel && newModelID == self.modelID
        )
    }

    /// The model and its word-timing support come from this provider's own catalog (CLD-4). Only
    /// OpenRouter has the style model that hears the audio and applies a Cleanup Style in one request.
    func validate(wordTimings: Bool) throws {
        for code in [self.languageCode, self.primaryLanguageCode, self.secondaryLanguageCode].compactMap({ $0 }) where !Self.supportedLanguageCodes.contains(code) {
            throw CloudTranscriptionError.invalidLanguage
        }
        if let audioDictation {
            guard self.providerID == CloudTranscriptionCatalog.openRouterID, CloudAudioDictationModel.isListed(audioDictation.modelID) else {
                throw CloudTranscriptionError.unsupportedModel
            }
            if wordTimings { throw CloudTranscriptionError.unsupportedWordTimings }
            return
        }
        guard let model = self.model else { throw CloudTranscriptionError.unsupportedModel }
        if wordTimings, !model.supportsWordTimings { throw CloudTranscriptionError.unsupportedWordTimings }
    }

    /// True for a stored choice of a model the provider's catalog no longer lists.
    var isUnlistedStoredModel: Bool {
        self.allowsUnlistedModel && self.audioDictation == nil
            && !CloudTranscriptionCatalog.models(for: self.providerID).contains { $0.id == self.modelID }
    }

    /// The error for a failure that says the model cannot be used: a stored model that is no longer listed
    /// is named as withdrawn, so the message points at the model choice rather than account settings.
    func unavailableModelError(_ error: CloudTranscriptionError) -> CloudTranscriptionError {
        guard self.isUnlistedStoredModel, error == .modelUnavailable || error == .unsupportedModel else { return error }
        return .modelNoLongerOffered(self.modelID)
    }

    /// The speech model in this provider's catalog; for a stored choice the catalog no longer lists, that
    /// model with unchecked word timings; otherwise nil.
    var model: CloudTranscriptionModel? {
        if let listed = CloudTranscriptionCatalog.models(for: self.providerID).first(where: { $0.id == self.modelID }) {
            return listed
        }
        guard self.allowsUnlistedModel, CloudTranscriptionCatalog.defaultModelID(for: self.providerID) != nil,
              !self.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return CloudTranscriptionModel(id: self.modelID, name: self.modelID, wordTimingSupport: .unverified, languageHintProviderTags: [])
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
    /// A short line the model picker shows under the name, such as "English only".
    var note: String?

    var supportsWordTimings: Bool { self.wordTimingSupport == .supported }

    static let defaultDictationID = "openai/whisper-large-v3-turbo"
    static let defaultMeetingID = "openai/whisper-large-v3"
    /// Capabilities verified against provider documentation. These are always offered, so cloud
    /// transcription works before the first catalog fetch and while offline.
    static let builtIn: [CloudTranscriptionModel] = [
        .init(id: defaultDictationID, name: "Whisper Large v3 Turbo", wordTimingSupport: .supported, languageHintProviderTags: ["groq", "together"]),
        .init(id: defaultMeetingID, name: "Whisper Large v3", wordTimingSupport: .supported, languageHintProviderTags: ["groq", "together"]),
        // OpenRouter serves whisper-1 through OpenAI only, whose API documents word timestamps for it.
        .init(id: "openai/whisper-1", name: "Whisper 1", wordTimingSupport: .supported, languageHintProviderTags: ["openai"]),
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

extension CloudTranscriptionWord {
    /// True for a character of a script written without spaces between words: Chinese, Japanese, Thai,
    /// Lao, Myanmar and Khmer (Korean separates words with spaces). Words in these scripts are joined
    /// without a space, and a vendor's pieces of them cannot be merged at whitespace.
    nonisolated static func isWrittenWithoutSpaces(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00 ... 0x0EFF, // Thai, Lao
             0x1000 ... 0x109F, // Myanmar
             0x1780 ... 0x17FF, // Khmer
             0x2E80 ... 0x9FFF, // CJK radicals, punctuation, kana and ideographs
             0xF900 ... 0xFAFF, // CJK compatibility ideographs
             0xFF66 ... 0xFF9F, // Half-width katakana
             0x20000 ... 0x3FFFF: // CJK ideograph extensions
            true
        default:
            false
        }
    }
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
    /// A job vendor reported that the transcription job failed.
    case jobFailed
    /// The chosen model transcribes a fixed set of languages, and none of the dictation languages is in it.
    case unsupportedLanguageForModel
    /// A stored speech model the catalog no longer lists, which the provider no longer serves either.
    case modelNoLongerOffered(String)

    var errorDescription: String? { self.message(providerName: CloudTranscriptionCatalog.openRouterName) }

    /// The message for a failure of the named provider. Messages never carry server text.
    func message(providerName name: String) -> String {
        switch self {
        case .missingAPIKey: ProviderKeyMessage.missing(providerName: name)
        case .authentication: ProviderKeyMessage.rejected(providerName: name) + Self.authenticationDetail(providerName: name)
        case .creditsExhausted: "\(name) has insufficient credits. Add credits or explicitly choose local transcription."
        case .rateLimited: "\(name) is rate limiting requests. Wait before retrying, or choose local transcription."
        case .timeout: "\(name) transcription timed out. Retry to resume completed chunks, or choose local transcription."
        case .network: "Could not reach \(name). Check your connection and retry, or choose local transcription."
        case .unsupportedModel: "This transcription model is not supported by this build. Select a supported Voice Engine model."
        case .modelUnavailable:
            name == CloudTranscriptionCatalog.openRouterName
                ? "OpenRouter cannot route this model with your account settings. Check model availability and allowed providers at https://openrouter.ai/settings/privacy, or select another model."
                : "\(name) cannot use this model with your account. Select another model."
        case .unsupportedWordTimings:
            name == CloudTranscriptionCatalog.openRouterName
                ? "This model has no verified word timings. Choose a Whisper model, or run the word-timing check in meeting settings."
                : "This \(name) model returns no word timings. Choose another model."
        case .invalidLanguage: "Choose Automatic or a supported two-letter language code."
        case .invalidAudio: "The recording contains invalid audio samples or could not be decoded."
        case .oversizedAudio: "The audio chunk exceeds the cloud upload limit. Split the recording and retry."
        case .malformedResponse: "\(name) returned an unreadable transcription response. Retry or choose local transcription."
        case .invalidWordTimings: "\(name) returned missing or invalid word timings. Transcription is incomplete; retry or choose local transcription."
        case .server(let status): "\(name) transcription failed (HTTP \(status)). Retry or choose local transcription."
        case .catalogUnavailable: "\(name) did not list a supported transcription model. Try validation again later."
        case .liveTranscriptionUnavailable: "Cloud transcription runs after recording stops. Select a local model for live captions."
        case .wordTimingCheckSpeechUnavailable: "Could not generate the spoken test clip for the word-timing check. Confirm a system voice is installed, then try again."
        case .wordTimingCheckInconclusive: "The model returned no text for the spoken test clip, so its word timings could not be checked. Try again or choose another model."
        case .dictationTooLong: "OpenRouter dictation with a Cleanup Style supports recordings up to 8 minutes. Record a shorter dictation, turn the style off, or import longer audio as a file."
        case .jobFailed: "\(name) could not transcribe this recording. Retry or choose local transcription."
        case .unsupportedLanguageForModel: "This \(name) model doesn't support your dictation language. Choose another model or language in Voice Engine."
        case .modelNoLongerOffered(let modelID): "\(modelID) is no longer offered by \(name). Choose another speech model in Voice Engine."
        case .truncatedDictationResponse: "OpenRouter stopped before completing the transcription and style response. Record a shorter dictation or choose another audio model."
        }
    }

    /// The message for any error from a request to the named provider.
    static func message(for error: Error, providerName: String) -> String {
        (error as? CloudTranscriptionError)?.message(providerName: providerName) ?? error.localizedDescription
    }

    /// ElevenLabs keys can be limited to some endpoints, so a refused key may only lack speech-to-text access.
    private static func authenticationDetail(providerName: String) -> String {
        providerName == ElevenLabsTranscriptionClient.name ? " The key may lack speech-to-text permission." : ""
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
