import SwiftUI

/// The Live cloud tab: the providers the user added, never the whole catalog (UX Design 1).
struct LiveCloudSettingsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    /// Rows show "Tested" as soon as a test passes in the Manage sheet.
    @ObservedObject private var test = LiveProviderTestCoordinator.shared
    @State private var isAddingProvider = false
    @State private var providerToManageAfterAdding: LiveTranscriptionProviderID?
    @State private var managedProvider: LiveTranscriptionProviderID?

    private var added: [LiveTranscriptionProviderID] { LiveTranscriptionPreferences(defaults: .standard).addedProviders }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            self.content
                .padding(16)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        }
        .sheet(isPresented: self.$isAddingProvider, onDismiss: self.openManageSheetAfterAdding) {
            AddLiveProviderSheet(added: Set(self.added)) { provider in
                self.viewModel.addLiveProvider(provider)
                self.providerToManageAfterAdding = provider
                self.isAddingProvider = false
            }
        }
        .sheet(item: self.$managedProvider) { provider in
            LiveCloudProviderSheet(provider: provider, settings: self.settings, viewModel: self.viewModel)
        }
        .onChange(of: self.settings.cloudTranscriptionPrimaryLanguageCode) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
        .onChange(of: self.settings.cloudTranscriptionSecondaryLanguageCode) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Live cloud providers").font(.headline)
                Spacer()
                Button("Add provider", systemImage: "plus") { self.isAddingProvider = true }
                    .fluidGlassAction()
                    .disabled(self.added.count == LiveTranscriptionCatalog.all.count)
                    .accessibilityIdentifier("live-cloud-add-provider")
            }
            Text("Words appear while you speak; the final text arrives moments after you stop. Audio streams to the provider while you record. Each provider uses your own API key.")
                .font(.callout).foregroundStyle(.secondary)
            if self.added.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No live providers yet.")
                    Text("Add one to try it. Adding a provider won't change your voice engine.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(self.added) { provider in
                        self.row(for: provider)
                    }
                }
            }
            if !self.settings.enableStreamingPreview {
                Text("Turn on Live Preview in Settings › Overlay to see words while you speak.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            FailedDictationRecoveryControls(
                viewModel: self.viewModel,
                hasFailedRecording: self.viewModel.asr.failedLiveProvider != nil,
                liveProviderName: self.viewModel.asr.failedLiveProvider.map { LiveTranscriptionCatalog.info(for: $0).name }
            )
            Divider()
            DictationLanguageControls(
                settings: self.settings,
                caption: "Shared with OpenRouter. Dictation detects the language automatically; choose Primary or Secondary while recording to override it."
            )
            Text("Live providers handle dictation, commands and rewrite. Imported files and the local API use your selected local model.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Cleanup Styles run after the transcript arrives, using your AI Providers, the same as local models.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(for provider: LiveTranscriptionProviderID) -> some View {
        let info = LiveTranscriptionCatalog.info(for: provider)
        let isActive = self.settings.activeLiveProvider == provider
        let hasKey = !self.settings.liveTranscriptionAPIKey(for: provider).isEmpty
        let needsLanguage = self.settings.liveProviderNeedsPrimaryLanguage(provider)
        let isProblem = !hasKey || needsLanguage || self.viewModel.liveRejectedKeys.contains(provider)
        return HStack(spacing: 12) {
            LiveProviderBadge(name: info.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(self.theme.typography.bodyStrong)
                Text(self.statusLine(for: provider, info: info, hasKey: hasKey))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(isProblem ? Color.red : Color.secondary)
                if let message = self.viewModel.liveActivationStatus[provider] {
                    Text(message)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if isActive {
                Text("Active")
                    .font(self.theme.typography.bodySmallStrong)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.fluidGreen.opacity(0.25)))
                    .foregroundStyle(Color.fluidGreen)
            } else {
                Button(self.viewModel.liveProviderBeingChecked == provider ? "Checking…" : "Activate") {
                    Task { await self.viewModel.activateLiveProvider(provider) }
                }
                .fluidGlassAction(quiet: true)
                .disabled(!hasKey || needsLanguage || self.viewModel.areSpeechModelActionsBlocked || self.viewModel.liveProviderBeingChecked != nil)
                .help(self.activateHelp(hasKey: hasKey, needsLanguage: needsLanguage))
            }
            Button("Manage") { self.managedProvider = provider }
                .fluidGlassAction(quiet: true)
                .accessibilityIdentifier("live-cloud-manage-\(provider.rawValue)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isActive ? Color.fluidGreen.opacity(0.9) : .clear, lineWidth: 2)
                )
        )
        .accessibilityIdentifier("live-cloud-row-\(provider.rawValue)")
    }

    private func activateHelp(hasKey: Bool, needsLanguage: Bool) -> String {
        if !hasKey { return "Save an API key first." }
        if needsLanguage { return "Choose a Primary language under Dictation language first." }
        if self.viewModel.areSpeechModelActionsBlocked { return "Finish the current recording first." }
        return "Use this provider for dictation. The key is checked first."
    }

    private func statusLine(for provider: LiveTranscriptionProviderID, info: LiveTranscriptionProviderInfo, hasKey: Bool) -> String {
        guard hasKey else { return "API key missing" }
        // UX §E4: a provider without automatic detection cannot run until a Primary language is set.
        if self.settings.liveProviderNeedsPrimaryLanguage(provider) { return "Needs a Primary language" }
        let modelID = LiveTranscriptionPreferences(defaults: .standard).modelID(for: provider)
        let model = info.models.first { $0.id == modelID }?.name ?? modelID
        if self.viewModel.liveProviderBeingChecked == provider { return "\(model) · Checking…" }
        if self.viewModel.liveRejectedKeys.contains(provider) { return "\(model) · Key rejected" }
        return "\(model) · \(self.test.hasPassed(provider) ? "Tested" : "Not tested")"
    }

    /// The Manage sheet opens once the Add sheet is gone; macOS drops a sheet presented while another dismisses.
    private func openManageSheetAfterAdding() {
        guard let provider = self.providerToManageAfterAdding else { return }
        self.providerToManageAfterAdding = nil
        self.managedProvider = provider
    }
}

/// The initials badge the AI Providers list uses for providers without a logo asset.
struct LiveProviderBadge: View {
    let name: String

    var body: some View {
        Text(String(self.name.split(separator: " ").prefix(2).compactMap(\.first)))
            .font(.fluidSystem(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.75))
            .frame(width: 38, height: 38)
            .background(Color(red: 0.9, green: 0.9, blue: 0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}
