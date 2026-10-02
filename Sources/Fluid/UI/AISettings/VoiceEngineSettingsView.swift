import SwiftUI

struct VoiceEngineSettingsView: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) var colorScheme
    @State var isShowingNemotronLanguagePicker = false
    @State var isShowingWhisperLanguagePicker = false
    @State var whisperLanguageSearchText = ""
    let theme: AppTheme

    var voiceEngineTitleText: Color {
        Color(nsColor: .labelColor)
    }

    var voiceEngineSecondaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.90) : self.theme.palette.primaryText.opacity(0.82)
    }

    var voiceEngineTertiaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.85) : self.theme.palette.secondaryText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.header
            // Tabs only browse; each tab's Activate changes the engine. The active one carries a check mark.
            Picker("Provider settings", selection: self.$viewModel.browsedSpeechExecutionSource) {
                ForEach(SpeechExecutionSource.allCases) { source in
                    let isActive = source == self.settings.speechExecutionSource
                    Text(Self.tabTitle(for: source, isActive: isActive))
                        .accessibilityLabel(isActive ? "\(source.displayName), active" : source.displayName)
                        .tag(source)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("voice-engine-provider-tabs")
            switch self.viewModel.browsedSpeechExecutionSource {
            case .cloud: CloudTranscriptionSettingsView(settings: self.settings, viewModel: self.viewModel)
            case .liveCloud: LiveCloudSettingsView(settings: self.settings, viewModel: self.viewModel)
            case .local: self.speechRecognitionCard
            }
        }
            .onAppear {
                self.viewModel.onAppear(
                    requestedTab: AppNavigationRouter.shared.consumeRequestedVoiceEngineTab(),
                    requestedCloudProviderID: AppNavigationRouter.shared.consumeRequestedCloudProviderID()
                )
            }
            // Already on Voice Engine: a request for one of its tabs switches the browsed tab.
            .onReceive(NotificationCenter.default.publisher(for: .appNavigationRequested)) { _ in
                if let tab = AppNavigationRouter.shared.consumeRequestedVoiceEngineTab() {
                    self.viewModel.browsedSpeechExecutionSource = tab
                }
                if let providerID = AppNavigationRouter.shared.consumeRequestedCloudProviderID() {
                    self.viewModel.browsedCloudProviderID = providerID
                }
            }
            .onChange(of: self.settings.speechExecutionSource) { _, _ in
                self.viewModel.asr.resetTranscriptionProvider()
            }
            .onChange(of: self.settings.selectedSpeechModel) { _, newValue in
                self.viewModel.handleSelectedSpeechModelChange(newValue)
            }
    }

    /// A segmented picker carries one text per segment, so the active engine's title gets a check mark.
    static func tabTitle(for source: SpeechExecutionSource, isActive: Bool) -> String {
        isActive ? "\(source.displayName) ✓" : source.displayName
    }

    /// "Active voice engine: …", with a way to the missing key when the engine's provider has none (VE-2).
    private var header: some View {
        let status = self.settings.voiceEngineStatus
        return HStack(spacing: 12) {
            Label(
                "Active voice engine: \(status.description)",
                systemImage: status.missingKeyProviderID == nil ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
            .font(.callout)
            .foregroundStyle(status.missingKeyProviderID == nil ? Color.primary : Color.red)
            .accessibilityIdentifier("active-voice-engine")
            if let providerID = status.missingKeyProviderID {
                Button("Open AI Providers") {
                    AppNavigationRouter.shared.request(.aiProvider(id: providerID, origin: .voiceEngine(tab: status.tab)))
                }
                .fluidGlassAction(quiet: true)
                .accessibilityIdentifier("active-voice-engine-open-ai-providers")
            }
        }
    }
}
