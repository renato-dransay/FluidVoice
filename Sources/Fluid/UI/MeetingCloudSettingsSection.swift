import SwiftUI

struct MeetingCloudSettingsSection: View {
    /// The three meeting transcription choices, named like the Voice Engine tabs. Cloud is OpenRouter
    /// for meetings.
    private enum Engine: Hashable {
        case local
        case openRouter
        case liveCloud
    }

    /// The on-device transcript language from the recording defaults draft; Cloud and Live cloud use their own language.
    @Binding var localLanguageCode: String
    /// Leaves FluidMeet settings for another screen: AI Providers for keys, Voice Engine for live providers.
    let onNavigate: (AppNavigationDestination) -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    @State private var models = CloudTranscriptionModel.catalog
    @State private var checkProgress: (completed: Int, total: Int, modelName: String)?
    @State private var modelStatus = ""

    private var engine: Engine {
        switch self.settings.meetingTranscriptionBackendID {
        case .openRouterNemotron: .openRouter
        case .liveCloudNemotron: .liveCloud
        default: .local
        }
    }

    private var usesCloud: Bool { self.engine == .openRouter }

    var body: some View {
        FluidManagementGroup(title: "Meeting transcription") {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                Picker("Transcription", selection: Binding(
                    get: { self.engine },
                    set: { self.select($0) }
                )) {
                    Text("Local").tag(Engine.local)
                    Text("Cloud").tag(Engine.openRouter)
                    Text("Live cloud").tag(Engine.liveCloud)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("meeting-transcription-engine")

                switch self.engine {
                case .openRouter: self.openRouterSettings
                case .liveCloud: self.liveCloudSettings
                case .local: self.localSettings
                }
                self.caption(self.engine == .liveCloud
                    ? "Changes apply when the next recording starts."
                    : "Changes apply when the next transcription starts.")
            }
        }
        .task(id: self.usesCloud) { await self.refreshCatalog() }
    }

    private func select(_ engine: Engine) {
        switch engine {
        case .local: self.settings.meetingTranscriptionBackendID = .parakeetNemotron
        case .openRouter: self.settings.meetingTranscriptionBackendID = .openRouterNemotron
        case .liveCloud: self.settings.selectMeetingLiveCloud()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var localSettings: some View {
        Menu {
            Picker("Meeting language", selection: self.$localLanguageCode) {
                ForEach(VoiceEngineLanguageCatalog.allLanguages(availableModels: [.parakeetTDT])) { language in
                    Text(language.displayName).tag(language.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(VoiceEngineLanguageCatalog.language(id: self.localLanguageCode, availableModels: [.parakeetTDT])?.displayName ?? "Choose language…")
        }
        .fluidDropdownStyle(fillsWidth: true)
        .accessibilityLabel("Meeting transcript language")
        self.caption("Parakeet transcribes 25 languages on this Mac. Live captions also run on this Mac, in English only.")
    }

    private var transcriptLanguagePicker: some View {
        Picker("Transcript language", selection: self.$settings.meetingCloudLanguageCode) {
            ForEach(MeetingCloudLanguage.choices, id: \.code) { language in
                Text(language.name).tag(language.code)
            }
        }
    }

    @ViewBuilder
    private var openRouterSettings: some View {
        Picker("Meeting model", selection: self.$settings.meetingCloudModelID) {
            ForEach(self.supportedModels, id: \.id) { model in
                Text(model.name).tag(model.id)
            }
            if !self.supportedModels.contains(where: { $0.id == self.settings.meetingCloudModelID }) {
                Text("\(self.name(for: self.settings.meetingCloudModelID)) (word timings not checked)").tag(self.settings.meetingCloudModelID)
            }
        }
        .disabled(self.checkProgress != nil)
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Button(self.uncheckedModels.isEmpty ? "Re-check models without word timings" : "Check catalog models for word timings", action: self.checkCatalogModels)
                .meetingGlassAction()
                .disabled(self.checkProgress != nil || self.checkCandidates.isEmpty)
            if let progress = self.checkProgress {
                ProgressView("Checking \(progress.completed) of \(progress.total): \(progress.modelName)…").controlSize(.small)
            }
        }
        if !self.modelStatus.isEmpty {
            Text(self.modelStatus)
                .font(self.theme.typography.caption)
                .textSelection(.enabled)
        }
        self.caption(self.uncheckedModels.isEmpty
            ? "Only models with verified word timings are listed, because meetings need them to label speakers."
            : "Only models with verified word timings are listed, because meetings need them to label speakers. OpenRouter lists \(self.uncheckedModels.count) unchecked models; checking sends each one short synthetic clip.")
        self.transcriptLanguagePicker
        self.caption("Recorded audio is sent to OpenRouter after you stop. Other cloud providers are not available for meetings yet. Speaker detection stays on this Mac, and live captions run on this Mac in English. Charges apply to audio duration.")
        Button(self.settings.openRouterTranscriptionAPIKey.isEmpty ? "Set up in AI Providers" : "Manage in AI Providers") {
            self.onNavigate(.aiProvider(id: CloudTranscriptionPreferences.defaultProviderID, origin: .fluidMeet))
        }
        .meetingGlassAction()
        .accessibilityIdentifier("meeting-openrouter-key")
    }

    private var liveProviderChoices: [LiveTranscriptionProviderID] { self.settings.meetingLiveCloudProviderChoices }

    @ViewBuilder
    private var liveCloudSettings: some View {
        let selected = self.settings.meetingLiveCloudProvider
        if self.liveProviderChoices.isEmpty, selected == nil {
            self.caption("Connect a live provider with its API key in AI Providers, then choose it here. Live cloud streams the meeting while you record, so captions and the transcript come from the same provider.")
            Button("Set up a live provider in AI Providers") {
                self.onNavigate(.addProvider(capability: .liveTranscription, origin: .fluidMeet))
            }
            .meetingGlassAction()
        } else {
            Picker("Live provider", selection: self.$settings.meetingLiveCloudProvider) {
                if selected == nil {
                    Text("Choose a provider").tag(LiveTranscriptionProviderID?.none)
                }
                ForEach(self.liveProviderChoices) { provider in
                    Text(Self.name(of: provider)).tag(Optional(provider))
                }
                if let selected, !self.liveProviderChoices.contains(selected) {
                    Text("\(Self.name(of: selected)) (key required)").tag(Optional(selected))
                }
            }
            .accessibilityIdentifier("meeting-live-cloud-provider")
            if let selected {
                self.caption("Model: \(Self.modelName(of: selected)). Change it in the provider's Manage sheet in Voice Engine.")
            }
            self.transcriptLanguagePicker
            if let selected, let note = self.languageNote(for: selected) {
                self.caption(note)
            }
            self.caption(self.liveCloudPrivacy(selected))
            Button("Manage live providers in Voice Engine") { self.onNavigate(.voiceEngine(tab: .liveCloud)) }
                .meetingGlassAction()
        }
    }

    private func liveCloudPrivacy(_ provider: LiveTranscriptionProviderID?) -> String {
        guard let provider else { return "Choose the provider that receives the meeting audio." }
        let name = Self.name(of: provider)
        if !self.liveProviderChoices.contains(provider) {
            return "\(name) has no saved API key, so meetings cannot be transcribed until you add one in AI Providers."
        }
        return [
            "While you record, meeting audio streams to \(name) with your key. Live captions and the completed transcript both come from it, so nothing is uploaded after you stop.",
            "Speaker detection stays on this Mac.",
            "Online calls stream your microphone and the call audio separately, and \(name) bills each stream for the whole recording.",
        ].joined(separator: " ")
    }

    /// Mirrors `SettingsStore.meetingLiveCloudSource`: a language the provider does not list is
    /// detected automatically when the provider can.
    private func languageNote(for provider: LiveTranscriptionProviderID) -> String? {
        let info = LiveTranscriptionCatalog.info(for: provider)
        let code = self.settings.meetingCloudLanguageCode
        guard code != MeetingCloudLanguage.automatic else {
            return info.detectsLanguageAutomatically ? nil : "\(info.name) cannot detect the language, so it uses your Primary language from Voice Engine."
        }
        let modelID = LiveTranscriptionPreferences(defaults: .standard).modelID(for: provider)
        guard info.supports(languageCode: code, modelID: modelID) || !info.detectsLanguageAutomatically else {
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            return "\(info.name) does not list \(name), so it detects the language automatically."
        }
        return nil
    }

    private static func name(of provider: LiveTranscriptionProviderID) -> String {
        LiveTranscriptionCatalog.info(for: provider).name
    }

    private static func modelName(of provider: LiveTranscriptionProviderID) -> String {
        let modelID = LiveTranscriptionPreferences(defaults: .standard).modelID(for: provider)
        return LiveTranscriptionCatalog.info(for: provider).models.first { $0.id == modelID }?.name ?? modelID
    }

    private var supportedModels: [CloudTranscriptionModel] { self.models.filter(\.supportsWordTimings) }

    private var uncheckedModels: [CloudTranscriptionModel] { self.models.filter { $0.wordTimingSupport == .unverified } }

    /// Unchecked models first; once every model has a verdict, the refusals can be rechecked in
    /// case a provider added timings. Verified models are never rechecked.
    private var checkCandidates: [CloudTranscriptionModel] {
        self.uncheckedModels.isEmpty ? self.models.filter { !$0.supportsWordTimings } : self.uncheckedModels
    }

    private func name(for modelID: String) -> String {
        self.models.first { $0.id == modelID }?.name ?? modelID
    }

    /// The catalog is fetched only once cloud meetings are on and a key is saved, so a
    /// local-only setup never contacts OpenRouter. A failed fetch keeps the cached list.
    private func refreshCatalog() async {
        guard self.usesCloud, !self.settings.openRouterTranscriptionAPIKey.isEmpty else { return }
        do {
            try await CloudTranscriptionCatalogStore.shared.refresh(using: .shared)
            self.models = CloudTranscriptionModel.catalog
        } catch is CancellationError {
            return
        } catch {
            DebugLogger.shared.warning("OpenRouter transcription catalog refresh failed: \(error)", source: "MeetingCloudSettingsSection")
        }
    }

    /// Sends one synthesized clip to every unchecked model and remembers each verdict, so the
    /// picker only ever offers models that have returned usable word timings on this Mac.
    private func checkCatalogModels() {
        let candidates = self.checkCandidates
        guard self.checkProgress == nil, !candidates.isEmpty else { return }
        let apiKey = self.settings.openRouterTranscriptionAPIKey
        guard !apiKey.isEmpty else {
            self.modelStatus = "Add an OpenRouter API key in AI Providers before checking models."
            return
        }
        self.modelStatus = ""
        self.checkProgress = (0, candidates.count, candidates[0].name)
        Task { @MainActor in
            defer {
                self.checkProgress = nil
                self.models = CloudTranscriptionModel.catalog
            }
            var passed: [String] = []
            var refused: [String] = []
            var failures: [String] = []
            do {
                let speech = try await CloudWordTimingCheckSpeech.samples()
                let client = OpenRouterTranscriptionClient.shared
                for (index, model) in candidates.enumerated() {
                    self.checkProgress = (index + 1, candidates.count, model.name)
                    do {
                        let supported = try await client.checkWordTimings(modelID: model.id, speechSamples: speech, apiKey: apiKey)
                        CloudTranscriptionCatalogStore.shared.recordWordTimingCheck(modelID: model.id, supported: supported)
                        if supported { passed.append(model.name) } else { refused.append(model.name) }
                    } catch let error as CloudTranscriptionError where Self.abortsCatalogCheck(error) {
                        throw error
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures.append("\(model.name): \(error.localizedDescription)")
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                failures.append(error.localizedDescription)
            }
            self.modelStatus = Self.checkSummary(passed: passed, refused: refused, failures: failures)
        }
    }

    /// Account-level failures repeat for every model, so one is enough to stop.
    private static func abortsCatalogCheck(_ error: CloudTranscriptionError) -> Bool {
        switch error {
        case .missingAPIKey, .authentication, .creditsExhausted, .rateLimited, .wordTimingCheckSpeechUnavailable: true
        default: false
        }
    }

    private static func checkSummary(passed: [String], refused: [String], failures: [String]) -> String {
        var lines: [String] = []
        lines.append(passed.isEmpty ? "No additional model returned word timings." : "Word timings verified: \(passed.joined(separator: ", ")).")
        if !refused.isEmpty { lines.append("No usable word timings: \(refused.joined(separator: ", ")).") }
        if !failures.isEmpty { lines.append("Could not check \(failures.count): \(failures.joined(separator: " "))") }
        return lines.joined(separator: "\n")
    }
}
