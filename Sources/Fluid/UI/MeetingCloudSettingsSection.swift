import SwiftUI

struct MeetingCloudSettingsSection: View {
    let onOpenVoiceEngine: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    @State private var models = CloudTranscriptionModel.catalog
    @State private var checkingModelID: String?
    @State private var modelStatus = ""

    private var usesCloud: Bool { self.settings.meetingTranscriptionBackendID == .openRouterNemotron }

    var body: some View {
        FluidManagementGroup(title: "Completed meeting transcripts") {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                Picker("Transcription", selection: Binding(
                    get: { self.usesCloud },
                    set: { self.settings.meetingTranscriptionBackendID = $0 ? .openRouterNemotron : .parakeetNemotron }
                )) {
                    Text("Local").tag(false)
                    Text("OpenRouter").tag(true)
                }
                .pickerStyle(.segmented)

                if self.usesCloud {
                    Picker("Meeting model", selection: Binding(
                        get: { self.settings.meetingCloudModelID },
                        set: { self.selectMeetingModel($0) }
                    )) {
                        ForEach(self.models, id: \.id) { model in
                            Text(Self.label(for: model)).tag(model.id)
                        }
                        if !self.models.contains(where: { $0.id == self.settings.meetingCloudModelID }) {
                            Text("\(self.settings.meetingCloudModelID) (no longer listed)").tag(self.settings.meetingCloudModelID)
                        }
                    }
                    .disabled(self.checkingModelID != nil)
                    if let checkingModelID = self.checkingModelID {
                        ProgressView("Checking word timings for \(self.name(for: checkingModelID))…").controlSize(.small)
                    }
                    if !self.modelStatus.isEmpty {
                        Text(self.modelStatus)
                            .font(self.theme.typography.caption)
                            .textSelection(.enabled)
                    }
                    Text("The list follows OpenRouter's transcription catalog. Meetings need word timings to label speakers, so choosing a model that is not yet verified first sends one short synthetic test clip to check them.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Picker("Transcript language", selection: self.$settings.meetingCloudLanguageCode) {
                        ForEach(MeetingCloudLanguage.choices, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    Text("Recorded audio is sent to OpenRouter. Speaker detection stays on this Mac. Charges apply to audio duration.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    Button(self.settings.openRouterTranscriptionAPIKey.isEmpty
                        ? "Add OpenRouter key in Voice Engine" : "Manage OpenRouter key in Voice Engine", action: self.onOpenVoiceEngine)
                        .meetingGlassAction()
                } else {
                    Text("Parakeet transcribes English on this Mac.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Text("Live captions remain local and English-only. Changes apply when the next transcription starts.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .task(id: self.usesCloud) { await self.refreshCatalog() }
    }

    private static func label(for model: CloudTranscriptionModel) -> String {
        switch model.wordTimingSupport {
        case .supported: model.name
        case .unverified: "\(model.name) (not yet verified)"
        case .unsupported: "\(model.name) (no word timings)"
        }
    }

    private func name(for modelID: String) -> String {
        self.models.first { $0.id == modelID }?.name ?? modelID
    }

    /// The catalog is fetched only once cloud meetings are on and a key is saved, so a
    /// local-only setup never contacts OpenRouter. A failed fetch keeps the cached list.
    private func refreshCatalog() async {
        guard self.usesCloud, !self.settings.openRouterTranscriptionAPIKey.isEmpty else { return }
        do {
            try await CloudTranscriptionCatalogStore.shared.refresh(using: OpenRouterTranscriptionClient())
            self.models = CloudTranscriptionModel.catalog
        } catch is CancellationError {
            return
        } catch {
            DebugLogger.shared.warning("OpenRouter transcription catalog refresh failed: \(error)", source: "MeetingCloudSettingsSection")
        }
    }

    /// A model becomes the meeting model only once it has returned usable word timings.
    /// Selecting any other model runs the check first and leaves the selection alone unless it passes.
    private func selectMeetingModel(_ modelID: String) {
        guard modelID != self.settings.meetingCloudModelID, let model = self.models.first(where: { $0.id == modelID }) else { return }
        self.modelStatus = ""
        if model.supportsWordTimings {
            self.settings.meetingCloudModelID = modelID
            return
        }
        let apiKey = self.settings.openRouterTranscriptionAPIKey
        guard !apiKey.isEmpty else {
            self.modelStatus = "Add your OpenRouter key in Voice Engine before checking \(model.name). The meeting model is unchanged."
            return
        }
        self.checkingModelID = modelID
        Task { @MainActor in
            defer { self.checkingModelID = nil }
            do {
                let speech = try await CloudWordTimingCheckSpeech.samples()
                let supported = try await OpenRouterTranscriptionClient().checkWordTimings(modelID: modelID, speechSamples: speech, apiKey: apiKey)
                CloudTranscriptionCatalogStore.shared.recordWordTimingCheck(modelID: modelID, supported: supported)
                self.models = CloudTranscriptionModel.catalog
                if supported {
                    self.settings.meetingCloudModelID = modelID
                    self.modelStatus = "\(model.name) returned word timings and is now the meeting model."
                } else {
                    self.modelStatus = "\(model.name) returned no usable word timings, so it cannot label speakers. The meeting model is unchanged."
                }
            } catch {
                self.modelStatus = "\(error.localizedDescription) The meeting model is unchanged."
            }
        }
    }
}
