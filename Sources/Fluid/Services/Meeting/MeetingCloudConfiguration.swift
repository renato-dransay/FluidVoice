import Foundation

nonisolated enum MeetingCloudLanguage {
    static let automatic = "auto"
    static let supportedCodes = CloudTranscriptionConfiguration.supportedLanguageCodes.union([automatic])

    static var choices: [(code: String, name: String)] {
        let manual = supportedCodes.filter { $0 != automatic }.map { code in
            (code: code, name: Locale.current.localizedString(forLanguageCode: code) ?? code)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [(automatic, "Automatic detection")] + manual
    }
}

nonisolated enum MeetingCloudConfigurationError: LocalizedError, Equatable {
    case missingAPIKey
    case unsupportedModel
    case unsupportedLanguage
    case incompatibleOptions

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenRouter transcription key in Voice Engine settings before transcribing this meeting."
        case .unsupportedModel:
            return "Choose a meeting model verified for word timings in meeting settings. Speaker labels require them."
        case .unsupportedLanguage:
            return "Choose automatic detection or a supported language in meeting settings."
        case .incompatibleOptions:
            return "Cloud meetings do not support local vocabulary or dictionary processing."
        }
    }
}

nonisolated enum MeetingCloudConfiguration {
    static func validate(_ configuration: MeetingFinalProcessingConfiguration) throws {
        guard configuration.asrProvider == .openRouter,
              CloudTranscriptionModel.catalog.contains(where: {
                  $0.id == configuration.asrModel && $0.supportsWordTimings
              })
        else { throw MeetingCloudConfigurationError.unsupportedModel }
        guard MeetingCloudLanguage.supportedCodes.contains(configuration.languageCode) else {
            throw MeetingCloudConfigurationError.unsupportedLanguage
        }
        guard !configuration.vocabularyBoostingEnabled,
              !configuration.pronunciationMatchingEnabled,
              !configuration.customDictionaryRewritingEnabled,
              !configuration.experimentalUnifiedFinalEnabled
        else { throw MeetingCloudConfigurationError.incompatibleOptions }
    }

    static func hasValidTimings(text: String, words: [ASRWordTiming], duration: TimeInterval) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return words.isEmpty }
        guard !words.isEmpty else { return false }
        var previousStart: TimeInterval = 0
        for word in words {
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  word.start.isFinite, word.end.isFinite,
                  word.start >= previousStart, word.end > word.start, word.end <= duration + 0.05
            else { return false }
            previousStart = word.start
        }
        return true
    }
}
