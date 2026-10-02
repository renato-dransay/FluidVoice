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
        self.asr.blocksSpeechEngineChanges
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

    /// The live key check Activate runs. Replaced only by tests, which must never contact a provider.
    var liveKeyCheck: LiveEngineActivation.KeyCheck = { try await LiveTranscriptionKeyChecker.check(provider: $0, apiKey: $1) }

    init(settings: SettingsStore, appServices: AppServices, notificationCenter: NotificationCenter = .default) {
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
        notificationCenter.publisher(for: .providerAPIKeyChanged)
            .compactMap(ProviderAPIKeyChange.init)
            .sink { [weak self] change in self?.handleProviderAPIKeyChange(change) }
            .store(in: &self.cancellables)
    }

    /// Browses the active engine's tab, or the tab a navigation request asked for. A live provider selected
    /// without its key browses Live cloud, where the missing key is shown (VE-2). A requested Cloud provider
    /// (one just set up from the Cloud tab) is the one the Cloud tab shows.
    func onAppear(requestedTab: SpeechExecutionSource? = nil, requestedCloudProviderID: String? = nil) {
        self.browsedSpeechExecutionSource = Self.tabToBrowse(requested: requestedTab, activeEngine: self.settings.voiceEngineStatus.tab)
        if let requestedCloudProviderID {
            self.browsedCloudProviderID = requestedCloudProviderID
        }
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
        var checks = EngineCheckResults(
            liveActivationStatus: self.liveActivationStatus,
            liveRejectedKeys: self.liveRejectedKeys,
            cloudActivationStatus: self.cloudActivationStatus,
            cloudRejectedKeys: self.cloudRejectedKeys
        )
        let clearsOpenRouterCatalogs = checks.forget(after: change)
        self.liveActivationStatus = checks.liveActivationStatus
        self.liveRejectedKeys = checks.liveRejectedKeys
        self.cloudActivationStatus = checks.cloudActivationStatus
        self.cloudRejectedKeys = checks.cloudRejectedKeys
        if clearsOpenRouterCatalogs {
            self.clearValidatedOpenRouterCatalogs()
            self.cloudRefreshResult = nil
        }
    }

    /// What the activation checks said about each provider's key, as the rows show it.
    struct EngineCheckResults: Equatable {
        var liveActivationStatus: [LiveTranscriptionProviderID: String]
        var liveRejectedKeys: Set<LiveTranscriptionProviderID>
        var cloudActivationStatus: [String: String]
        var cloudRejectedKeys: Set<String>

        /// Forgets what the checks said about the changed provider's old key. Returns true when the
        /// provider is OpenRouter, whose listed (validated) catalogs then no longer apply either.
        mutating func forget(after change: ProviderAPIKeyChange) -> Bool {
            if let live = ProviderRegistry.liveProviderID(for: change.providerID) {
                self.liveActivationStatus[live] = nil
                self.liveRejectedKeys.remove(live)
            }
            self.cloudActivationStatus[change.providerID] = nil
            self.cloudRejectedKeys.remove(change.providerID)
            return change.providerID == CloudTranscriptionPreferences.defaultProviderID
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

    /// Job vendors answer only after their job finishes, which dictation feels.
    static let slowCloudProviderIDs: Set<String> = ["speechmatics", "soniox", "assemblyai", "gladia"]

    /// The captions under a non-OpenRouter provider's "Speech model" menu (VE-5 item 4).
    static func cloudSpeechModelCaptions(providerID: String, supportsWordTimings: Bool) -> [String] {
        var captions = [
            "Turns speech into text. Used for dictation, imported files and voice commands. Cleanup Styles run afterwards on your default text provider.",
        ]
        if self.slowCloudProviderIDs.contains(providerID) {
            captions.append("This provider answers after a short wait, so dictation feels slower than with Local or Live cloud.")
        }
        if !supportsWordTimings {
            captions.append("Imported files are transcribed without speaker labels.")
        }
        return captions
    }

    /// VE-5 item 7: with a Cloud provider other than OpenRouter, Cleanup Styles run afterwards on the default
    /// text provider, so the activation row points to AI Providers while no text provider is text-verified.
    static func showsVerifiedTextProviderHint(providerID: String, verifiedTextProviderKeys: [String], isTextVerified: (String) -> Bool) -> Bool {
        providerID != CloudTranscriptionPreferences.defaultProviderID && !verifiedTextProviderKeys.contains(where: isTextVerified)
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
            hasModel: !self.settings.cloudTranscriptionModelID(for: providerID).isEmpty,
            isBusy: self.areSpeechModelActionsBlocked || self.isEngineCheckRunning
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
    /// them. Any other provider: its speech model must be in its catalog and its key check must pass.
    /// Every Cloud provider must pass its check before it becomes the engine.
    private func checkCloudProvider(_ providerID: String, apiKey: String) async throws {
        guard providerID == CloudTranscriptionPreferences.defaultProviderID else {
            try await Self.checkCloudProvider(
                providerID,
                modelID: self.settings.cloudTranscriptionModelID(for: providerID),
                apiKey: apiKey
            )
            return
        }
        try await Self.checkOpenRouter(
            apiKey: apiKey,
            selectedModels: { (self.settings.cloudTranscriptionModelID, self.settings.cloudDictationModelID) },
            list: { try await self.listOpenRouterModels(apiKey: $0) }
        )
    }

    /// OpenRouter's activation check (VE-5a): both catalogs are listed with the key, and the speech and
    /// style models chosen when the check started must be on them and still chosen when it ends.
    static func checkOpenRouter(
        apiKey: String,
        selectedModels: () -> (speech: String, style: String),
        list: (String) async throws -> (speech: Set<String>, style: Set<String>)
    ) async throws {
        let chosen = selectedModels()
        let listed = try await list(apiKey)
        try Task.checkCancellation()
        let current = selectedModels()
        guard current.speech == chosen.speech, current.style == chosen.style else {
            throw CloudActivationError.settingsChanged
        }
        let name = VoiceEngineStatus.providerName(CloudTranscriptionPreferences.defaultProviderID)
        guard listed.speech.contains(chosen.speech) else { throw CloudActivationError.speechModelUnavailable(providerName: name) }
        guard listed.style.contains(chosen.style) else { throw CloudActivationError.styleModelUnavailable(providerName: name) }
    }

    /// The check of a Cloud provider other than OpenRouter (VE-5a): the model locally, then one request
    /// without audio that the provider answers only for a key it accepts.
    static func checkCloudProvider(
        _ providerID: String,
        modelID: String,
        apiKey: String,
        clients: (String) -> any CloudTranscriptionClient = CloudTranscriptionClients.make
    ) async throws {
        let configuration = CloudTranscriptionConfiguration(providerID: providerID, modelID: modelID)
        do {
            try configuration.validate(wordTimings: false)
        } catch {
            throw CloudActivationError.speechModelUnavailable(providerName: VoiceEngineStatus.providerName(providerID))
        }
        try await clients(providerID).checkKey(apiKey: apiKey)
    }

    /// The listing check: which speech and style models OpenRouter offers this key. Afterwards only those
    /// stay selectable.
    private func listOpenRouterModels(apiKey: String) async throws -> (speech: Set<String>, style: Set<String>) {
        let client = OpenRouterTranscriptionClient.shared
        let speechModels = try await client.validate(apiKey: apiKey)
        let styleModels = try await client.validateAudioDictation(apiKey: apiKey)
        let speech = Set(speechModels.map(\.id))
        let style = Set(styleModels.map(\.id))
        // Lists fetched with a key that was replaced meanwhile describe the old key: they are not kept.
        guard Self.isStillSavedKey(apiKey, current: self.settings.speechAPIKey(for: CloudTranscriptionPreferences.defaultProviderID)) else {
            return (speech, style)
        }
        self.validatedOpenRouterSpeechModelIDs = speech
        self.hasValidatedOpenRouterSpeechModels = true
        self.validatedOpenRouterStyleModelIDs = style
        self.hasValidatedOpenRouterStyleModels = true
        return (speech, style)
    }

    /// True while the key a request sent is still the saved speech key, so its result may be kept.
    static func isStillSavedKey(_ requestKey: String, current: String) -> Bool {
        !requestKey.isEmpty && requestKey == current
    }

    /// `Refresh models`: fetches OpenRouter's catalogs again and checks which models this key can use.
    func refreshOpenRouterModels() async {
        let providerID = CloudTranscriptionPreferences.defaultProviderID
        let apiKey = self.settings.speechAPIKey(for: providerID)
        guard !apiKey.isEmpty, !self.isEngineCheckRunning else { return }
        self.cloudProviderBeingChecked = providerID
        self.cloudRefreshResult = nil
        defer { self.cloudProviderBeingChecked = nil }
        await self.refreshOpenRouterCatalog(force: true)
        do {
            let listed = try await self.listOpenRouterModels(apiKey: apiKey)
            // The key passed a speech check, unless it was replaced while the check ran.
            self.settings.recordSpeechVerification(for: providerID, checkedKey: apiKey)
            self.cloudRejectedKeys.remove(providerID)
            self.cloudRefreshResult = .success(
                "\(listed.speech.count) speech models and \(listed.style.count) style models listed. Your account must allow a provider serving the selected model; access is checked when it is used."
            )
        } catch is CancellationError {
            return
        } catch {
            if (error as? CloudTranscriptionError) == .authentication,
               Self.isStillSavedKey(apiKey, current: self.settings.speechAPIKey(for: providerID))
            {
                self.cloudRejectedKeys.insert(providerID)
                self.settings.clearSpeechVerification(for: providerID, rejectedKey: apiKey)
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

    /// True while a Cloud or Live cloud activation check (or a Cloud model refresh) runs. Neither engine
    /// can be activated meanwhile, so two checks never race to switch the engine.
    var isEngineCheckRunning: Bool {
        Self.isEngineCheckRunning(cloudProviderBeingChecked: self.cloudProviderBeingChecked, liveProviderBeingChecked: self.liveProviderBeingChecked)
    }

    static func isEngineCheckRunning(cloudProviderBeingChecked: String?, liveProviderBeingChecked: LiveTranscriptionProviderID?) -> Bool {
        cloudProviderBeingChecked != nil || liveProviderBeingChecked != nil
    }

    /// Why `Activate` on a live provider cannot run now, or nil. A Cloud or Live check already running
    /// blocks it, like a recording.
    static func liveActivationBlocker(isBusy: Bool, isEngineCheckRunning: Bool) -> String? {
        if isBusy { return "Finish the current recording first." }
        if isEngineCheckRunning { return "Wait for the running check to finish." }
        return nil
    }

    /// Checks the key with one REST request and switches the engine only when it passes.
    func activateLiveProvider(_ provider: LiveTranscriptionProviderID) async {
        guard Self.liveActivationBlocker(isBusy: self.areSpeechModelActionsBlocked, isEngineCheckRunning: self.isEngineCheckRunning) == nil
        else { return }
        let name = LiveTranscriptionCatalog.info(for: provider).name
        guard !self.settings.liveProviderNeedsPrimaryLanguage(provider) else {
            self.liveActivationStatus[provider] = "Couldn't activate \(name): \(LiveTranscriptionError.languageRequired.message(providerName: name))"
            return
        }
        self.liveProviderBeingChecked = provider
        self.liveActivationStatus[provider] = nil
        defer { self.liveProviderBeingChecked = nil }
        let outcome = await LiveEngineActivation(keyStore: self.settings.providerKeyStore).activate(
            provider,
            check: self.liveKeyCheck,
            canSwitch: { !self.areSpeechModelActionsBlocked }
        )
        switch outcome {
        case .activated:
            self.liveRejectedKeys.remove(provider)
            self.settings.objectWillChange.send()
            self.asr.resetTranscriptionProvider()
        case let .failed(message, keyRejected):
            if keyRejected {
                self.liveRejectedKeys.insert(provider)
                self.settings.objectWillChange.send()
            }
            self.liveActivationStatus[provider] = message
        case .cancelled:
            break
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

extension ASRService {
    /// True while the speech engine must not change: a recording, a FluidMeet meeting or a file
    /// transcription (`activeExclusiveActivity`), or a model download or preparation. Voice Engine's
    /// model and engine actions and the provider removals in AI Providers all wait for it.
    var blocksSpeechEngineChanges: Bool {
        self.isRunning
            || self.activeExclusiveActivity != nil
            || self.downloadingModelId != nil
            || self.hasActiveModelDownload
            || self.hasActiveModelPreparation
            || self.isCancellingModelPreparation
            || (!self.isAsrReady && (self.isDownloadingModel || self.isLoadingModel))
    }

    /// Why provider keys cannot be removed now, in words that name the activity that blocks it, or nil.
    var speechEngineChangeBlockerMessage: String? {
        Self.speechEngineChangeBlockerMessage(
            isRecording: self.isRunning || self.activeExclusiveActivity == .dictation,
            activity: self.activeExclusiveActivity,
            isDownloadingModel: self.downloadingModelId != nil || self.hasActiveModelDownload
                || (!self.isAsrReady && self.isDownloadingModel),
            isPreparingModel: self.hasActiveModelPreparation || self.isCancellingModelPreparation
                || (!self.isAsrReady && self.isLoadingModel)
        )
    }

    static func speechEngineChangeBlockerMessage(
        isRecording: Bool,
        activity: ASRExclusiveActivity?,
        isDownloadingModel: Bool,
        isPreparingModel: Bool
    ) -> String? {
        if isRecording { return "Finish the current recording first." }
        switch activity {
        case .meeting: return "Finish the current meeting first."
        case .fileTranscription, .localAPI: return "Finish the current transcription first."
        case .dictation: return "Finish the current recording first."
        case .modelMaintenance, nil: break
        }
        if isDownloadingModel { return "Wait for the model download to finish." }
        if isPreparingModel || activity == .modelMaintenance { return "Wait for the speech model to finish loading." }
        return nil
    }
}
