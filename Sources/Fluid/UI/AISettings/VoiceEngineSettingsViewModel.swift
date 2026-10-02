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
    /// The Cloud provider whose settings the Cloud tab shows. View state only: choosing a provider in
    /// the menu never changes the engine.
    @Published var browsedCloudProviderID: String?
    /// The Cloud provider whose activation check or model refresh is running.
    @Published var cloudProviderBeingChecked: String?
    /// Why the last Activate of a Cloud provider failed; cleared when it succeeds or its key changes.
    @Published var cloudActivationStatus: [String: String] = [:]
    /// Cloud providers whose key the provider rejected at activation or refresh.
    @Published var cloudRejectedKeys: Set<String> = []
    /// The outcome of the last `Refresh models`.
    @Published var cloudRefreshResult: ProviderActionResult?
    /// OpenRouter's speech and style catalogs as last fetched.
    @Published var openRouterSpeechModels = CloudTranscriptionModel.catalog
    @Published var openRouterStyleModels = CloudAudioDictationModel.catalog
    /// The speech and style models OpenRouter listed at the last successful check. Before one,
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

    /// Browses the active engine's tab, or the tab a navigation request asked for. A live provider selected
    /// without its key browses Live cloud, where the missing key is shown (VE-2).
    func onAppear(requestedTab: SpeechExecutionSource? = nil) {
        self.browsedSpeechExecutionSource = Self.tabToBrowse(requested: requestedTab, activeEngine: self.settings.voiceEngineStatus.tab)
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
        self.cloudActivationStatus[change.providerID] = nil
        self.cloudRejectedKeys.remove(change.providerID)
        if change.providerID == CloudTranscriptionPreferences.defaultProviderID {
            self.clearValidatedOpenRouterCatalogs()
            self.cloudRefreshResult = nil
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

    /// The line under "Selected local model" while Local is not the engine (VE-8). Live cloud leaves imported
    /// files to the local model; Cloud handles them itself.
    static func selectedLocalModelCaption(engine: SpeechExecutionSource, cloudProviderName: String) -> String {
        switch engine {
        case .cloud: "Not in use. \(cloudProviderName) handles dictation, imported files and voice commands."
        case .liveCloud, .local: "Used for imported files, and for dictation when you activate it."
        }
    }

    func isActiveSpeechModel(_ model: SettingsStore.SpeechModel) -> Bool {
        self.settings.speechExecutionSource == .local && self.settings.selectedSpeechModel == model
    }

    // MARK: - Cloud

    /// The Cloud tab's provider menu: connected Cloud transcription providers first, then the rest.
    static func cloudProviderGroups(hasKey: (String) -> Bool) -> (connected: [ProviderDescriptor], notSetUp: [ProviderDescriptor]) {
        let all = ProviderRegistry.providers(with: .cloudTranscription)
        return (all.filter { hasKey($0.id) }, all.filter { !hasKey($0.id) })
    }

    /// The provider the Cloud tab shows: the one browsed in the menu, else the stored Cloud provider, else
    /// the first connected one. Nil when none is connected.
    static func shownCloudProviderID(browsed: String?, stored: String, connected: [String]) -> String? {
        if let browsed, connected.contains(browsed) { return browsed }
        if connected.contains(stored) { return stored }
        return connected.first
    }

    var cloudProviderGroups: (connected: [ProviderDescriptor], notSetUp: [ProviderDescriptor]) {
        Self.cloudProviderGroups(hasKey: { !self.settings.speechAPIKey(for: $0).isEmpty })
    }

    var shownCloudProviderID: String? {
        Self.shownCloudProviderID(
            browsed: self.browsedCloudProviderID,
            stored: self.settings.cloudTranscriptionProviderID,
            connected: self.cloudProviderGroups.connected.map(\.id)
        )
    }

    func isActiveCloudProvider(_ providerID: String) -> Bool {
        self.settings.usesCloudTranscription && self.settings.cloudTranscriptionProviderID == providerID
    }

    /// Why `Activate` is disabled for this Cloud provider, or nil when it can run.
    static func cloudActivationBlocker(hasKey: Bool, hasModel: Bool, isBusy: Bool) -> String? {
        if !hasKey { return "Add an API key in AI Providers first." }
        if !hasModel { return "Choose a speech model first." }
        if isBusy { return "Finish the current recording first." }
        return nil
    }

    func cloudActivationBlocker(for providerID: String) -> String? {
        Self.cloudActivationBlocker(
            hasKey: !self.settings.speechAPIKey(for: providerID).isEmpty,
            hasModel: !self.settings.cloudTranscriptionModelID.isEmpty,
            isBusy: self.areSpeechModelActionsBlocked || self.cloudProviderBeingChecked != nil || self.liveProviderBeingChecked != nil
        )
    }

    /// The speech status the Cloud tab's connection line shows (VER-5).
    func cloudProviderStatus(for providerID: String) -> ProviderStatus {
        ProviderStatus.speech(
            hasAPIKey: !self.settings.speechAPIKey(for: providerID).isEmpty,
            isVerifying: self.cloudProviderBeingChecked == providerID,
            isVerified: self.settings.isSpeechVerified(providerID),
            verificationFailed: self.cloudRejectedKeys.contains(providerID)
        )
    }

    /// Runs the provider's check and makes it the voice engine only when it passes (VE-5a). Returns true
    /// once the engine switched.
    @discardableResult
    func activateCloudProvider(_ providerID: String) async -> Bool {
        guard self.cloudActivationBlocker(for: providerID) == nil else { return false }
        self.cloudProviderBeingChecked = providerID
        self.cloudActivationStatus[providerID] = nil
        defer { self.cloudProviderBeingChecked = nil }
        let outcome = await CloudEngineActivation(keyStore: self.settings.providerKeyStore).activate(
            providerID,
            check: { apiKey in try await self.checkCloudProvider(providerID, apiKey: apiKey) },
            canSwitch: { !self.areSpeechModelActionsBlocked }
        )
        switch outcome {
        case .activated:
            self.cloudRejectedKeys.remove(providerID)
            self.settings.objectWillChange.send()
            self.asr.resetTranscriptionProvider()
            return true
        case let .failed(message, keyRejected):
            if keyRejected {
                self.cloudRejectedKeys.insert(providerID)
                self.settings.objectWillChange.send()
            }
            self.cloudActivationStatus[providerID] = message
            return false
        case .cancelled:
            return false
        }
    }

    /// OpenRouter: both catalogs are listed with the key and the chosen speech and style models must be on
    /// them. Every Cloud provider must pass its check before it becomes the engine.
    private func checkCloudProvider(_ providerID: String, apiKey: String) async throws {
        guard providerID == CloudTranscriptionPreferences.defaultProviderID else {
            throw CloudTranscriptionError.unsupportedModel
        }
        let speechModelID = self.settings.cloudTranscriptionModelID
        let styleModelID = self.settings.cloudDictationModelID
        let listed = try await self.listOpenRouterModels(apiKey: apiKey)
        try Task.checkCancellation()
        guard self.settings.cloudTranscriptionModelID == speechModelID, self.settings.cloudDictationModelID == styleModelID else {
            throw CloudActivationError.settingsChanged
        }
        let name = VoiceEngineStatus.providerName(providerID)
        guard listed.speech.contains(speechModelID) else { throw CloudActivationError.speechModelUnavailable(providerName: name) }
        guard listed.style.contains(styleModelID) else { throw CloudActivationError.styleModelUnavailable(providerName: name) }
    }

    /// The listing check: which speech and style models OpenRouter offers this key. Afterwards only those
    /// stay selectable.
    private func listOpenRouterModels(apiKey: String) async throws -> (speech: Set<String>, style: Set<String>) {
        let client = OpenRouterTranscriptionClient.shared
        let speechModels = try await client.validate(apiKey: apiKey)
        let styleModels = try await client.validateAudioDictation(apiKey: apiKey)
        let speech = Set(speechModels.map(\.id))
        let style = Set(styleModels.map(\.id))
        self.validatedOpenRouterSpeechModelIDs = speech
        self.hasValidatedOpenRouterSpeechModels = true
        self.validatedOpenRouterStyleModelIDs = style
        self.hasValidatedOpenRouterStyleModels = true
        return (speech, style)
    }

    /// `Refresh models`: fetches OpenRouter's catalogs again and checks which models this key can use.
    func refreshOpenRouterModels() async {
        let providerID = CloudTranscriptionPreferences.defaultProviderID
        let apiKey = self.settings.speechAPIKey(for: providerID)
        guard !apiKey.isEmpty, self.cloudProviderBeingChecked == nil else { return }
        self.cloudProviderBeingChecked = providerID
        self.cloudRefreshResult = nil
        defer { self.cloudProviderBeingChecked = nil }
        await self.refreshOpenRouterCatalog(force: true)
        do {
            let listed = try await self.listOpenRouterModels(apiKey: apiKey)
            // The key passed a speech check, unless it was replaced while the check ran.
            if self.settings.speechAPIKey(for: providerID) == apiKey {
                self.settings.recordSpeechVerification(for: providerID)
            }
            self.cloudRejectedKeys.remove(providerID)
            self.cloudRefreshResult = .success(
                "\(listed.speech.count) speech models and \(listed.style.count) style models listed. Your account must allow a provider serving the selected model; access is checked when it is used."
            )
        } catch is CancellationError {
            return
        } catch {
            if (error as? CloudTranscriptionError) == .authentication {
                self.cloudRejectedKeys.insert(providerID)
                self.settings.clearSpeechVerification(for: providerID)
            }
            self.cloudRefreshResult = .failure(error.localizedDescription)
        }
    }

    /// The catalog is fetched only once a key is saved, so a local-only setup never contacts OpenRouter.
    /// A failed fetch keeps the cached list; the listing check reports connection errors.
    func refreshOpenRouterCatalog(force: Bool) async {
        guard !self.settings.openRouterTranscriptionAPIKey.isEmpty else { return }
        do {
            try await CloudTranscriptionCatalogStore.shared.refresh(using: .shared, force: force)
            self.openRouterSpeechModels = CloudTranscriptionModel.catalog
            self.openRouterStyleModels = CloudAudioDictationModel.catalog
        } catch is CancellationError {
            return
        } catch {
            DebugLogger.shared.warning("OpenRouter transcription catalog refresh failed: \(error)", source: "VoiceEngineVM")
        }
    }

    /// `Use local model instead`: Local with the selected local model, the state the old switch's off gave.
    func useLocalModelInstead() {
        guard !self.areSpeechModelActionsBlocked else { return }
        CloudEngineActivation(keyStore: self.settings.providerKeyStore).useLocalModelInstead()
        self.settings.objectWillChange.send()
        self.asr.resetTranscriptionProvider()
    }

    // MARK: - Live cloud

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
