import Combine
import Foundation

extension SettingsStore {
    var meetingRecordingLanguageCode: String {
        self.meetingTranscriptionBackendID == .openRouterNemotron ? self.meetingCloudLanguageCode : "en"
    }

    var meetingCloudModelID: String {
        get { UserDefaults.standard.string(forKey: "MeetingCloudModelID") ?? CloudTranscriptionModel.defaultMeetingID }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "MeetingCloudModelID")
        }
    }

    var meetingCloudLanguageCode: String {
        get { UserDefaults.standard.string(forKey: "MeetingCloudLanguageCode") ?? MeetingCloudLanguage.automatic }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "MeetingCloudLanguageCode")
        }
    }

    /// The Live cloud provider meeting captions stream to; nil keeps captions on this Mac.
    var meetingLiveCaptionProvider: LiveTranscriptionProviderID? {
        get { UserDefaults.standard.string(forKey: "MeetingLiveCaptionProvider").flatMap(LiveTranscriptionProviderID.init(rawValue:)) }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue?.rawValue, forKey: "MeetingLiveCaptionProvider")
        }
    }

    /// Providers added under Voice Engine > Live cloud that have a saved key, in the order they were added.
    var meetingLiveCaptionProviderChoices: [LiveTranscriptionProviderID] {
        LiveTranscriptionPreferences(defaults: .standard).addedProviders.filter { !self.liveTranscriptionAPIKey(for: $0).isEmpty }
    }

    /// The language streamed captions use: the cloud transcript language, or automatic detection
    /// when Parakeet makes the transcript, since its English-only limit does not apply to providers.
    var meetingLiveCaptionLanguageCode: String {
        self.meetingTranscriptionBackendID == .openRouterNemotron ? self.meetingCloudLanguageCode : MeetingCloudLanguage.automatic
    }

    /// Where the next recording's live captions come from, read when it starts.
    func meetingLiveCaptionSource() -> MeetingLiveCaptionSource {
        let cloud = CloudTranscriptionPreferences(defaults: .standard)
        return Self.meetingLiveCaptionSource(
            provider: self.meetingLiveCaptionProvider,
            apiKey: { self.liveTranscriptionAPIKey(for: $0) },
            modelID: { LiveTranscriptionPreferences(defaults: .standard).modelID(for: $0) },
            languageCode: self.meetingLiveCaptionLanguageCode,
            languageHints: [cloud.primaryLanguageCode, cloud.secondaryLanguageCode].compactMap { $0 }
        )
    }

    /// `languageCode` is a language code or `MeetingCloudLanguage.automatic`.
    /// The dictation Primary and Secondary languages are the hints, as for live dictation.
    static func meetingLiveCaptionSource(
        provider: LiveTranscriptionProviderID?,
        apiKey: (LiveTranscriptionProviderID) -> String,
        modelID: (LiveTranscriptionProviderID) -> String,
        languageCode: String,
        languageHints: [String]
    ) -> MeetingLiveCaptionSource {
        guard let provider else { return .onDevice }
        let info = LiveTranscriptionCatalog.info(for: provider)
        let key = apiKey(provider)
        guard !key.isEmpty else {
            return .unavailable(reason: "Live captions need a \(info.name) API key. Add it in Voice Engine > Live cloud.")
        }
        let requested = languageCode == MeetingCloudLanguage.automatic ? nil : languageCode
        // JUDGMENT: a transcript language the provider does not list would end the stream as unsupported;
        // a provider that detects languages captions it automatically instead. One that cannot detect
        // (Speechmatics) keeps the language and reports it if the provider refuses.
        let language = requested.flatMap { info.supports(languageCode: $0) || !info.detectsLanguageAutomatically ? $0 : nil }
        return .cloud(
            LiveTranscriptionConfiguration(provider: provider, modelID: modelID(provider), languageCode: language, languageHints: languageHints),
            apiKey: key
        )
    }

    func meetingFinalConfiguration(backendID: MeetingBackendID, recordedLanguageCode: String) -> MeetingFinalProcessingConfiguration {
        if backendID == .openRouterNemotron {
            return MeetingFinalProcessingConfiguration(
                asrProvider: .openRouter,
                asrModel: self.meetingCloudModelID,
                languageCode: self.meetingCloudLanguageCode
            )
        }
        return MeetingFinalProcessingConfiguration(languageCode: recordedLanguageCode == MeetingCloudLanguage.automatic ? "en" : recordedLanguageCode)
    }
}
