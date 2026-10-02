import AppKit
import SwiftUI

/// Retry, Transcribe locally or Discard for a cloud dictation that failed and kept its recording.
/// Shown in the tab that owns the failed engine. It stays in place after the recording is gone so
/// the retry progress and the "copied" status remain visible.
struct FailedDictationRecoveryControls: View {
    @ObservedObject var viewModel: VoiceEngineSettingsViewModel
    /// True while a failed recording of this tab's engine is waiting.
    let hasFailedRecording: Bool
    /// Names the live provider in retry errors; nil for the Cloud tab, which names its own provider.
    var liveProviderName: String?
    @State private var retryTask: Task<Void, Never>?
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.hasFailedRecording {
                HStack {
                    Button("Retry and copy") { self.retryDictation(useLocal: false) }
                    Button("Transcribe locally and copy") { self.retryDictation(useLocal: true) }
                    Button("Discard recording", role: .destructive) { self.viewModel.asr.discardFailedCloudDictation() }
                }
                .disabled(self.viewModel.areSpeechModelActionsBlocked || self.retryTask != nil)
            }
            if self.retryTask != nil {
                HStack {
                    ProgressView("Transcribing saved recording…").controlSize(.small)
                    Button("Cancel retry") { self.retryTask?.cancel() }
                }
            }
            if !self.status.isEmpty {
                Text(self.status).font(.callout).textSelection(.enabled)
            }
        }
        .onDisappear { self.retryTask?.cancel() }
    }

    private func retryDictation(useLocal: Bool) {
        guard self.retryTask == nil else { return }
        self.status = ""
        // Read before the retry: a successful retry discards the failed recording.
        let providerName = self.viewModel.asr.failedCloudProviderName
        self.retryTask = Task { @MainActor in
            defer { self.retryTask = nil }
            do {
                let text = try await self.viewModel.asr.retryFailedCloudDictation(useLocal: useLocal)
                try Task.checkCancellation()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.status = "Transcript copied. Paste it into your document."
            } catch is CancellationError {
                self.status = "Retry cancelled."
            } catch let error as LiveTranscriptionError {
                self.status = error.message(providerName: self.liveProviderName ?? "The live provider")
            } catch let error as CloudTranscriptionError {
                self.status = error.message(providerName: providerName ?? CloudTranscriptionCatalog.openRouterName)
            } catch {
                self.status = error.localizedDescription
            }
        }
    }
}
