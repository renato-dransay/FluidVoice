import Combine
import SwiftUI

/// The Manage sheet for one live provider: key, model, usage, activation and removal.
struct LiveCloudProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let provider: LiveTranscriptionProviderID
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject private var usage = LiveTranscriptionUsageStore.shared
    @State private var keyDraft = ""
    @State private var status = ""
    @State private var isConfirmingRemoval = false

    private var info: LiveTranscriptionProviderInfo { LiveTranscriptionCatalog.info(for: self.provider) }
    private var hasKey: Bool { !self.settings.liveTranscriptionAPIKey(for: self.provider).isEmpty }
    private var isActive: Bool { self.settings.activeLiveProvider == self.provider }
    private var isChecking: Bool { self.viewModel.liveProviderBeingChecked != nil }

    var body: some View {
        FluidManagementSheet(
            title: self.info.name,
            subtitle: "Connection, model and test.",
            symbol: "waveform",
            close: { self.dismiss() }
        ) {
            self.keyGroup
            self.modelGroup
            // JUDGMENT: the Test block arrives with Task 2.12 and its LiveProviderTestCoordinator.
            self.usageGroup
            Divider()
            self.footer
        }
        .alert("Remove \(self.info.name)?", isPresented: self.$isConfirmingRemoval) {
            Button("Remove provider", role: .destructive) {
                self.viewModel.removeLiveProvider(self.provider)
                self.dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes its saved API key and model choice. If it is active, dictation switches to your selected local model.")
        }
    }

    private var keyGroup: some View {
        FluidManagementGroup(title: "API key") {
            HStack {
                SecureField(self.hasKey ? "Replace saved API key" : "\(self.info.name) API key", text: self.$keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("live-cloud-key-\(self.provider.rawValue)")
                Button("Save key") {
                    self.status = self.viewModel.saveLiveKey(self.keyDraft, for: self.provider)
                    self.keyDraft = ""
                }
                .fluidGlassAction()
                .disabled(self.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(self.viewModel.areSpeechModelActionsBlocked || self.isChecking)
            if self.hasKey {
                HStack {
                    Label("Key saved in macOS Keychain", systemImage: "lock.fill")
                        .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                    Button("Remove key", role: .destructive) {
                        self.status = self.viewModel.saveLiveKey("", for: self.provider)
                    }
                    .buttonStyle(.link)
                    .disabled(self.viewModel.areSpeechModelActionsBlocked || self.isChecking)
                }
            }
            if let keyURL = self.info.keyURL {
                Link(destination: keyURL) {
                    Label("Get a \(self.info.name) API key", systemImage: "arrow.up.right").font(self.theme.typography.caption)
                }
            }
            Text("Voice Engine keys are stored separately from AI Providers keys.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            if !self.status.isEmpty {
                Text(self.status).font(self.theme.typography.caption).textSelection(.enabled)
            }
        }
    }

    private var modelGroup: some View {
        FluidManagementGroup(title: "Model") {
            Picker("Model", selection: Binding(
                get: { LiveTranscriptionPreferences(defaults: .standard).modelID(for: self.provider) },
                set: { modelID in
                    var preferences = LiveTranscriptionPreferences(defaults: .standard)
                    preferences.setModelID(modelID, for: self.provider)
                    self.settings.objectWillChange.send()
                    self.viewModel.asr.resetTranscriptionProvider()
                }
            )) {
                ForEach(self.info.models) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .disabled(self.viewModel.areSpeechModelActionsBlocked)
            .accessibilityIdentifier("live-cloud-model-\(self.provider.rawValue)")
            Text("The model applies from your next recording.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            if !self.info.detectsLanguageAutomatically {
                Text("\(self.info.name) needs a set language for this model. Dictation uses your Primary language.")
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            }
            ForEach(self.unlistedLanguageWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(self.theme.typography.caption).foregroundStyle(.orange)
            }
        }
    }

    /// UX §E4: the sheet warns about configured languages this provider does not list, active or not.
    private var unlistedLanguageWarnings: [String] {
        [self.settings.cloudTranscriptionPrimaryLanguageCode, self.settings.cloudTranscriptionSecondaryLanguageCode]
            .compactMap { $0 }
            .filter { !self.info.supports(languageCode: $0) }
            .map { DictationLanguageControls.unlistedLanguageWarning(provider: self.info.name, languageCode: $0) }
    }

    private var usageGroup: some View {
        FluidManagementGroup(title: "Usage") {
            let totals = self.usage.totals(for: self.provider)
            let minutes = Int((Double(totals.milliseconds) / 60_000).rounded())
            Text("Streamed on this Mac: \(minutes) min across \(totals.recordings) recordings")
            Text("\(self.info.name) doesn't report cost here.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            if let usageURL = self.info.usageURL {
                Link(destination: usageURL) {
                    Label("\(self.info.name) usage and billing", systemImage: "arrow.up.right").font(self.theme.typography.caption)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if self.isActive {
                    Button("Active for dictation", systemImage: "checkmark") {}
                        .fluidGlassAction()
                        .disabled(true)
                } else {
                    Button(self.viewModel.liveProviderBeingChecked == self.provider ? "Checking…" : "Activate for dictation") {
                        Task { await self.viewModel.activateLiveProvider(self.provider) }
                    }
                    .fluidGlassAction(prominent: true)
                    .disabled(!self.hasKey || self.viewModel.areSpeechModelActionsBlocked || self.isChecking)
                    .help(!self.hasKey
                        ? "Save an API key first."
                        : self.viewModel.areSpeechModelActionsBlocked ? "Finish the current recording first." : "Use this provider for dictation. The key is checked first.")
                    .accessibilityIdentifier("live-cloud-activate-\(self.provider.rawValue)")
                }
                Spacer()
                Button("Remove provider", role: .destructive) { self.isConfirmingRemoval = true }
                    .fluidGlassAction()
                    .disabled(self.viewModel.areSpeechModelActionsBlocked || self.isChecking)
            }
            if let message = self.viewModel.liveActivationStatus[self.provider] {
                Text(message)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}
