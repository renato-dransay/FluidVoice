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
                Button("Cancel") { self.dismiss() }
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
        self.isActivating = true
        self.activationTask = Task { @MainActor in
            defer { self.isActivating = false }
            do {
                let models = try await OpenRouterTranscriptionClient().validate(apiKey: self.settings.openRouterTranscriptionAPIKey)
                try Task.checkCancellation()
                guard models.contains(where: { $0.id == self.settings.cloudTranscriptionModelID }) else {
                    self.errorMessage = "The selected transcription model is unavailable on OpenRouter. Choose another model."
                    return
                }
                self.settings.speechExecutionSource = .openRouter
                self.viewModel.asr.resetTranscriptionProvider()
                try await self.viewModel.asr.ensureAsrReady(source: .onboarding)
                self.dismiss()
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
