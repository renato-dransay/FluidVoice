import AppKit
import Combine
import SwiftUI

@MainActor
final class VoiceEngineSettingsViewModel: ObservableObject {
    let settings: SettingsStore
    private let appServices: AppServices
    private var cancellables = Set<AnyCancellable>()

    var asr: ASRService { self.appServices.asr }

    var areSpeechModelActionsBlocked: Bool {
        self.asr.isRunning
            || self.asr.activeExclusiveActivity != nil
            || self.downloadingModel != nil
            || self.asr.hasActiveModelDownload
            || self.asr.hasActiveModelPreparation
            || self.asr.isCancellingModelPreparation
            || (!self.asr.isAsrReady && (self.asr.isDownloadingModel || self.asr.isLoadingModel))
    }

    @Published var modelSortOption: ModelSortOption = .provider
    @Published var providerFilter: SpeechProviderFilter = .all
    @Published var englishOnlyFilter: Bool = false
    @Published var installedOnlyFilter: Bool = false
    @Published var showSpeechFilters: Bool = false
    @Published var browsedSpeechExecutionSource: SpeechExecutionSource
    /// Why the last Activate of a live provider failed; cleared when it succeeds or its key changes.
    @Published var liveActivationStatus: [LiveTranscriptionProviderID: String] = [:]
    /// Providers whose key the provider rejected at activation, shown as "Key rejected" in the row.
    @Published var liveRejectedKeys: Set<LiveTranscriptionProviderID> = []
    @Published var liveProviderBeingChecked: LiveTranscriptionProviderID?
    /// The speech and style models OpenRouter listed at the last successful validation. Before one,
    /// every catalog model stays selectable. Cleared when the OpenRouter key changes.
    @Published var validatedOpenRouterSpeechModelIDs: Set<String> = []
    @Published var hasValidatedOpenRouterSpeechModels = false
    @Published var validatedOpenRouterStyleModelIDs: Set<String> = []
    @Published var hasValidatedOpenRouterStyleModels = false

    @Published var selectedSpeechProvider: SettingsStore.SpeechModel.Provider
    @Published var previewSpeechModel: SettingsStore.SpeechModel
    @Published var showAdvancedSpeechInfo: Bool = false

    var downloadingModel: SettingsStore.SpeechModel? {
        guard let modelID = self.asr.downloadingModelId else { return nil }
        return SettingsStore.SpeechModel.allCases.first { $0.id == modelID }
    }

    var downloadProgress: Double {
        self.asr.downloadProgress ?? 0.0
    }

    var isCancellingModelDownload: Bool {
        self.asr.isCancellingModelDownload
    }

    init(settings: SettingsStore, appServices: AppServices) {
        self.settings = settings
        self.appServices = appServices
        self.browsedSpeechExecutionSource = settings.speechExecutionSource
        self.previewSpeechModel = settings.selectedSpeechModel
        self.selectedSpeechProvider = settings.selectedSpeechModel.provider
        appServices.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &self.cancellables)
        NotificationCenter.default.publisher(for: .providerAPIKeyChanged)
            .compactMap(ProviderAPIKeyChange.init)
            .sink { [weak self] change in self?.handleProviderAPIKeyChange(change) }
            .store(in: &self.cancellables)
    }

    /// Browses the active engine's tab, or the tab a navigation request asked for.
    func onAppear(requestedTab: SpeechExecutionSource? = nil) {
        self.browsedSpeechExecutionSource = Self.tabToBrowse(requested: requestedTab, activeEngine: self.settings.speechExecutionSource)
        self.previewSpeechModel = self.settings.selectedSpeechModel
        self.selectedSpeechProvider = self.settings.selectedSpeechModel.provider

        Task {
            await self.asr.checkIfModelsExistAsync()
        }
    }

    /// A tab requested by navigation wins over the active engine for that appearance.
    static func tabToBrowse(requested: SpeechExecutionSource?, activeEngine: SpeechExecutionSource) -> SpeechExecutionSource {
        requested ?? activeEngine
    }

    /// Status that described the old key no longer applies once a provider's key changes.
    func handleProviderAPIKeyChange(_ change: ProviderAPIKeyChange) {
        if let live = ProviderRegistry.liveProviderID(for: change.providerID) {
            self.liveActivationStatus[live] = nil
            self.liveRejectedKeys.remove(live)
        }
        if change.providerID == CloudTranscriptionPreferences.defaultProviderID {
            self.clearValidatedOpenRouterCatalogs()
        }
    }

    func clearValidatedOpenRouterCatalogs() {
        self.validatedOpenRouterSpeechModelIDs = []
        self.hasValidatedOpenRouterSpeechModels = false
        self.validatedOpenRouterStyleModelIDs = []
        self.hasValidatedOpenRouterStyleModels = false
    }

    func handleSelectedSpeechModelChange(_ newValue: SettingsStore.SpeechModel) {
        self.previewSpeechModel = newValue
        self.setSelectedSpeechProvider(newValue.provider)
    }

    var filteredSpeechModels: [SettingsStore.SpeechModel] {
        var models = SettingsStore.SpeechModel.availableModels

        switch self.providerFilter {
        case .all:
            break
        case .nvidia:
            models = models.filter { $0.provider == .nvidia }
        case .apple:
            models = models.filter { $0.provider == .apple }
        case .cohere:
            models = models.filter { $0.provider == .cohere }
        case .openai:
            models = models.filter { $0.provider == .openai }
        }

        if self.englishOnlyFilter {
            models = models.filter { model in
                let label = model.languageSupport.lowercased()
                let title = model.humanReadableName.lowercased()
                return label.contains("english only") || title.contains("english")
            }
        }

        if self.installedOnlyFilter {
            models = models.filter { $0.isInstalled }
        }

        switch self.modelSortOption {
        case .provider:
            models.sort { $0.brandName.localizedCaseInsensitiveCompare($1.brandName) == .orderedAscending }
        case .accuracy:
            models.sort { $0.accuracyPercent > $1.accuracyPercent }
        case .speed:
            models.sort { $0.speedPercent > $1.speedPercent }
        }

        return models
    }

    func activateSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.areSpeechModelActionsBlocked else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            // Exactly one engine is active: a local model replaces any live provider.
            self.settings.clearActiveLiveProvider()
            self.settings.speechExecutionSource = .local
            self.settings.selectedSpeechModel = model
            self.previewSpeechModel = model
            self.setSelectedSpeechProvider(model.provider)
        }
        self.asr.resetTranscriptionProvider()
        Task {
            do {
                try await self.asr.ensureAsrReady(source: .settings)
            } catch is CancellationError {
                DebugLogger.shared.info("Model activation cancelled: \(model.displayName)", source: "AISettingsView")
            } catch {
                DebugLogger.shared.error("Failed to prepare model after activation: \(error)", source: "AISettingsView")
                self.asr.errorTitle = "Model Activation Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    func downloadSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.areSpeechModelActionsBlocked else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.asr.downloadModel(model, progressHandler: nil)
                DebugLogger.shared.info("Model download completed: \(model.displayName)", source: "VoiceEngineVM")
            } catch is CancellationError {
                DebugLogger.shared.info("Model download cancelled: \(model.displayName)", source: "VoiceEngineVM")
            } catch {
                DebugLogger.shared.error("Failed to download model \(model.displayName): \(error)", source: "VoiceEngineVM")
                self.asr.errorTitle = "Model Download Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    func cancelSpeechModelDownload() {
        guard self.downloadingModel != nil, !self.isCancellingModelDownload else { return }
        self.asr.cancelModelDownload()
    }

    func cancelActiveModelPreparation() {
        self.asr.cancelModelPreparation()
    }

    func deleteSpeechModel(_ model: SettingsStore.SpeechModel) {
        guard !self.areSpeechModelActionsBlocked else { return }
        Task { await self.deleteSpeechModelCache(model) }
    }

    func deleteModels() async {
        await self.deleteSpeechModelCache(self.settings.selectedSpeechModel)
    }

    private func deleteSpeechModelCache(_ model: SettingsStore.SpeechModel) async {
        guard !self.areSpeechModelActionsBlocked else { return }
        do {
            // Browsing Local while cloud is active must still target the local model cache.
            try await self.asr.clearModelCache(for: model)
            if self.settings.speechExecutionSource == .local, self.settings.selectedSpeechModel == model {
                self.asr.resetTranscriptionProvider()
            }
        } catch {
            DebugLogger.shared.error("Failed to delete model \(model.displayName): \(error)", source: "VoiceEngineVM")
        }
    }

    func isActiveSpeechModel(_ model: SettingsStore.SpeechModel) -> Bool {
        self.settings.speechExecutionSource == .local && self.settings.selectedSpeechModel == model
    }

    func setCloudTranscriptionEnabled(_ enabled: Bool) {
        guard !self.areSpeechModelActionsBlocked else { return }
        guard !enabled || !self.settings.openRouterTranscriptionAPIKey.isEmpty else { return }
        if enabled {
            // Exactly one engine is active: OpenRouter replaces any live provider.
            self.settings.clearActiveLiveProvider()
            self.settings.cloudTranscriptionProviderID = CloudTranscriptionPreferences.defaultProviderID
            self.settings.speechExecutionSource = .cloud
        } else if self.settings.usesCombinedCloudDictation {
            // JUDGMENT: turning OpenRouter off (or removing its key) must not leave Live cloud,
            // so only an active OpenRouter engine falls back to Local.
            self.settings.speechExecutionSource = .local
        }
        self.asr.resetTranscriptionProvider()
    }

    // MARK: - Live cloud

    /// Adding a provider never changes the voice engine.
    func addLiveProvider(_ provider: LiveTranscriptionProviderID) {
        var preferences = LiveTranscriptionPreferences(defaults: .standard)
        preferences.addedProviders.append(provider)
        self.settings.objectWillChange.send()
    }

    /// Saves or, for an empty key, removes the provider's key and returns the status line to show.
    /// `setProviderAPIKey` applies the effects of a removal; observers clear the status of the old key.
    func saveLiveKey(_ key: String, for provider: LiveTranscriptionProviderID) -> String {
        let isRemoval = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let wasActive = self.settings.activeLiveProvider == provider
        do {
            try self.settings.setProviderAPIKey(isRemoval ? nil : key, for: ProviderRegistry.providerID(for: provider))
        } catch {
            return error.localizedDescription
        }
        if isRemoval {
            guard wasActive else { return "API key removed." }
            return "API key removed. \(LiveTranscriptionCatalog.info(for: provider).name) is no longer active; dictation uses your selected local model."
        }
        return "Key saved. Start a test or activate to check it."
    }

    /// Checks the key with one REST request and switches the engine only when it passes.
    func activateLiveProvider(_ provider: LiveTranscriptionProviderID) async {
        guard !self.areSpeechModelActionsBlocked, self.liveProviderBeingChecked == nil else { return }
        let name = LiveTranscriptionCatalog.info(for: provider).name
        guard !self.settings.liveProviderNeedsPrimaryLanguage(provider) else {
            self.liveActivationStatus[provider] = "Couldn't activate \(name): \(LiveTranscriptionError.languageRequired.message(providerName: name))"
            return
        }
        self.liveProviderBeingChecked = provider
        self.liveActivationStatus[provider] = nil
        defer { self.liveProviderBeingChecked = nil }
        do {
            try await LiveTranscriptionKeyChecker.check(provider: provider, apiKey: self.settings.liveTranscriptionAPIKey(for: provider))
            // A recording may have started while the check ran; the engine never changes under it.
            guard !self.areSpeechModelActionsBlocked else {
                self.liveActivationStatus[provider] = "Couldn't activate \(name): finish the current recording first."
                return
            }
            var preferences = LiveTranscriptionPreferences(defaults: .standard)
            preferences.activeProvider = provider
            self.liveRejectedKeys.remove(provider)
            self.settings.recordSpeechVerification(for: ProviderRegistry.providerID(for: provider))
            self.settings.speechExecutionSource = .liveCloud
            self.asr.resetTranscriptionProvider()
        } catch let error as LiveTranscriptionError {
            if error == .authentication {
                self.liveRejectedKeys.insert(provider)
                self.settings.clearSpeechVerification(for: ProviderRegistry.providerID(for: provider))
            }
            self.liveActivationStatus[provider] = "Couldn't activate \(name): \(error.message(providerName: name))"
        } catch {
            self.liveActivationStatus[provider] = "Couldn't activate \(name): \(error.localizedDescription)"
        }
    }

    /// Removes the provider from the list with its key and model choice. If it was active, dictation returns to
    /// Local; if FluidMeet transcribed with it, meetings return to Local too (`setProviderAPIKey`).
    func removeLiveProvider(_ provider: LiveTranscriptionProviderID) {
        do {
            try self.settings.setProviderAPIKey(nil, for: ProviderRegistry.providerID(for: provider))
        } catch {
            DebugLogger.shared.warning("Live provider key removal failed: provider=\(provider.rawValue)", source: "VoiceEngineVM")
        }
        var preferences = LiveTranscriptionPreferences(defaults: .standard)
        preferences.addedProviders.removeAll { $0 == provider }
        preferences.removeModelChoice(for: provider)
        self.settings.objectWillChange.send()
    }

    var modelDescriptionText: String {
        let model = self.settings.selectedSpeechModel
        switch model {
        case .appleSpeech:
            return "Apple Speech (Legacy) uses built-in macOS speech recognition. No model download required, works on Intel and Apple Silicon."
        case .appleSpeechAnalyzer:
            return "Apple Speech uses advanced on-device recognition with fast, accurate transcription. Requires macOS 26+."
        case .parakeetTDT:
            return "Parakeet TDT v3 uses CoreML and Neural Engine for fastest transcription (25 languages) on Apple Silicon."
        case .parakeetTDTv2:
            return "Parakeet TDT v2 is an English-only model optimized for accuracy and consistency on Apple Silicon."
        case .parakeetRealtime:
            return "Parakeet Flash uses FluidAudio's true streaming EOU pipeline for low-latency English dictation. Best when you want words to appear live as you speak."
        case .qwen3Asr:
            return "Qwen3 ASR is a multilingual FluidAudio model with strong quality, but higher memory usage. Requires macOS 15+."
        case .cohereTranscribeSixBit:
            return "Cohere Transcribe downloads a CoreML pipeline from Hugging Face and caches it locally. Select the language manually before dictation. Best on Apple Silicon with 8GB+ RAM."
        case .nemotronOffline:
            return "Nemotron 3.5 Multilingual is slower but more accurate. Supports around 40 languages with auto or manual language selection. Best on Apple Silicon with 8GB+ RAM."
        case .nemotronStreaming, .nemotronStreaming320:
            return "Nemotron Speech 3.5 Streaming Capable uses NVIDIA's streaming CoreML pipeline. Supports around 40 languages with auto or manual language selection."
        default:
            return "Whisper models support 99 languages and work on any Mac."
        }
    }

    func downloadModels() async {
        do {
            try await self.asr.ensureAsrReady(source: .settings)
        } catch is CancellationError {
            DebugLogger.shared.info("Model download cancelled", source: "AISettingsView")
        } catch {
            DebugLogger.shared.error("Failed to download models: \(error)", source: "AISettingsView")
            self.asr.errorTitle = "Model Download Failed"
            self.asr.errorMessage = error.localizedDescription
            self.asr.showError = true
        }
    }

    func setSelectedSpeechProvider(_ provider: SettingsStore.SpeechModel.Provider) {
        self.selectedSpeechProvider = provider
    }

    func openExternalModelSource(for model: SettingsStore.SpeechModel) {
        guard let url = model.externalCoreMLSpec?.sourceURL else { return }
        NSWorkspace.shared.open(url)
    }
}
