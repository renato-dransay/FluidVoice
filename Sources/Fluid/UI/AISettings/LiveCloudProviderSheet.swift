import Combine
import SwiftUI

/// The Manage sheet for one live provider: connection, model, test, usage and activation. Its key is
/// entered, replaced and removed in AI Providers.
struct LiveCloudProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let provider: LiveTranscriptionProviderID
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject private var usage = LiveTranscriptionUsageStore.shared
    @ObservedObject private var test = LiveProviderTestCoordinator.shared

    private var info: LiveTranscriptionProviderInfo { LiveTranscriptionCatalog.info(for: self.provider) }
    private var hasKey: Bool { !self.settings.liveTranscriptionAPIKey(for: self.provider).isEmpty }
    private var isActive: Bool { self.settings.activeLiveProvider == self.provider }
    private var isChecking: Bool { self.viewModel.liveProviderBeingChecked != nil }
    private var isTestArmed: Bool { self.test.armedProvider == self.provider }
    private var providerID: String { ProviderRegistry.providerID(for: self.provider) }
    private var needsLanguage: Bool { self.settings.liveProviderNeedsPrimaryLanguage(self.provider) }

    var body: some View {
        FluidManagementSheet(
            title: self.info.name,
            subtitle: "Connection, model and test.",
            symbol: "waveform",
            close: { self.dismiss() }
        ) {
            self.connectionGroup
            self.modelGroup
            self.testGroup
            self.usageGroup
            Divider()
            self.footer
        }
        // Closing the sheet disarms the test, so the next dictation uses the active engine again.
        .onDisappear { if self.isTestArmed { self.test.disarm() } }
    }

    /// The speech status and the way to the key, which lives in AI Providers.
    private var connectionGroup: some View {
        FluidManagementGroup(title: "Connection") {
            HStack(spacing: 12) {
                ProviderStatusBadge(status: ProviderStatus.speech(
                    hasAPIKey: self.hasKey,
                    isVerifying: self.viewModel.liveProviderBeingChecked == self.provider,
                    isVerified: self.settings.isSpeechVerified(self.providerID),
                    verificationFailed: self.viewModel.liveRejectedKeys.contains(self.provider)
                ))
                Spacer()
                Button("Manage in AI Providers") {
                    self.dismiss()
                    AppNavigationRouter.shared.request(.aiProvider(id: self.providerID, origin: .voiceEngine(tab: .liveCloud)))
                }
                .fluidGlassAction(quiet: true)
                .accessibilityIdentifier("live-cloud-manage-key-\(self.provider.rawValue)")
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
                    .font(self.theme.typography.caption).foregroundStyle(self.needsLanguage ? Color.red : self.theme.palette.secondaryText)
            }
            if !self.info.sendsLanguageChoice {
                Text("\(self.info.name) detects the language on its own; language choices are not sent.")
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            }
            ForEach(self.unlistedLanguageWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(self.theme.typography.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Like the Cleanup Styles prompt test: the user's own dictation shortcut records, and the result shows here.
    private var testGroup: some View {
        FluidManagementGroup(title: "Test") {
            if self.isTestArmed {
                Label("Press your dictation shortcut, speak for a few seconds, then stop.", systemImage: "mic.circle")
                Button("Stop testing") { self.test.disarm() }
                    .fluidGlassAction()
                    .accessibilityIdentifier("live-cloud-stop-test-\(self.provider.rawValue)")
            } else {
                Button("Test with your dictation shortcut") { self.test.arm(self.provider) }
                    .fluidGlassAction()
                    .disabled(!self.hasKey || self.needsLanguage || self.viewModel.areSpeechModelActionsBlocked || self.isChecking)
                    .help(
                        !self.hasKey
                            ? "Add an API key in AI Providers first."
                            : self.needsLanguage
                            ? "Choose a Primary language under Dictation language first."
                            : "The next dictation uses \(self.info.name) and shows its text here."
                    )
                    .accessibilityIdentifier("live-cloud-test-\(self.provider.rawValue)")
            }
            if self.isTestArmed, !self.test.lastTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcript").font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                    Text(self.test.lastTranscript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                if let latency = self.test.lastLatencyMilliseconds, self.test.lastError.isEmpty {
                    Label(String(format: "Final text %.2f s after you stopped", Double(latency) / 1000), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
            if self.isTestArmed, !self.test.lastError.isEmpty {
                Text(self.test.lastError).foregroundStyle(.red).textSelection(.enabled)
            }
            Text("Nothing is typed or saved. A test uses a few seconds of \(self.info.name) usage. Testing doesn't change your voice engine.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
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

    private var activateHelp: String {
        if !self.hasKey { return "Add an API key in AI Providers first." }
        if self.needsLanguage { return "Choose a Primary language under Dictation language first." }
        if self.viewModel.areSpeechModelActionsBlocked { return "Finish the current recording first." }
        return "Use this provider for dictation. The key is checked first."
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if self.isActive {
                    VoiceEngineActiveCapsule()
                } else {
                    Button(self.viewModel.liveProviderBeingChecked == self.provider ? "Checking…" : "Activate") {
                        Task { await self.viewModel.activateLiveProvider(self.provider) }
                    }
                    .fluidGlassAction(prominent: true)
                    .disabled(!self.hasKey || self.needsLanguage || self.viewModel.areSpeechModelActionsBlocked || self.isChecking)
                    .help(self.activateHelp)
                    .accessibilityIdentifier("live-cloud-activate-\(self.provider.rawValue)")
                }
                Spacer()
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
