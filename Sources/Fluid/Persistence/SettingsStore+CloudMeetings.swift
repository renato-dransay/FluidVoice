import Combine
import Foundation

extension SettingsStore {
    var meetingRecordingLanguageCode: String {
        self.meetingTranscriptionBackendID.usesCloudLanguage ? self.meetingCloudLanguageCode : "en"
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

    /// The Live cloud provider a meeting streams to when Live cloud makes its transcript.
    var meetingLiveCloudProvider: LiveTranscriptionProviderID? {
        get { Self.meetingLiveCloudProvider(in: .standard) }
        set {
            self.objectWillChange.send()
            Self.setMeetingLiveCloudProvider(newValue, in: .standard)
        }
    }

    static func meetingLiveCloudProvider(in defaults: UserDefaults) -> LiveTranscriptionProviderID? {
        defaults.string(forKey: "MeetingLiveCloudProvider").flatMap(LiveTranscriptionProviderID.init(rawValue:))
    }

    static func setMeetingLiveCloudProvider(_ provider: LiveTranscriptionProviderID?, in defaults: UserDefaults) {
        defaults.set(provider?.rawValue, forKey: "MeetingLiveCloudProvider")
    }

    /// The connected live providers: every live provider with a saved key, in catalog order (FM-3).
    var meetingLiveCloudProviderChoices: [LiveTranscriptionProviderID] {
        Self.meetingLiveCloudProviderChoices(hasKey: { !self.liveTranscriptionAPIKey(for: $0).isEmpty })
    }

    static func meetingLiveCloudProviderChoices(hasKey: (LiveTranscriptionProviderID) -> Bool) -> [LiveTranscriptionProviderID] {
        LiveTranscriptionCatalog.all.map(\.id).filter(hasKey)
    }

    /// Makes Live cloud the meeting transcription. Without a usable provider choice it takes the
    /// dictation's live provider, or else the first connected live provider.
    func selectMeetingLiveCloud() {
        let choices = self.meetingLiveCloudProviderChoices
        if self.meetingLiveCloudProvider.map({ !choices.contains($0) }) ?? true {
            self.meetingLiveCloudProvider = self.activeLiveProvider.flatMap { choices.contains($0) ? $0 : nil } ?? choices.first
        }
        self.meetingTranscriptionBackendID = .liveCloudNemotron
    }

    /// Where the next recording's live captions come from, read when it starts: the Live cloud
    /// provider when it makes the transcript, otherwise the on-device model.
    func meetingLiveCaptionSource() -> MeetingLiveCaptionSource {
        guard self.meetingTranscriptionBackendID == .liveCloudNemotron else { return .onDevice }
        let cloud = CloudTranscriptionPreferences(defaults: .standard)
        return Self.meetingLiveCloudSource(
            provider: self.meetingLiveCloudProvider,
            apiKey: { self.liveTranscriptionAPIKey(for: $0) },
            modelID: { LiveTranscriptionPreferences(defaults: .standard).modelID(for: $0) },
            languageCode: self.meetingCloudLanguageCode,
            languageHints: [cloud.primaryLanguageCode, cloud.secondaryLanguageCode].compactMap { $0 }
        )
    }

    /// `languageCode` is a language code or `MeetingCloudLanguage.automatic`.
    /// The dictation Primary and Secondary languages are the hints, as for live dictation.
    static func meetingLiveCloudSource(
        provider: LiveTranscriptionProviderID?,
        apiKey: (LiveTranscriptionProviderID) -> String,
        modelID: (LiveTranscriptionProviderID) -> String,
        languageCode: String,
        languageHints: [String]
    ) -> MeetingLiveCaptionSource {
        guard let provider else {
            return .unavailable(reason: "Live cloud needs a provider. Connect one with its API key in AI Providers, then choose it in FluidMeet settings.")
        }
        let info = LiveTranscriptionCatalog.info(for: provider)
        let key = apiKey(provider)
        guard !key.isEmpty else {
            return .unavailable(reason: "Live cloud needs \(ProviderKeyMessage.indefiniteArticle(for: info.name)) \(info.name) API key. Add it in AI Providers.")
        }
        let requested = languageCode == MeetingCloudLanguage.automatic ? nil : languageCode
        // JUDGMENT: a transcript language the provider does not list would end the stream as unsupported;
        // a provider that detects languages transcribes it automatically instead. One that cannot detect
        // (Speechmatics) keeps the language and reports it if the provider refuses.
        let model = modelID(provider)
        let language = requested.flatMap { info.supports(languageCode: $0, modelID: model) || !info.detectsLanguageAutomatically ? $0 : nil }
        return .cloud(
            LiveTranscriptionConfiguration(provider: provider, modelID: model, languageCode: language, languageHints: languageHints),
            apiKey: key
        )
    }

    func meetingFinalConfiguration(backendID: MeetingBackendID, recordedLanguageCode: String) -> MeetingFinalProcessingConfiguration {
        if backendID == .liveCloudNemotron {
            // The text was streamed during the recording; the model names the provider that is set now.
            let provider = self.meetingLiveCloudProvider
            return MeetingFinalProcessingConfiguration(
                asrProvider: .liveCloud,
                asrModel: provider.map { "\($0.rawValue)/\(LiveTranscriptionPreferences(defaults: .standard).modelID(for: $0))" } ?? "none",
                languageCode: self.meetingCloudLanguageCode
            )
        }
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
