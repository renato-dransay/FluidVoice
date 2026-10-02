import Foundation

/// The line at the top of File Transcription that says what an imported file is transcribed with,
/// and the Voice Engine tab its `Change` button opens (FT-1).
struct FileTranscriptionEngineLine: Equatable {
    let text: String
    let tab: SpeechExecutionSource

    /// - Parameters:
    ///   - engine: the engine dictation really uses (`SettingsStore.speechExecutionSource`).
    ///   - localModelName: the selected local speech model.
    ///   - cloudProviderID: the active Cloud provider.
    ///   - cloudModelID: that provider's speech model.
    static func make(
        engine: SpeechExecutionSource,
        localModelName: String,
        cloudProviderID: String,
        cloudModelID: String
    ) -> FileTranscriptionEngineLine {
        switch engine {
        case .local:
            return FileTranscriptionEngineLine(text: "Transcribes with Local · \(localModelName).", tab: .local)
        case .liveCloud:
            // Live cloud streams dictation only; imported files keep using the selected local model.
            return FileTranscriptionEngineLine(
                text: "Transcribes with Local · \(localModelName). Live cloud handles dictation only, so files use the selected local model.",
                tab: .local
            )
        case .cloud:
            let model = CloudTranscriptionCatalog.models(for: cloudProviderID).first { $0.id == cloudModelID }
            let providerName = VoiceEngineStatus.providerName(cloudProviderID)
            var text = "Transcribes with \(providerName) · \(model?.name ?? cloudModelID)."
            // Mirrors the service: a model whose provider documents no word timings drops speaker labels.
            let speakerLabels = FileTranscriptionService.cloudSpeakerLabels(
                requested: true,
                cloudProviderID: cloudProviderID,
                supportsWordTimings: model?.supportsWordTimings ?? false
            )
            if speakerLabels == .droppedForModel {
                text += " Without speaker labels."
            }
            return FileTranscriptionEngineLine(text: text, tab: .cloud)
        }
    }
}

extension SettingsStore {
    /// What File Transcription transcribes with now.
    var fileTranscriptionEngineLine: FileTranscriptionEngineLine {
        let configuration = self.cloudTranscriptionConfiguration
        return FileTranscriptionEngineLine.make(
            engine: self.speechExecutionSource,
            localModelName: self.selectedSpeechModel.displayName,
            cloudProviderID: configuration.providerID,
            cloudModelID: configuration.modelID
        )
    }
}
