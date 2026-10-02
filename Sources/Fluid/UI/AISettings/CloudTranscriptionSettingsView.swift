import SwiftUI

/// The Cloud tab of Voice Engine (VE-5): pick a connected Cloud transcription provider, see its
/// connection, choose its models and activate it. Keys are entered in AI Providers.
struct CloudTranscriptionSettingsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject private var usage = CloudTranscriptionUsageStore.shared

    var body: some View {
        let groups = self.viewModel.cloudProviderGroups
        let shown = self.viewModel.shownCloudProviderID
        return VStack(alignment: .leading, spacing: 16) {
            Text("Cloud voice engine").font(.headline)
            Text("Your recording is sent to the provider when you stop. The provider may keep it under its own policy.")
                .font(.callout).foregroundStyle(.secondary)

            self.providerMenu(groups: groups, shown: shown)
            if let shown {
                self.connectionLine(for: shown)
                self.modelControls(for: shown)
                    .disabled(self.viewModel.areSpeechModelActionsBlocked || self.viewModel.cloudProviderBeingChecked != nil)
                if shown == CloudTranscriptionPreferences.defaultProviderID {
                    self.refreshModelsControl
                }
            } else {
                Text("No cloud provider is connected.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            DictationLanguageControls(
                settings: self.settings,
                caption: "Dictation detects any language automatically. Choose Primary or Secondary while recording to override detection; the choice is remembered."
            )
            .disabled(self.viewModel.areSpeechModelActionsBlocked || self.viewModel.cloudProviderBeingChecked != nil)
            if let shown {
                Divider()
                self.activationRow(for: shown)
            }
            FailedDictationRecoveryControls(viewModel: self.viewModel, hasFailedRecording: self.viewModel.asr.hasFailedCloudDictation)
            if let shown {
                self.usageSummary(for: shown)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .task { await self.viewModel.refreshOpenRouterCatalog(force: false) }
        .onChange(of: self.settings.cloudTranscriptionModelID) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
        .onChange(of: self.settings.activeCloudTranscriptionModelID) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
        .onChange(of: self.settings.cloudDictationModelID) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
        .onChange(of: self.settings.cloudTranscriptionPrimaryLanguageCode) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
        .onChange(of: self.settings.cloudTranscriptionSecondaryLanguageCode) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
    }

    // MARK: - Provider

    /// Connected providers first (the active one marked), then every other Cloud transcription provider,
    /// which opens AI Providers. Choosing a connected provider only changes which settings are shown.
    private func providerMenu(groups: (connected: [ProviderDescriptor], notSetUp: [ProviderDescriptor]), shown: String?) -> some View {
        HStack(spacing: 12) {
            Text("Provider")
            Menu(shown.map(VoiceEngineStatus.providerName) ?? "Set up a provider") {
                ForEach(groups.connected) { provider in
                    Button(self.menuTitle(for: provider)) { self.viewModel.browsedCloudProviderID = provider.id }
                }
                if !groups.connected.isEmpty, !groups.notSetUp.isEmpty {
                    Divider()
                }
                ForEach(groups.notSetUp) { provider in
                    Button("\(provider.name): set up…") {
                        AppNavigationRouter.shared.request(.aiProvider(id: provider.id, origin: .voiceEngine(tab: .cloud)))
                    }
                }
            }
            .fixedSize()
            .accessibilityIdentifier("cloud-provider-menu")
        }
    }

    private func menuTitle(for provider: ProviderDescriptor) -> String {
        self.viewModel.isActiveCloudProvider(provider.id) ? "\(provider.name) · Active" : provider.name
    }

    /// The speech status of the shown provider and the way to its key.
    private func connectionLine(for providerID: String) -> some View {
        HStack(spacing: 12) {
            ProviderStatusBadge(status: self.viewModel.cloudProviderStatus(for: providerID))
            Spacer()
            Button("Manage in AI Providers") {
                AppNavigationRouter.shared.request(.aiProvider(id: providerID, origin: .voiceEngine(tab: .cloud)))
            }
            .fluidGlassAction(quiet: true)
            .accessibilityIdentifier("cloud-manage-\(providerID)")
        }
    }

    @ViewBuilder
    private func modelControls(for providerID: String) -> some View {
        if providerID == CloudTranscriptionPreferences.defaultProviderID {
            OpenRouterModelControls(settings: self.settings, viewModel: self.viewModel)
        } else {
            CloudSpeechModelControls(settings: self.settings, providerID: providerID)
        }
    }

    /// The forced catalog refresh and listing check. It decides which OpenRouter models are selectable.
    private var refreshModelsControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Refresh models") { Task { await self.viewModel.refreshOpenRouterModels() } }
                    .fluidGlassAction(quiet: true)
                    .disabled(self.viewModel.isEngineCheckRunning || self.settings.openRouterTranscriptionAPIKey.isEmpty)
                    .help("Fetch OpenRouter's models again and check which ones this key can use.")
                    .accessibilityIdentifier("openrouter-refresh-models")
                if self.viewModel.cloudProviderBeingChecked == CloudTranscriptionPreferences.defaultProviderID {
                    ProgressView().controlSize(.small)
                }
            }
            if let result = self.viewModel.cloudRefreshResult {
                ProviderActionResultLabel(result: result)
            }
        }
    }

    // MARK: - Activation

    private func activationRow(for providerID: String) -> some View {
        let name = VoiceEngineStatus.providerName(providerID)
        let isActive = self.viewModel.isActiveCloudProvider(providerID)
        let blocker = self.viewModel.cloudActivationBlocker(for: providerID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if isActive {
                    VoiceEngineActiveCapsule()
                    Button("Use local model instead") { self.viewModel.useLocalModelInstead() }
                        .fluidGlassAction(quiet: true)
                        .disabled(self.viewModel.areSpeechModelActionsBlocked)
                        .help(self.viewModel.areSpeechModelActionsBlocked
                            ? "Finish the current recording first."
                            : "Dictation and imported files use your selected local model.")
                        .accessibilityIdentifier("cloud-use-local-model")
                } else {
                    Button(self.viewModel.cloudProviderBeingChecked == providerID ? "Checking…" : "Activate") {
                        Task { await self.viewModel.activateCloudProvider(providerID) }
                    }
                    .fluidGlassAction(prominent: true)
                    .disabled(blocker != nil)
                    .help(blocker ?? "Use \(name) for dictation. The key and models are checked first.")
                    .accessibilityIdentifier("cloud-activate-\(providerID)")
                }
            }
            if !isActive, let blocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
            if let message = self.viewModel.cloudActivationStatus[providerID] {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if self.viewModel.cloudRejectedKeys.contains(providerID) {
                    Button("Update key in AI Providers") {
                        AppNavigationRouter.shared.request(.aiProvider(id: providerID, origin: .voiceEngine(tab: .cloud)))
                    }
                    .fluidGlassAction(quiet: true)
                }
            }
            if VoiceEngineSettingsViewModel.showsVerifiedTextProviderHint(
                providerID: providerID,
                verifiedTextProviderKeys: Array(self.settings.verifiedProviderFingerprints.keys),
                isTextVerified: self.settings.isCommandModeProviderVerified
            ) {
                HStack(spacing: 8) {
                    Text("Cleanup Styles need a verified text provider.").font(.caption).foregroundStyle(.secondary)
                    Button("Open AI Providers") { AppNavigationRouter.shared.request(.aiEnhancements) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: - Usage

    /// The recorded cost exists for OpenRouter only; every provider links to its own usage page.
    @ViewBuilder
    private func usageSummary(for providerID: String) -> some View {
        if providerID == CloudTranscriptionPreferences.defaultProviderID {
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
        }
        if let usageURL = ProviderRegistry.descriptor(for: providerID)?.usageURL {
            Link("\(VoiceEngineStatus.providerName(providerID)) usage and billing", destination: usageURL)
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
}

/// The one "Speech model" picker of a Cloud provider other than OpenRouter, from its catalog (CLD-4).
struct CloudSpeechModelControls: View {
    @ObservedObject var settings: SettingsStore
    let providerID: String

    var body: some View {
        let selectedID = self.settings.cloudTranscriptionModelID(for: self.providerID)
        let supportsWordTimings = CloudTranscriptionCatalog.models(for: self.providerID).first { $0.id == selectedID }?.supportsWordTimings ?? false
        VStack(alignment: .leading, spacing: 8) {
            SpeechModelPickerRow(
                title: "Speech model",
                items: SpeechModelPickerItems.cloud(providerID: self.providerID, selected: selectedID),
                selection: self.selection,
                accessibilityIdentifier: "cloud-speech-model-\(self.providerID)"
            )
            ForEach(VoiceEngineSettingsViewModel.cloudSpeechModelCaptions(providerID: self.providerID, supportsWordTimings: supportsWordTimings), id: \.self) { caption in
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { self.settings.cloudTranscriptionModelID(for: self.providerID) },
            set: { self.settings.setCloudTranscriptionModelID($0, for: self.providerID) }
        )
    }
}

/// A label and the shared searchable model picker, as every speech model choice in Voice Engine shows it.
struct SpeechModelPickerRow: View {
    let title: String
    let items: [SearchableModelPickerItem]
    @Binding var selection: String
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 12) {
            Text(self.title)
            SearchableModelPicker(
                items: self.items,
                selectedModel: self.$selection,
                controlWidth: 280,
                popoverWidth: 340,
                accessibilityIdentifier: self.accessibilityIdentifier
            )
            Spacer(minLength: 0)
        }
    }
}

/// OpenRouter's two models: the speech model (transcription endpoint) and the style model (hears the
/// recording and applies the Cleanup Style in one request). Shared by the Cloud tab and onboarding.
struct OpenRouterModelControls: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.speechModelControls
            self.styleModelControls
            self.dictationRouteStatus
        }
    }

    /// Dictation without a Cleanup Style, imported files, the local API and the voice command and
    /// rewrite modes all run on the speech model, on the transcription endpoint.
    @ViewBuilder
    private var speechModelControls: some View {
        SpeechModelPickerRow(
            title: "Speech model",
            items: SpeechModelPickerItems.openRouterSpeech(
                models: self.viewModel.openRouterSpeechModels,
                selected: self.settings.cloudTranscriptionModelID,
                validatedIDs: self.viewModel.hasValidatedOpenRouterSpeechModels ? self.viewModel.validatedOpenRouterSpeechModelIDs : nil
            ),
            selection: self.$settings.cloudTranscriptionModelID,
            accessibilityIdentifier: "openrouter-transcription-model"
        )
        Text("Turns speech into text. Used for dictation, imported files and voice commands.")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Only a dictation with a Cleanup Style reaches the style model, an audio chat model that
    /// hears the recording and writes it in that style.
    @ViewBuilder
    private var styleModelControls: some View {
        SpeechModelPickerRow(
            title: "Style model",
            items: SpeechModelPickerItems.openRouterStyle(
                models: self.viewModel.openRouterStyleModels,
                automaticName: self.modelName(self.automaticModelID),
                validatedIDs: self.viewModel.hasValidatedOpenRouterStyleModels ? self.viewModel.validatedOpenRouterStyleModelIDs : nil
            ),
            selection: self.$settings.cloudDictationModelSelection,
            accessibilityIdentifier: "openrouter-audio-dictation-model"
        )
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
        return self.viewModel.openRouterSpeechModels.first { $0.id == id }?.name ?? id
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
}

/// The green capsule an active voice engine shows in every tab, where the others show `Activate`.
struct VoiceEngineActiveCapsule: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("Active")
            .font(self.theme.typography.bodySmallStrong)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.fluidGreen.opacity(0.25)))
            .foregroundStyle(Color.fluidGreen)
            .accessibilityIdentifier("voice-engine-active")
    }
}
