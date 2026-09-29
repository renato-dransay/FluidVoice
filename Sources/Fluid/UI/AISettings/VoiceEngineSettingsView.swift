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
            Label("Active voice engine: \(self.settings.speechExecutionSource.displayName)", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .accessibilityIdentifier("active-voice-engine")
            Picker("Provider settings", selection: self.$viewModel.browsedSpeechExecutionSource) {
                ForEach(SpeechExecutionSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("voice-engine-provider-tabs")
            Text("Tabs show provider settings. Use the OpenRouter switch or activate a local model to change the voice engine.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if self.viewModel.browsedSpeechExecutionSource == .openRouter {
                OpenRouterTranscriptionSettingsView(settings: self.settings, viewModel: self.viewModel)
            } else {
                self.speechRecognitionCard
            }
        }
            .onAppear { self.viewModel.onAppear() }
            .onChange(of: self.settings.speechExecutionSource) { _, _ in
                self.viewModel.asr.resetTranscriptionProvider()
            }
            .onChange(of: self.settings.selectedSpeechModel) { _, newValue in
                self.viewModel.handleSelectedSpeechModelChange(newValue)
            }
    }
}
