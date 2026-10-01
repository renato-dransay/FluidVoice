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
            Text("Each dictation is one request: after recording stops, the audio and your selected Cleanup Style go to the dictation model together, and it returns the finished text. There is no separate cleanup request.")
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
            Toggle("Use OpenRouter for transcription", isOn: Binding(
                get: { self.settings.usesCloudTranscription },
                set: { self.viewModel.setCloudTranscriptionEnabled($0) }
            ))
            .toggleStyle(.switch)
            .disabled(self.viewModel.areSpeechModelActionsBlocked || self.isValidating || (!self.settings.usesCloudTranscription && self.settings.openRouterTranscriptionAPIKey.isEmpty))
            .accessibilityIdentifier("openrouter-transcription-enabled")
            Text(self.settings.usesCloudTranscription
                 ? "OpenRouter is on for dictation and imported files. Turn it off to use your selected local model."
                 : "OpenRouter is off. \(self.settings.openRouterTranscriptionAPIKey.isEmpty ? "Save an API key, then turn it on." : "Turn it on to use cloud transcription.")")
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
        self.dictationControls
        Divider()
        self.importedFileControls
    }

    @ViewBuilder
    private var dictationControls: some View {
        Label("Dictation", systemImage: "mic").font(.callout)
        Picker("Dictation model", selection: self.$settings.cloudDictationModelID) {
            ForEach(self.audioModels, id: \.id) { model in
                Text(model.name).tag(model.id)
                    .disabled(self.hasValidatedDictationCatalog && !self.availableDictationModelIDs.contains(model.id))
            }
        }
        .accessibilityIdentifier("openrouter-audio-dictation-model")
        Text("Choose the style in Cleanup Styles, including app and shortcut rules. Off returns the plain transcript from the same single request. Recordings are limited to 8 minutes; a failure never triggers another request automatically.")
            .font(.caption).foregroundStyle(.secondary)
        Text("The list shows the newest audio-capable models OpenRouter offers, one per model family.")
            .font(.caption).foregroundStyle(.secondary)
        self.languageControls
    }

    /// Imported files, the local API and voice command and rewrite modes use the transcription model.
    @ViewBuilder
    private var importedFileControls: some View {
        Label("Imported files and commands", systemImage: "doc.badge.arrow.up").font(.callout)
        Picker("Transcription model", selection: self.$settings.cloudTranscriptionModelID) {
            self.transcriptionModelOptions
        }
        .accessibilityIdentifier("openrouter-transcription-model")
        Text("Dictation never uses this model. Imported audio and video, the local API, and the command and rewrite modes use it on the transcription endpoint, without Cleanup Styles.")
            .font(.caption).foregroundStyle(.secondary)
        Text("The model list follows OpenRouter's transcription catalog. Whisper models return word timestamps; others return plain text until verified in meeting settings, which has its own model selection.")
            .font(.caption).foregroundStyle(.secondary)
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
            caption: "Dictation detects any language automatically. Choose Primary or Secondary while recording to override detection; the choice is remembered.",
            footnote: "Primary and Secondary are optional hints during automatic detection. A selected language is sent to OpenRouter, or given to the dictation model as an instruction."
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
                self.status = "Key verified. \(dictationModels.count) dictation models and \(transcriptionModels.count) transcription models listed. Your account must allow a provider serving the selected model; access is checked when it is used."
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
