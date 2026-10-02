import SwiftUI

/// Which live providers the Live cloud tab lists as connected: those with a saved key, plus the stored
/// active provider even when its key is gone. Every other live provider is "Not set up".
enum LiveCloudProviderGroups {
    static func make(
        hasKey: (LiveTranscriptionProviderID) -> Bool,
        activeProvider: LiveTranscriptionProviderID?
    ) -> (connected: [LiveTranscriptionProviderID], notSetUp: [LiveTranscriptionProviderID]) {
        let all = LiveTranscriptionCatalog.all.map(\.id)
        let connected = all.filter { hasKey($0) || $0 == activeProvider }
        return (connected, all.filter { !connected.contains($0) })
    }
}

/// The Live cloud tab: connected providers first, then every other live provider under "Not set up",
/// each linking to AI Providers, where keys are entered.
struct LiveCloudSettingsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    /// Rows show "Tested" as soon as a test passes in the Manage sheet.
    @ObservedObject private var test = LiveProviderTestCoordinator.shared
    @State private var managedProvider: LiveTranscriptionProviderID?
    @State private var showsAllNotSetUp = false

    private var groups: (connected: [LiveTranscriptionProviderID], notSetUp: [LiveTranscriptionProviderID]) {
        LiveCloudProviderGroups.make(
            hasKey: { !self.settings.liveTranscriptionAPIKey(for: $0).isEmpty },
            activeProvider: self.settings.activeLiveProvider
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            self.content
                .padding(16)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        }
        .sheet(item: self.$managedProvider) { provider in
            LiveCloudProviderSheet(provider: provider, settings: self.settings, viewModel: self.viewModel)
        }
        .onChange(of: self.settings.cloudTranscriptionPrimaryLanguageCode) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
        .onChange(of: self.settings.cloudTranscriptionSecondaryLanguageCode) { _, _ in self.viewModel.asr.resetTranscriptionProvider() }
    }

    private var content: some View {
        let groups = self.groups
        return VStack(alignment: .leading, spacing: 16) {
            Text("Live cloud providers").font(.headline)
            Text("Words appear while you speak; the final text arrives moments after you stop. Audio streams to the provider while you record. Each provider uses your own API key, entered in AI Providers.")
                .font(.callout).foregroundStyle(.secondary)
            if groups.connected.isEmpty {
                Text("No live provider is connected yet. Setting one up won't change your voice engine.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(groups.connected) { provider in
                        self.row(for: provider)
                    }
                }
            }
            if !groups.notSetUp.isEmpty {
                self.notSetUpGroup(groups.notSetUp, expanded: groups.connected.isEmpty || self.showsAllNotSetUp)
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
                caption: "Shared with Cloud. Dictation detects the language automatically; choose Primary or Secondary while recording to override it."
            )
            Text("Live providers handle dictation, commands and rewrite. Imported files and the local API use your selected local model.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Cleanup Styles run after the transcript arrives, using your AI Providers, the same as local models.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Expanded when nothing is connected, otherwise behind "Show N more providers".
    @ViewBuilder
    private func notSetUpGroup(_ providers: [LiveTranscriptionProviderID], expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not set up").font(self.theme.typography.bodySmallStrong).foregroundStyle(.secondary)
            if expanded {
                ForEach(providers) { provider in
                    self.notSetUpRow(for: provider)
                }
            } else {
                Button("Show \(providers.count) more providers") { self.showsAllNotSetUp = true }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("live-cloud-show-not-set-up")
            }
        }
    }

    private func notSetUpRow(for provider: LiveTranscriptionProviderID) -> some View {
        let info = LiveTranscriptionCatalog.info(for: provider)
        return HStack(spacing: 12) {
            LiveProviderBadge(name: info.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(self.theme.typography.bodyStrong)
                Text("Needs an API key").font(self.theme.typography.bodySmall).foregroundStyle(.secondary)
            }
            Spacer()
            self.setUpButton(for: provider)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(self.theme.palette.cardBorder.opacity(0.25), lineWidth: 1))
        .accessibilityIdentifier("live-cloud-not-set-up-\(provider.rawValue)")
    }

    private func setUpButton(for provider: LiveTranscriptionProviderID) -> some View {
        Button("Set up in AI Providers") {
            AppNavigationRouter.shared.request(.aiProvider(
                id: ProviderRegistry.providerID(for: provider),
                origin: .voiceEngine(tab: .liveCloud)
            ))
        }
        .fluidGlassAction(quiet: true)
        .accessibilityIdentifier("live-cloud-set-up-\(provider.rawValue)")
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
                Label(self.statusLine(for: provider, info: info, hasKey: hasKey), systemImage: self.statusIcon(for: provider, hasKey: hasKey))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(isProblem ? Color.red : Color.secondary)
                if let message = self.viewModel.liveActivationStatus[provider] {
                    Text(message)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if self.viewModel.liveRejectedKeys.contains(provider) {
                    Button("Update key in AI Providers") {
                        AppNavigationRouter.shared.request(.aiProvider(
                            id: ProviderRegistry.providerID(for: provider),
                            origin: .voiceEngine(tab: .liveCloud)
                        ))
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("live-cloud-update-key-\(provider.rawValue)")
                }
            }
            Spacer()
            if isActive, !hasKey {
                self.setUpButton(for: provider)
            }
            if isActive {
                VoiceEngineActiveCapsule()
            } else if !hasKey {
                self.setUpButton(for: provider)
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
        if !hasKey { return "Add an API key in AI Providers first." }
        if needsLanguage { return "Choose a Primary language under Dictation language first." }
        if self.viewModel.areSpeechModelActionsBlocked { return "Finish the current recording first." }
        return "Use this provider for dictation. The key is checked first."
    }

    /// The icon the status badge uses for the matching state: a problem, tested, or not tested yet.
    private func statusIcon(for provider: LiveTranscriptionProviderID, hasKey: Bool) -> String {
        if !hasKey || self.settings.liveProviderNeedsPrimaryLanguage(provider) { return "exclamationmark.circle" }
        if self.viewModel.liveRejectedKeys.contains(provider) { return "exclamationmark.circle.fill" }
        if self.viewModel.liveProviderBeingChecked == provider { return "arrow.triangle.2.circlepath" }
        return self.test.hasPassed(provider) ? "checkmark.circle.fill" : "circle.dashed"
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
