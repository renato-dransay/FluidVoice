import SwiftUI

/// Cloud setup remains optional; opening this sheet does not change the active voice engine.
struct OnboardingCloudTranscriptionSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var viewModel: VoiceEngineSettingsViewModel
    @State private var errorMessage: String?
    @State private var isActivating = false
    @State private var activationTask: Task<Void, Never>?

    init(appServices: AppServices) {
        self._viewModel = StateObject(wrappedValue: VoiceEngineSettingsViewModel(
            settings: SettingsStore.shared,
            appServices: appServices
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set up OpenRouter").font(.title2)
            OpenRouterTranscriptionSettingsView(settings: self.settings, viewModel: self.viewModel, showsActivationControl: false)
                .disabled(self.isActivating)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") {
                    self.activationTask?.cancel()
                    self.dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use OpenRouter") { self.activate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.isActivating || self.settings.openRouterTranscriptionAPIKey.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 650)
        .onDisappear { self.activationTask?.cancel() }
    }

    private func activate() {
        guard !self.isActivating else { return }
        let modelID = self.settings.cloudDictationModelID
        let speechModelID = self.settings.cloudTranscriptionModelID
        let apiKey = self.settings.openRouterTranscriptionAPIKey
        let primaryLanguageCode = self.settings.cloudTranscriptionPrimaryLanguageCode
        let secondaryLanguageCode = self.settings.cloudTranscriptionSecondaryLanguageCode
        let originalSource = self.settings.speechExecutionSource
        self.errorMessage = nil
        self.isActivating = true
        self.activationTask = Task { @MainActor in
            defer {
                self.isActivating = false
                self.activationTask = nil
            }
            do {
                let models = try await OpenRouterTranscriptionClient.shared.validateAudioDictation(apiKey: apiKey)
                let availableModelIDs = Set(models.map(\.id))
                // Dictation without a Cleanup Style runs on the speech model, so both must be listed.
                let speechModels = try await OpenRouterTranscriptionClient.shared.validate(apiKey: apiKey)
                try Task.checkCancellation()
                guard self.settings.cloudDictationModelID == modelID,
                      self.settings.cloudTranscriptionModelID == speechModelID,
                      self.settings.openRouterTranscriptionAPIKey == apiKey,
                      self.settings.cloudTranscriptionPrimaryLanguageCode == primaryLanguageCode,
                      self.settings.cloudTranscriptionSecondaryLanguageCode == secondaryLanguageCode,
                      self.settings.speechExecutionSource == originalSource
                else {
                    self.errorMessage = "Voice settings changed during validation. Try activating OpenRouter again."
                    return
                }
                guard speechModels.contains(where: { $0.id == speechModelID }) else {
                    self.errorMessage = "The selected speech model is unavailable on OpenRouter. Choose another model."
                    return
                }
                guard availableModelIDs.contains(modelID) else {
                    self.errorMessage = "The selected style model is unavailable on OpenRouter. Choose another model."
                    return
                }
                self.settings.speechExecutionSource = .openRouter
                self.viewModel.asr.resetTranscriptionProvider()
                self.dismiss()
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
