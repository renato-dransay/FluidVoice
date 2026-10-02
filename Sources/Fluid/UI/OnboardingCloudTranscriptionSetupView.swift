import SwiftUI

/// Lets a new user connect OpenRouter and make it the voice engine in one sheet. The key goes through
/// the same field and the same store as AI Providers. Cloud setup remains optional; opening this sheet
/// does not change the active voice engine.
struct OnboardingCloudTranscriptionSetupView: View {
    private static let providerID = CloudTranscriptionPreferences.defaultProviderID

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var viewModel: VoiceEngineSettingsViewModel
    @State private var keyDraft = ""
    @State private var errorMessage: String?
    @State private var isActivating = false
    @State private var activationTask: Task<Void, Never>?

    init(appServices: AppServices) {
        self._viewModel = StateObject(wrappedValue: VoiceEngineSettingsViewModel(
            settings: SettingsStore.shared,
            appServices: appServices
        ))
    }

    private var hasSavedKey: Bool { !self.settings.openRouterTranscriptionAPIKey.isEmpty }
    private var hasDraft: Bool { !self.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set up OpenRouter").font(.title2)
            VStack(alignment: .leading, spacing: 16) {
                Text("Your recording is sent to OpenRouter when you stop.")
                    .font(.callout).foregroundStyle(.secondary)
                ProviderAPIKeyField(
                    text: self.$keyDraft,
                    hasSavedKey: self.hasSavedKey,
                    link: AIProviderCatalog.keyLink(for: Self.providerID)
                )
                OpenRouterModelControls(settings: self.settings, viewModel: self.viewModel)
                Divider()
                DictationLanguageControls(
                    settings: self.settings,
                    caption: "Dictation detects any language automatically. Choose Primary or Secondary while recording to override detection; the choice is remembered."
                )
            }
            .padding(16)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
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
                if self.isActivating {
                    ProgressView().controlSize(.small)
                }
                Button("Use OpenRouter") { self.activate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.isActivating || (!self.hasSavedKey && !self.hasDraft))
            }
        }
        .padding(24)
        .frame(width: 650)
        .task { await self.viewModel.refreshOpenRouterCatalog(force: false) }
        .onDisappear { self.activationTask?.cancel() }
    }

    /// Saves a typed key, then checks it and both models before OpenRouter becomes the voice engine.
    private func activate() {
        guard !self.isActivating else { return }
        self.errorMessage = nil
        if self.hasDraft {
            do {
                try self.settings.setProviderAPIKey(self.keyDraft, for: Self.providerID)
                self.keyDraft = ""
            } catch {
                self.errorMessage = error.localizedDescription
                return
            }
        }
        self.isActivating = true
        self.activationTask = Task { @MainActor in
            defer {
                self.isActivating = false
                self.activationTask = nil
            }
            await self.viewModel.refreshOpenRouterCatalog(force: false)
            let activated = await self.viewModel.activateCloudProvider(Self.providerID)
            guard !Task.isCancelled else { return }
            if activated {
                self.dismiss()
            } else {
                self.errorMessage = self.viewModel.cloudActivationStatus[Self.providerID]
                    ?? self.viewModel.cloudActivationBlocker(for: Self.providerID)
            }
        }
    }
}
