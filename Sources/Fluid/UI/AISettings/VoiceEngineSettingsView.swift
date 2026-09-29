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
            Picker("Transcription", selection: self.$settings.speechExecutionSource) {
                ForEach(SpeechExecutionSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(self.viewModel.areSpeechModelActionsBlocked)
            if self.settings.usesCloudTranscription {
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
