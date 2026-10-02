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

    /// Providers added under Voice Engine > Live cloud that have a saved key, in the order they were added.
    var meetingLiveCloudProviderChoices: [LiveTranscriptionProviderID] {
        LiveTranscriptionPreferences(defaults: .standard).addedProviders.filter { !self.liveTranscriptionAPIKey(for: $0).isEmpty }
    }

    /// Makes Live cloud the meeting transcription. Without a usable provider choice it takes the
    /// dictation's live provider, or else the first added provider with a key.
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
            return .unavailable(reason: "Live cloud needs a provider. Add one with its API key in Voice Engine > Live cloud, then choose it in FluidMeet settings.")
        }
        let info = LiveTranscriptionCatalog.info(for: provider)
        let key = apiKey(provider)
        guard !key.isEmpty else {
            return .unavailable(reason: "Live cloud needs a \(info.name) API key. Add it in Voice Engine > Live cloud.")
        }
        let requested = languageCode == MeetingCloudLanguage.automatic ? nil : languageCode
        // JUDGMENT: a transcript language the provider does not list would end the stream as unsupported;
        // a provider that detects languages transcribes it automatically instead. One that cannot detect
        // (Speechmatics) keeps the language and reports it if the provider refuses.
        let language = requested.flatMap { info.supports(languageCode: $0) || !info.detectsLanguageAutomatically ? $0 : nil }
        return .cloud(
            LiveTranscriptionConfiguration(provider: provider, modelID: modelID(provider), languageCode: language, languageHints: languageHints),
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
