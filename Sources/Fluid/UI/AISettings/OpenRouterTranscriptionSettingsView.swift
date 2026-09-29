import AppKit
import SwiftUI

struct OpenRouterTranscriptionSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    var showsActivationControl = true
    @ObservedObject private var usage = CloudTranscriptionUsageStore.shared
    @State private var keyDraft = ""
    @State private var status = ""
    @State private var isValidating = false
    @State private var retryTask: Task<Void, Never>?
    @State private var availableModelIDs: Set<String> = []
    @State private var hasValidatedCatalog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cloud transcription").font(.headline)
            Text("Audio is sent to OpenRouter after recording stops. AI enhancement is a separate, optional setting.")
                .font(.callout).foregroundStyle(.secondary)

            if self.showsActivationControl {
                self.activationControls
            }
            self.keyControls.disabled(self.viewModel.areSpeechModelActionsBlocked)
            self.modelControls.disabled(self.viewModel.areSpeechModelActionsBlocked)
            self.operationStatus
            self.usageSummary
        }
        .padding(16)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .onDisappear { self.retryTask?.cancel() }
        .onChange(of: self.settings.cloudTranscriptionModelID) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
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
            .disabled(self.viewModel.areSpeechModelActionsBlocked || (!self.settings.usesCloudTranscription && self.settings.openRouterTranscriptionAPIKey.isEmpty))
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
                        try self.settings.saveOpenRouterTranscriptionAPIKey("")
                        self.viewModel.setCloudTranscriptionEnabled(false)
                        self.viewModel.asr.resetTranscriptionProvider()
                        self.status = "API key removed. OpenRouter is off; dictation and imported files use your selected local model."
                    } catch { self.status = error.localizedDescription }
                }.buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private var modelControls: some View {
        Picker("Dictation and file model", selection: self.$settings.cloudTranscriptionModelID) {
            ForEach(CloudTranscriptionModel.catalog, id: \.id) { model in
                Text(model.name).tag(model.id)
                    .disabled(self.hasValidatedCatalog && !self.availableModelIDs.contains(model.id))
            }
        }
        self.languageControls
        Text("Whisper models support word timestamps. GPT transcription models produce plain text. Completed meetings have a separate model selection in meeting settings.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var languageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Language: Detect automatically", systemImage: "globe")
                .font(.callout)
            Text("Speak in any language supported by the model. Optional language hints do not force a language or limit detection to your choices.")
                .font(.caption).foregroundStyle(.secondary)
            self.languageHintPicker("Primary language", selection: Binding(
                get: { self.settings.cloudTranscriptionPrimaryLanguageCode ?? "none" },
                set: { self.settings.cloudTranscriptionPrimaryLanguageCode = $0 == "none" ? nil : $0 }
            ))
            .accessibilityIdentifier("cloud-primary-language")
            self.languageHintPicker(
                "Secondary language",
                selection: Binding(
                    get: { self.settings.cloudTranscriptionSecondaryLanguageCode ?? "none" },
                    set: { self.settings.cloudTranscriptionSecondaryLanguageCode = $0 == "none" ? nil : $0 }
                ),
                excluding: self.settings.cloudTranscriptionPrimaryLanguageCode
            )
            .disabled(self.settings.cloudTranscriptionPrimaryLanguageCode == nil)
            .accessibilityIdentifier("cloud-secondary-language")
            Text("Hints help providers that support them; other providers may ignore them. Leave both empty for unrestricted automatic detection.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func languageHintPicker(_ title: String, selection: Binding<String>, excluding excludedCode: String? = nil) -> some View {
        Picker(title, selection: selection) {
            Text("None (optional)").tag("none")
            ForEach(VoiceEngineLanguageCatalog.whisperLanguages.filter { $0.id.count == 2 && $0.id != excludedCode }) { language in
                Text(language.displayName).tag(language.id)
            }
        }
    }

    @ViewBuilder
    private var operationStatus: some View {
        if self.isValidating { ProgressView("Checking OpenRouter…").controlSize(.small) }
        if !self.status.isEmpty { Text(self.status).font(.callout).textSelection(.enabled) }
        if self.viewModel.asr.hasFailedCloudDictation {
            HStack {
                Button("Retry and copy") { self.retryDictation(useLocal: false) }
                Button("Transcribe locally and copy") { self.retryDictation(useLocal: true) }
                Button("Discard recording", role: .destructive) { self.viewModel.asr.discardFailedCloudDictation() }
            }.disabled(self.viewModel.areSpeechModelActionsBlocked)
        }
        if self.retryTask != nil {
            HStack {
                ProgressView("Transcribing saved recording…").controlSize(.small)
                Button("Cancel retry") { self.retryTask?.cancel() }
            }
        }
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
            self.status = "Key saved. Validate the connection to check access and available models."
        } catch { self.status = error.localizedDescription }
    }

    private func validateConnection() {
        self.isValidating = true
        self.status = ""
        let apiKey = self.settings.openRouterTranscriptionAPIKey
        Task { @MainActor in
            defer { self.isValidating = false }
            do {
                let models = try await OpenRouterTranscriptionClient().validate(apiKey: apiKey)
                self.availableModelIDs = Set(models.map(\.id))
                self.hasValidatedCatalog = true
                self.status = "Key verified. \(models.count) supported models listed. Your account must allow a provider serving the selected model; access is checked when transcribing."
            } catch { self.status = error.localizedDescription }
        }
    }

    private func retryDictation(useLocal: Bool) {
        guard self.retryTask == nil else { return }
        self.retryTask = Task { @MainActor in
            defer { self.retryTask = nil }
            do {
                let text = try await self.viewModel.asr.retryFailedCloudDictation(useLocal: useLocal)
                try Task.checkCancellation()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.status = "Transcript copied. Paste it into your document."
            } catch is CancellationError {
                self.status = "Retry cancelled."
            } catch { self.status = error.localizedDescription }
        }
    }
}
