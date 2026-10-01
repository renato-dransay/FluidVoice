import SwiftUI

struct MeetingCloudSettingsSection: View {
    let onOpenVoiceEngine: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    @State private var models = CloudTranscriptionModel.catalog
    @State private var checkProgress: (completed: Int, total: Int, modelName: String)?
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
                    Picker("Meeting model", selection: self.$settings.meetingCloudModelID) {
                        ForEach(self.supportedModels, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                        if !self.supportedModels.contains(where: { $0.id == self.settings.meetingCloudModelID }) {
                            Text("\(self.name(for: self.settings.meetingCloudModelID)) (not verified)").tag(self.settings.meetingCloudModelID)
                        }
                    }
                    .disabled(self.checkProgress != nil)
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        Button(self.uncheckedModels.isEmpty ? "Re-check models without word timings" : "Check catalog models for word timings", action: self.checkCatalogModels)
                            .meetingGlassAction()
                            .disabled(self.checkProgress != nil || self.checkCandidates.isEmpty)
                        if let progress = self.checkProgress {
                            ProgressView("Checking \(progress.completed) of \(progress.total): \(progress.modelName)…").controlSize(.small)
                        }
                    }
                    if !self.modelStatus.isEmpty {
                        Text(self.modelStatus)
                            .font(self.theme.typography.caption)
                            .textSelection(.enabled)
                    }
                    Text(self.uncheckedModels.isEmpty
                        ? "Only models with verified word timings are listed, because meetings need them to label speakers."
                        : "Only models with verified word timings are listed, because meetings need them to label speakers. OpenRouter lists \(self.uncheckedModels.count) unchecked models; checking sends each one short synthetic clip.")
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

    private var supportedModels: [CloudTranscriptionModel] { self.models.filter(\.supportsWordTimings) }

    private var uncheckedModels: [CloudTranscriptionModel] { self.models.filter { $0.wordTimingSupport == .unverified } }

    /// Unchecked models first; once every model has a verdict, the refusals can be rechecked in
    /// case a provider added timings. Verified models are never rechecked.
    private var checkCandidates: [CloudTranscriptionModel] {
        self.uncheckedModels.isEmpty ? self.models.filter { !$0.supportsWordTimings } : self.uncheckedModels
    }

    private func name(for modelID: String) -> String {
        self.models.first { $0.id == modelID }?.name ?? modelID
    }

    /// The catalog is fetched only once cloud meetings are on and a key is saved, so a
    /// local-only setup never contacts OpenRouter. A failed fetch keeps the cached list.
    private func refreshCatalog() async {
        guard self.usesCloud, !self.settings.openRouterTranscriptionAPIKey.isEmpty else { return }
        do {
            try await CloudTranscriptionCatalogStore.shared.refresh(using: .shared)
            self.models = CloudTranscriptionModel.catalog
        } catch is CancellationError {
            return
        } catch {
            DebugLogger.shared.warning("OpenRouter transcription catalog refresh failed: \(error)", source: "MeetingCloudSettingsSection")
        }
    }

    /// Sends one synthesized clip to every unchecked model and remembers each verdict, so the
    /// picker only ever offers models that have returned usable word timings on this Mac.
    private func checkCatalogModels() {
        let candidates = self.checkCandidates
        guard self.checkProgress == nil, !candidates.isEmpty else { return }
        let apiKey = self.settings.openRouterTranscriptionAPIKey
        guard !apiKey.isEmpty else {
            self.modelStatus = "Add your OpenRouter key in Voice Engine before checking models."
            return
        }
        self.modelStatus = ""
        self.checkProgress = (0, candidates.count, candidates[0].name)
        Task { @MainActor in
            defer {
                self.checkProgress = nil
                self.models = CloudTranscriptionModel.catalog
            }
            var passed: [String] = []
            var refused: [String] = []
            var failures: [String] = []
            do {
                let speech = try await CloudWordTimingCheckSpeech.samples()
                let client = OpenRouterTranscriptionClient.shared
                for (index, model) in candidates.enumerated() {
                    self.checkProgress = (index + 1, candidates.count, model.name)
                    do {
                        let supported = try await client.checkWordTimings(modelID: model.id, speechSamples: speech, apiKey: apiKey)
                        CloudTranscriptionCatalogStore.shared.recordWordTimingCheck(modelID: model.id, supported: supported)
                        if supported { passed.append(model.name) } else { refused.append(model.name) }
                    } catch let error as CloudTranscriptionError where Self.abortsCatalogCheck(error) {
                        throw error
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures.append("\(model.name): \(error.localizedDescription)")
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                failures.append(error.localizedDescription)
            }
            self.modelStatus = Self.checkSummary(passed: passed, refused: refused, failures: failures)
        }
    }

    /// Account-level failures repeat for every model, so one is enough to stop.
    private static func abortsCatalogCheck(_ error: CloudTranscriptionError) -> Bool {
        switch error {
        case .missingAPIKey, .authentication, .creditsExhausted, .rateLimited, .wordTimingCheckSpeechUnavailable: true
        default: false
        }
    }

    private static func checkSummary(passed: [String], refused: [String], failures: [String]) -> String {
        var lines: [String] = []
        lines.append(passed.isEmpty ? "No additional model returned word timings." : "Word timings verified: \(passed.joined(separator: ", ")).")
        if !refused.isEmpty { lines.append("No usable word timings: \(refused.joined(separator: ", ")).") }
        if !failures.isEmpty { lines.append("Could not check \(failures.count): \(failures.joined(separator: " "))") }
        return lines.joined(separator: "\n")
    }
}
