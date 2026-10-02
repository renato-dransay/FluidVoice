import SwiftUI

struct OpenRouterTranscriptionSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    var showsActivationControl = true
    @ObservedObject private var usage = CloudTranscriptionUsageStore.shared
    @State private var keyDraft = ""
    @State private var status = ""
    @State private var isValidating = false
    @State private var models = CloudTranscriptionModel.catalog
    @State private var audioModels = CloudAudioDictationModel.catalog
    @State private var availableModelIDs: Set<String> = []
    @State private var hasValidatedCatalog = false
    @State private var availableDictationModelIDs: Set<String> = []
    @State private var hasValidatedDictationCatalog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenRouter voice engine").font(.headline)
            Text("Your recording is sent to OpenRouter when you stop.")
                .font(.callout).foregroundStyle(.secondary)

            if self.showsActivationControl {
                self.activationControls
            }
            self.keyControls.disabled(self.viewModel.areSpeechModelActionsBlocked || self.isValidating)
            self.modelControls.disabled(self.viewModel.areSpeechModelActionsBlocked || self.isValidating)
            self.operationStatus
            self.usageSummary
        }
        .padding(16)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .task { await self.refreshCatalog(force: false) }
        .onChange(of: self.settings.cloudTranscriptionModelID) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
        .onChange(of: self.settings.cloudDictationModelID) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
        .onChange(of: self.settings.cloudTranscriptionPrimaryLanguageCode) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
        .onChange(of: self.settings.cloudTranscriptionSecondaryLanguageCode) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
    }

    private var activationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Use OpenRouter", isOn: Binding(
                get: { self.settings.usesCloudTranscription },
                set: { self.viewModel.setCloudTranscriptionEnabled($0) }
            ))
            .toggleStyle(.switch)
            .disabled(self.viewModel.areSpeechModelActionsBlocked || self.isValidating || (!self.settings.usesCloudTranscription && self.settings.openRouterTranscriptionAPIKey.isEmpty))
            .accessibilityIdentifier("openrouter-transcription-enabled")
            Text(self.settings.usesCloudTranscription
                 ? "OpenRouter is on for dictation and imported files. Turn it off to use your selected local model."
                 : "OpenRouter is off. \(self.settings.openRouterTranscriptionAPIKey.isEmpty ? "Save an API key, then turn it on." : "Turn it on to send recordings to OpenRouter.")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var keyControls: some View {
        HStack {
            SecureField(self.settings.openRouterTranscriptionAPIKey.isEmpty ? "OpenRouter API key" : "Replace saved API key", text: self.$keyDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("openrouter-transcription-key")
            Button("Save key") { self.saveKey() }
                .disabled(self.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Validate connection") { self.validateConnection() }
                .disabled(self.isValidating || self.settings.openRouterTranscriptionAPIKey.isEmpty)
        }
        if !self.settings.openRouterTranscriptionAPIKey.isEmpty {
            HStack {
                Label("Key saved in macOS Keychain", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Remove key", role: .destructive) {
                    do {
                        let wasActive = self.settings.usesCloudTranscription
                        try self.settings.saveOpenRouterTranscriptionAPIKey("")
                        self.viewModel.setCloudTranscriptionEnabled(false)
                        self.viewModel.asr.resetTranscriptionProvider()
                        self.clearValidatedCatalogs()
                        // A live provider stays active when the OpenRouter key goes.
                        self.status = wasActive
                            ? "API key removed. OpenRouter is off; dictation and imported files use your selected local model."
                            : "API key removed."
                    } catch { self.status = error.localizedDescription }
                }.buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private var modelControls: some View {
        self.speechModelControls
        self.styleModelControls
        self.dictationRouteStatus
        Divider()
        self.languageControls
    }

    /// Dictation without a Cleanup Style, imported files, the local API and the voice command and
    /// rewrite modes all run on the speech model, on the transcription endpoint.
    @ViewBuilder
    private var speechModelControls: some View {
        Picker("Speech model", selection: self.$settings.cloudTranscriptionModelID) {
            self.transcriptionModelOptions
        }
        .accessibilityIdentifier("openrouter-transcription-model")
        Text("Turns speech into text. Used for dictation, imported files and voice commands.")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Only a dictation with a Cleanup Style reaches the style model, an audio chat model that
    /// hears the recording and writes it in that style.
    @ViewBuilder
    private var styleModelControls: some View {
        Picker("Style model", selection: self.$settings.cloudDictationModelSelection) {
            Text("Automatic (\(self.modelName(self.automaticModelID)))").tag(CloudAudioDictationModel.automaticID)
            Divider()
            ForEach(self.audioModels, id: \.id) { model in
                Text(model.name).tag(model.id)
                    .disabled(self.hasValidatedDictationCatalog && !self.availableDictationModelIDs.contains(model.id))
            }
        }
        .accessibilityIdentifier("openrouter-audio-dictation-model")
        .help(self.automaticExplanation)
        Text("Used only when a Cleanup Style is on: it hears the recording and writes it in that style. Recordings up to 8 minutes.")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Says which of the two models the next dictation reaches, so nobody has to work it out.
    private var dictationRouteStatus: some View {
        Label(self.dictationRouteText, systemImage: "arrow.turn.down.right")
            .font(.callout)
            .accessibilityIdentifier("openrouter-dictation-route")
    }

    private var dictationRouteText: String {
        guard self.settings.resolvedDictationPromptSelection(for: .primary, appBundleID: nil) != .off else {
            return "Dictation now uses \(self.speechModelName). Cleanup Style is Off."
        }
        let style = self.settings.dictationPromptDisplayName(for: .primary, appBundleID: nil)
        return "Dictation now uses \(self.modelName(self.settings.cloudDictationModelID)) with the \(style) Cleanup Style. App and shortcut rules can change the style."
    }

    private var speechModelName: String {
        let id = self.settings.cloudTranscriptionModelID
        return self.models.first { $0.id == id }?.name ?? id
    }

    private var automaticModelID: String {
        CloudAudioDictationModel.automaticModelID(inheriting: self.settings.openRouterAIProviderModel)
    }

    /// Says which model Automatic resolves to and why, so the choice never needs a second look.
    private var automaticExplanation: String {
        let fallback = self.modelName(CloudAudioDictationModel.defaultID)
        guard let providerModel = self.settings.openRouterAIProviderModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerModel.isEmpty
        else {
            return "Automatic uses the OpenRouter model selected in AI Providers when it accepts audio, otherwise \(fallback)."
        }
        if CloudAudioDictationModel.isListed(providerModel) {
            return "Automatic uses \(self.modelName(providerModel)), the OpenRouter model selected in AI Providers."
        }
        return "Automatic uses \(fallback) because \(providerModel), selected in AI Providers, does not accept audio."
    }

    private func modelName(_ id: String) -> String {
        CloudAudioDictationModel.listed(id)?.name ?? id
    }

    private var transcriptionModelOptions: some View {
        ForEach(self.models, id: \.id) { model in
            Text(model.name).tag(model.id)
                .disabled(self.hasValidatedCatalog && !self.availableModelIDs.contains(model.id))
        }
    }

    private var languageControls: some View {
        DictationLanguageControls(
            settings: self.settings,
            caption: "Dictation detects any language automatically. Choose Primary or Secondary while recording to override detection; the choice is remembered."
        )
    }

    @ViewBuilder
    private var operationStatus: some View {
        if self.isValidating { ProgressView("Checking OpenRouter…").controlSize(.small) }
        if !self.status.isEmpty { Text(self.status).font(.callout).textSelection(.enabled) }
        FailedDictationRecoveryControls(viewModel: self.viewModel, hasFailedRecording: self.viewModel.asr.hasFailedCloudDictation)
    }

    @ViewBuilder
    private var usageSummary: some View {
        if self.usage.requestCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.totalUsageText)
                if self.usage.unknownCostCount > 0 {
                    Text("Cost unavailable for \(self.usage.unknownCostCount) requests; the total above is incomplete.")
                }
                if let text = self.lastUsageText {
                    Text(text)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        if let error = self.usage.persistenceError {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
        if let activityURL = URL(string: "https://openrouter.ai/activity") {
            Link("OpenRouter usage and credits", destination: activityURL)
        }
    }

    private var totalUsageText: String {
        let amount = String(format: "%.5f", self.usage.knownCostUSD)
        return "Recorded cost: $\(amount) USD across \(self.usage.requestCount) requests"
    }

    private var lastUsageText: String? {
        guard let last = self.usage.lastRecord else { return nil }
        let duration = String(format: "%.2f", last.processingDuration)
        let cost: String
        if let amount = last.costUSD {
            cost = "$" + String(format: "%.5f", amount) + " USD"
        } else {
            cost = "unknown"
        }
        return "Last request: \(duration) seconds. Cost: \(cost)"
    }

    private func saveKey() {
        do {
            try self.settings.saveOpenRouterTranscriptionAPIKey(self.keyDraft)
            self.keyDraft = ""
            self.viewModel.asr.resetTranscriptionProvider()
            self.clearValidatedCatalogs()
            self.status = "Key saved. Validate the connection to check access and available models."
        } catch { self.status = error.localizedDescription }
    }

    private func validateConnection() {
        self.isValidating = true
        self.status = ""
        let apiKey = self.settings.openRouterTranscriptionAPIKey
        Task { @MainActor in
            defer { self.isValidating = false }
            // Validation reports what OpenRouter lists now, so refresh the cached catalog first.
            await self.refreshCatalog(force: true)
            do {
                let client = OpenRouterTranscriptionClient.shared
                let dictationModels = try await client.validateAudioDictation(apiKey: apiKey)
                self.availableDictationModelIDs = Set(dictationModels.map(\.id))
                self.hasValidatedDictationCatalog = true
                let transcriptionModels = try await client.validate(apiKey: apiKey)
                self.availableModelIDs = Set(transcriptionModels.map(\.id))
                self.hasValidatedCatalog = true
                self.status = "Key verified. \(transcriptionModels.count) speech models and \(dictationModels.count) style models listed. Your account must allow a provider serving the selected model; access is checked when it is used."
            } catch { self.status = error.localizedDescription }
        }
    }

    /// The catalog is fetched only once a key is saved, so a local-only setup never contacts
    /// OpenRouter. A failed fetch keeps the cached list; validation reports connection errors.
    private func refreshCatalog(force: Bool) async {
        guard !self.settings.openRouterTranscriptionAPIKey.isEmpty else { return }
        do {
            try await CloudTranscriptionCatalogStore.shared.refresh(using: .shared, force: force)
            self.models = CloudTranscriptionModel.catalog
            self.audioModels = CloudAudioDictationModel.catalog
        } catch is CancellationError {
            return
        } catch {
            DebugLogger.shared.warning("OpenRouter transcription catalog refresh failed: \(error)", source: "OpenRouterTranscriptionSettingsView")
        }
    }

    private func clearValidatedCatalogs() {
        self.availableModelIDs = []
        self.hasValidatedCatalog = false
        self.availableDictationModelIDs = []
        self.hasValidatedDictationCatalog = false
    }
}
