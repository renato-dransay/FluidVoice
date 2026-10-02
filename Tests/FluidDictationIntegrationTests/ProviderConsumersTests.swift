@testable import FluidVoice_Debug
import XCTest

/// The screens that consume a provider without connecting one (section 12): File Transcription's engine
/// line, the Dashboard's missing-key message and the meeting summary key source.
@MainActor
final class ProviderConsumersTests: XCTestCase {
    // MARK: - File Transcription engine line (FT-1)

    private func line(_ engine: SpeechExecutionSource, provider: String = "openrouter", model: String = "") -> FileTranscriptionEngineLine {
        FileTranscriptionEngineLine.make(engine: engine, localModelName: "Parakeet TDT v3", cloudProviderID: provider, cloudModelID: model)
    }

    func testLocalNamesTheLocalModelAndChangesOnTheLocalTab() {
        XCTAssertEqual(self.line(.local), FileTranscriptionEngineLine(text: "Transcribes with Local · Parakeet TDT v3.", tab: .local))
    }

    func testOpenRouterNamesItsSpeechModel() {
        XCTAssertEqual(
            self.line(.cloud, model: CloudTranscriptionModel.defaultDictationID),
            FileTranscriptionEngineLine(text: "Transcribes with OpenRouter · Whisper Large v3 Turbo.", tab: .cloud)
        )
    }

    func testAnotherCloudProviderWithWordTimingsKeepsSpeakerLabels() {
        XCTAssertEqual(
            self.line(.cloud, provider: "deepgram", model: "nova-3"),
            FileTranscriptionEngineLine(text: "Transcribes with Deepgram · Nova-3.", tab: .cloud)
        )
    }

    func testACloudModelWithoutWordTimingsSaysFilesHaveNoSpeakerLabels() {
        XCTAssertEqual(
            self.line(.cloud, provider: "mistral", model: "voxtral-mini-latest"),
            FileTranscriptionEngineLine(text: "Transcribes with Mistral · Voxtral Mini. Without speaker labels.", tab: .cloud)
        )
    }

    func testLiveCloudSaysFilesUseTheLocalModel() {
        let line = self.line(.liveCloud, provider: "deepgram", model: "nova-3")
        XCTAssertEqual(
            line.text,
            "Transcribes with Local · Parakeet TDT v3. Live cloud handles dictation only, so files use the selected local model."
        )
        XCTAssertEqual(line.tab, .local, "Change opens the tab where the model files use is chosen")
    }

    // MARK: - Dashboard (DASH-1)

    func testAMissingKeyForAnyCloudProviderIsNamed() {
        let status = VoiceEngineStatus.make(storedSource: .cloud, cloudProviderID: "deepgram", storedLiveProvider: nil, speechKey: { _ in "" })
        XCTAssertEqual(status.missingKeyMessage, "Deepgram key required")
        XCTAssertEqual(status.missingKeyProviderID, "deepgram")
    }

    // MARK: - Meeting summary (SUM-1)

    func testTheSummaryErrorPointsToAIProviders() {
        XCTAssertEqual(
            MeetingCloudSummaryError.emptyResponse.localizedDescription,
            "The AI provider returned an empty summary. Try again or choose another model in AI Providers."
        )
    }
}
