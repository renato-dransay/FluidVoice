#!/usr/bin/env python3
"""Run production Swift method bodies against deterministic, gated dependency fakes.

This avoids loading ASR models or the app UI. It verifies method control flow,
not the real provider, disk store, or SwiftUI integration.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
selected_toolchain = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
developer_dir = os.environ.get("DEVELOPER_DIR", selected_toolchain)
if ".app/Contents/Developer" not in developer_dir or not (Path(developer_dir) / "usr/bin/xcodebuild").is_file():
    raise SystemExit("Set DEVELOPER_DIR to an installed full Xcode before running this test.")
os.environ["DEVELOPER_DIR"] = developer_dir

source = (repo / 'Sources/Fluid/Services/ASRService.swift').read_text()
methods = source[source.index('    func transcribeSamplesForAPI('):source.index('    // MARK: - Exclusive model residency')]
leases = source[source.index('    func acquireExclusiveActivity('):source.index('    func prepareMeetingAudioHandoff(')]
# The harness calls the training-capture refreeze directly; in the app only `start` does.
leases = leases.replace('private func freezeLocalProviderForDictionaryTrainingCapture', 'func freezeLocalProviderForDictionaryTrainingCapture')
types = source[source.index('enum ASRExclusiveActivity:'):source.index('nonisolated enum ASRHardwareListenerEventDisposition:')]
executor = source[source.index('actor TranscriptionExecutor {'):source.index('private nonisolated func logTranscriptionExecutorPhase')]
# Which Cloud output skips local text processing, and the processing itself (CLD-5).
routing = source[source.index('    /// The Cloud provider of the recording in progress'):source.index('    /// Retry of a failed Cloud recording')]
swift = r'''
import Foundation
TYPES
EXECUTOR
func logTranscriptionExecutorPhase(_ phase: String, sessionID: Int?) {}
struct ASRTranscriptionResult { let text: String; let confidence: Float }
enum SpeechExecutionSource { case local, cloud, liveCloud }
struct CloudTranscriptionConfiguration: Equatable {
    var providerID = "openrouter"
    var modelID: String
    var languageCode: String?
    var primaryLanguageCode: String? = nil
    var secondaryLanguageCode: String? = nil
    var audioDictation: String? = nil
    init(providerID: String = "openrouter", modelID: String, languageCode: String? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.languageCode = languageCode
    }
    func with(languageCode: String??) -> CloudTranscriptionConfiguration {
        var copy = self
        if let languageCode { copy.languageCode = languageCode }
        return copy
    }
}
enum CloudTranscriptionCatalog { static let openRouterID = "openrouter" }
/// The frozen provider, key and configuration; the real session also owns the client and the prewarm rule.
struct CloudTranscriptionSession {
    let configuration: CloudTranscriptionConfiguration
    let apiKey: String
    init(configuration: CloudTranscriptionConfiguration, speechAPIKey: (String) -> String) {
        self.configuration = configuration
        self.apiKey = speechAPIKey(configuration.providerID)
    }
    private init(configuration: CloudTranscriptionConfiguration, apiKey: String) {
        self.configuration = configuration
        self.apiKey = apiKey
    }
    func with(configuration: CloudTranscriptionConfiguration) -> CloudTranscriptionSession {
        CloudTranscriptionSession(configuration: configuration, apiKey: self.apiKey)
    }
    @MainActor func provider(persistChunks: Bool) -> CloudTranscriptionProvider {
        CloudTranscriptionProvider(configuration: self.configuration, apiKey: self.apiKey, persistChunks: persistChunks)
    }
    func prewarm() async {}
}
struct LiveTranscriptionConfiguration: Equatable {
    let provider: String
    let modelID: String
}
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var speechExecutionSource = SpeechExecutionSource.local
    var cloudTranscriptionConfiguration = CloudTranscriptionConfiguration(modelID: "original", languageCode: "en")
    var cloudDictationConfiguration: CloudTranscriptionConfiguration { cloudTranscriptionConfiguration }
    var cloudDictationModelID = "dictation-model"
    var cloudDictationLanguageCode: String?
    /// As in the app: only OpenRouter as the Cloud provider sends dictation to its style model.
    var usesCombinedCloudDictation: Bool { usesCloudTranscription && cloudTranscriptionProviderID == CloudTranscriptionCatalog.openRouterID }
    var openRouterTranscriptionAPIKey = "fixture-credential"
    var cloudTranscriptionProviderID = "openrouter"
    func speechAPIKey(for providerID: String) -> String {
        providerID == "openrouter" ? openRouterTranscriptionAPIKey : "\(providerID)-fixture-credential"
    }
    var usesCloudTranscription: Bool { speechExecutionSource == .cloud }
    /// Set only while Live cloud is the effective engine, as in the app.
    var liveDictationConfiguration: LiveTranscriptionConfiguration?
    var usesLiveCloudDictation: Bool { liveDictationConfiguration != nil }
    func liveTranscriptionAPIKey(for provider: String) -> String { "live-fixture-credential" }
    var cloudTranscriptionProviderName = "OpenRouter"
    static func dictationEngineBadge(cloudProviderName: String?, liveProvider: String?) -> String {
        if let cloudProviderName { return "\(cloudProviderName.uppercased()) · CLOUD" }
        return liveProvider.map { "\($0.uppercased()) · LIVE" } ?? "ON-DEVICE"
    }
    var dictationEngineBadge: String {
        Self.dictationEngineBadge(
            cloudProviderName: usesCloudTranscription ? cloudTranscriptionProviderName : nil,
            liveProvider: liveDictationConfiguration?.provider
        )
    }
}
struct LiveProviderTestRun {
    let provider: String
    var failureMessage: String?
}
@MainActor final class LiveProviderTestCoordinator {
    static let shared = LiveProviderTestCoordinator()
    var overrideConfiguration: LiveTranscriptionConfiguration?
}
final class DictionaryAudioLearningService {
    static let shared = DictionaryAudioLearningService()
    func cancelForRecording() {}
    func activityDidEnd() {}
}
actor Gate {
    var entered = false
    var waiting: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}
struct LocalAPIAudioDecoder {
    static var sampleCount = 0
    static var throwDecoding = false
    static func estimatedSampleCount(for url: URL) throws -> Int {
        if throwDecoding { throw CancellationError() }
        return sampleCount
    }
    final class ChunkReader {
        var hasRead = false
        init(fileURL: URL) throws {}
        func nextSamples() async throws -> [Float] {
            if hasRead { return [] }
            hasRead = true
            return [Float](repeating: 0.1, count: LocalAPIAudioDecoder.sampleCount)
        }
    }
}
class Provider {
    var isReady = true
    var prefersNativeFileTranscription = true
    var finalCalls: [[Float]] = []
    var fileCalls = 0
    var shouldFail = false
    var gate: Gate?
    var responseText: String?
    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        finalCalls.append(samples)
        if let gate { await gate.pause() }
        if shouldFail { throw CancellationError() }
        return ASRTranscriptionResult(text: responseText ?? "sample result", confidence: 0.8)
    }
    func transcribeFile(at url: URL) async throws -> ASRTranscriptionResult {
        fileCalls += 1
        if shouldFail { throw CancellationError() }
        return ASRTranscriptionResult(text: responseText ?? "file result", confidence: 0.8)
    }
}
final class LiveCloudTranscriptionProvider: Provider {
    let configuration: LiveTranscriptionConfiguration
    let apiKey: String
    let localProvider: Provider?
    var reconfiguredLanguages: [String?] = []
    init(configuration: LiveTranscriptionConfiguration, apiKey: String, localProvider: Provider?) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.localProvider = localProvider
        super.init()
    }
    func reconfigure(languageCode: String?) async { reconfiguredLanguages.append(languageCode) }
}
final class CloudTranscriptionProvider: Provider {
    static var nextGate: Gate?
    let configuration: CloudTranscriptionConfiguration
    let apiKey: String
    let persistChunks: Bool
    init(configuration: CloudTranscriptionConfiguration, apiKey: String, persistChunks: Bool) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.persistChunks = persistChunks
        super.init()
        self.gate = Self.nextGate
        self.responseText = "  um cloud raw words  "
    }
}
@MainActor final class ASRService {
    var activeActivityLease: ASRActivityLease?
    var activeExclusiveActivity: ASRExclusiveActivity?
    var deferredMeetingActivityLeaseRelease: ASRActivityLease?
    var providerResetPending = false
    var localProvider = Provider()
    var frozenTranscriptionProvider: Provider?
    var frozenSpeechExecutionSource: SpeechExecutionSource?
    var frozenCloudSession: CloudTranscriptionSession?
    var frozenCloudConfiguration: CloudTranscriptionConfiguration? { frozenCloudSession?.configuration }
    var frozenCloudDictationModelID: String?
    var isAsrReady = false
    var asrReadyBeforeLiveLease: Bool?
    var isStoppingFinalTranscription = false
    var liveProviderTestRun: LiveProviderTestRun?
    var endedLiveStreams = 0
    func endLiveCloudStream() { endedLiveStreams += 1 }
    var transcriptionProvider: Provider { frozenTranscriptionProvider ?? localProvider }
    var isUsingCloudTranscription: Bool {
        (frozenSpeechExecutionSource ?? SettingsStore.shared.speechExecutionSource) == .cloud
    }
    static var formattingCalls = 0
    private let transcriptionExecutor = TranscriptionExecutor()
    var hasCompletedFirstTranscription = false
    var isLoadingModel = true
    var modelPreparationPhase: String? = "loading"
    var prepareFails = false
    var outputCount = 0
    func isMeetingASRClaimBlocking(lease: ASRActivityLease) -> Bool { false }
    func resetTranscriptionProvider() {}
    func ensureAsrReady() async throws { if prepareFails { throw CancellationError() } }
    static func applySpokenPunctuationFormatting(_ text: String) -> String { formattingCalls += 1; return text }
    static func applyCustomDictionary(_ text: String) -> String { formattingCalls += 1; return text }
    static func removeFillerWords(_ text: String) -> String { formattingCalls += 1; return text }
    func recordWordBoostHitIfAny(transcribedText: String) { outputCount += 1 }
    LEASES
    METHODS
    ROUTING
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
@main struct Runner {
    @MainActor static func main() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var passes = 0
        for native in [false, true] {
            for count in [0, 1, 15999, 16000, 32000] {
                let service = ASRService()
                service.transcriptionProvider.prefersNativeFileTranscription = native
                LocalAPIAudioDecoder.sampleCount = count
                let (result, originalCount) = try await service.transcribeFileForAPI(url)
                check(originalCount == count, "Response must retain unpadded source duration")
                let expectedFileCalls = native && (count == 0 || count >= 16000) ? 1 : 0
                check(service.transcriptionProvider.fileCalls == expectedFileCalls, "Native route must preserve boundary behavior")
                if count > 0 && expectedFileCalls == 0 {
                    let samples = service.transcriptionProvider.finalCalls
                    check(samples.count == 1 && samples[0].count == max(16000, count), "Samples must be padded to one second exactly once")
                    check(samples[0].prefix(count).allSatisfy { $0 == 0.1 }, "Padding must preserve input samples")
                    check(samples[0].dropFirst(count).allSatisfy { $0 == 0 }, "Padding must append silence")
                    check(result.text == "sample result", "Sample result must be returned")
                }
                check(service.activeActivityLease == nil, "Successful API request must release the lease")
                passes += 1
            }
        }
        for failure in 0..<4 {
            let service = ASRService()
            LocalAPIAudioDecoder.sampleCount = 8000
            LocalAPIAudioDecoder.throwDecoding = failure == 1
            service.prepareFails = failure == 2
            service.transcriptionProvider.shouldFail = failure == 3
            do {
                _ = try await service.transcribeFileForAPI(failure == 0 ? url.appendingPathExtension("missing") : url)
                fatalError("Expected failure \(failure)")
            } catch {}
            check(service.activeActivityLease == nil && service.activeExclusiveActivity == nil, "Failure must release lease")
            LocalAPIAudioDecoder.throwDecoding = false
            passes += 1
        }
        do {
            let service = ASRService()
            let dictation = try service.acquireExclusiveActivity(.dictation)
            do { _ = try await service.transcribeFileForAPI(url); fatalError("Existing recording must reject API") } catch ASRActivityError.activityInProgress(.dictation) {} catch { fatalError("Wrong busy error") }
            check(service.activeActivityLease == dictation, "Rejected request must not release another recording")
            check(service.transcriptionProvider.finalCalls.isEmpty && service.transcriptionProvider.fileCalls == 0, "Rejected request must not call provider")
            service.releaseExclusiveActivity(dictation)
            passes += 1
        }
        do {
            let service = ASRService()
            LocalAPIAudioDecoder.sampleCount = 8000
            let gate = Gate()
            service.transcriptionProvider.gate = gate
            let request = Task { try await service.transcribeFileForAPI(url) }
            while !(await gate.entered) { await Task.yield() }
            check(service.activeExclusiveActivity == .localAPI, "Short upload must keep API ownership during provider work")
            do { _ = try service.acquireExclusiveActivity(.dictation); fatalError("Concurrent recording must be rejected") } catch ASRActivityError.activityInProgress(.localAPI) {} catch { fatalError("Wrong activity error") }
            await gate.release()
            _ = try await request.value
            check(service.activeActivityLease == nil, "Short upload must release ownership when provider completes")
            _ = try service.acquireExclusiveActivity(.dictation)
            passes += 1
        }
        do {
            let service = ASRService()
            _ = try await service.transcribeSamplesForAPI([0.1])
            check(service.transcriptionProvider.finalCalls.first?.count == 16000 && service.activeActivityLease == nil, "Direct samples API still acquires/releases and pads")
            passes += 1
        }
        do {
            let settings = SettingsStore.shared
            settings.speechExecutionSource = .cloud
            let originalConfiguration = CloudTranscriptionConfiguration(modelID: "original", languageCode: "en")
            settings.cloudTranscriptionConfiguration = originalConfiguration
            let service = ASRService()
            let gate = Gate()
            CloudTranscriptionProvider.nextGate = gate
            ASRService.formattingCalls = 0
            let request = Task { try await service.transcribeSamplesForAPI([0.1]) }
            while !(await gate.entered) { await Task.yield() }
            guard let provider = service.frozenTranscriptionProvider as? CloudTranscriptionProvider else {
                fatalError("Cloud API lease must freeze a cloud provider")
            }
            check(provider.configuration == originalConfiguration, "Model and language must be frozen at acquisition")
            check(provider.persistChunks, "API recordings should persist resumable chunks")
            settings.speechExecutionSource = .local
            settings.cloudTranscriptionConfiguration = .init(modelID: "changed", languageCode: "de")
            settings.openRouterTranscriptionAPIKey = "changed-fixture-credential"
            check(service.transcriptionProvider === provider && service.isUsingCloudTranscription, "Preferences cannot redirect in-flight cloud audio")
            check(provider.configuration == originalConfiguration && provider.apiKey == "fixture-credential", "In-flight configuration and credential are immutable")
            await gate.release()
            let result = try await request.value
            check(result.text == "um cloud raw words", "Cloud transcript is trimmed but not rewritten")
            check(ASRService.formattingCalls == 0, "Cloud API must bypass local transcript transformations")
            check(service.frozenTranscriptionProvider == nil && service.frozenSpeechExecutionSource == nil && service.frozenCloudConfiguration == nil, "Lease release clears all frozen state")
            CloudTranscriptionProvider.nextGate = nil
            settings.speechExecutionSource = .cloud
            for activity in [ASRExclusiveActivity.dictation, .fileTranscription, .localAPI] {
                let lease = try service.acquireExclusiveActivity(activity)
                guard let next = service.frozenTranscriptionProvider as? CloudTranscriptionProvider else { fatalError("Expected cloud provider") }
                check(next.configuration == settings.cloudTranscriptionConfiguration, "Only subsequent operations adopt model and language changes")
                check(next.persistChunks == (activity != .dictation), "Dictation must not persist cloud chunks; files and API may resume")
                check(service.frozenCloudDictationModelID == (activity == .dictation ? "dictation-model" : nil), "Only OpenRouter dictation freezes the style model")
                service.releaseExclusiveActivity(lease)
                passes += 1
            }
            settings.speechExecutionSource = .local
            passes += 1
        }
        do {
            // Another Cloud provider: its own key is frozen, and its output gets the local transformations (CLD-5).
            let settings = SettingsStore.shared
            settings.speechExecutionSource = .cloud
            settings.cloudTranscriptionProviderID = "deepgram"
            settings.cloudTranscriptionConfiguration = CloudTranscriptionConfiguration(providerID: "deepgram", modelID: "nova-3")
            defer {
                settings.speechExecutionSource = .local
                settings.cloudTranscriptionProviderID = "openrouter"
                settings.cloudTranscriptionConfiguration = CloudTranscriptionConfiguration(modelID: "original", languageCode: "en")
            }
            let service = ASRService()
            let lease = try service.acquireExclusiveActivity(.dictation)
            guard let provider = service.frozenTranscriptionProvider as? CloudTranscriptionProvider else { fatalError("Expected cloud provider") }
            check(provider.apiKey == "deepgram-fixture-credential", "The key is the frozen provider's own speech key")
            check(service.frozenCloudDictationModelID == nil, "Deepgram dictation never goes to OpenRouter's style model")
            check(service.skipsLocalTextProcessing == false, "Deepgram output is processed like local output")
            settings.cloudTranscriptionProviderID = "openrouter"
            check(service.activeCloudProviderID == "deepgram", "The recording keeps the provider it was frozen with")
            service.releaseExclusiveActivity(lease)
            settings.cloudTranscriptionProviderID = "deepgram"
            ASRService.formattingCalls = 0
            let result = try await service.transcribeSamplesForAPI([0.1])
            check(result.text == "  um cloud raw words  " && ASRService.formattingCalls == 3, "Deepgram API output gets the local transformations")
            passes += 1
        }
        do {
            let service = ASRService()
            let gate = Gate()
            service.localProvider.gate = gate
            let request = Task { try await service.transcribeSamplesForAPI([0.1]) }
            while !(await gate.entered) { await Task.yield() }
            request.cancel()
            await gate.release()
            do { _ = try await request.value; fatalError("Cancelled API request returned late output") } catch is CancellationError {}
            check(service.activeActivityLease == nil && service.frozenTranscriptionProvider == nil, "Cancellation releases API ownership")
            check(service.outputCount == 0, "Cancelled API must not publish output metadata")
            passes += 1
        }
        do {
            // Live cloud: dictation streams to the live provider; files and the local API stay on the local model.
            let settings = SettingsStore.shared
            settings.speechExecutionSource = .liveCloud
            settings.liveDictationConfiguration = LiveTranscriptionConfiguration(provider: "soniox", modelID: "stt-rt-v5")
            defer {
                settings.speechExecutionSource = .local
                settings.liveDictationConfiguration = nil
            }
            let service = ASRService()
            service.isAsrReady = false
            let dictation = try service.acquireExclusiveActivity(.dictation)
            guard let live = service.frozenTranscriptionProvider as? LiveCloudTranscriptionProvider else {
                fatalError("A Live cloud dictation lease must freeze the live provider")
            }
            check(live.configuration == settings.liveDictationConfiguration && live.apiKey == "live-fixture-credential", "Live configuration and key are frozen at acquisition")
            check(live.localProvider === service.localProvider, "The live provider keeps the cached local provider, not a new unloaded one")
            check(service.frozenSpeechExecutionSource == .liveCloud && !service.isUsingCloudTranscription, "A live lease is not an OpenRouter lease")
            check(service.isAsrReady, "A live lease with a saved key is ready without the local model")
            service.releaseExclusiveActivity(dictation)
            check(!service.isAsrReady && service.endedLiveStreams == 1, "Releasing a live lease closes the stream and forgets the live readiness")
            check(service.frozenTranscriptionProvider == nil && service.asrReadyBeforeLiveLease == nil, "Release clears live state")
            passes += 1

            let loaded = ASRService()
            loaded.isAsrReady = true
            let afterLoad = try loaded.acquireExclusiveActivity(.dictation)
            loaded.releaseExclusiveActivity(afterLoad)
            check(loaded.isAsrReady, "Releasing a live lease restores the local model's readiness from before the lease")
            passes += 1

            service.isAsrReady = true
            let training = try service.acquireExclusiveActivity(.dictation)
            service.freezeLocalProviderForDictionaryTrainingCapture(true)
            check(service.frozenTranscriptionProvider === service.localProvider && service.frozenSpeechExecutionSource == .local, "Dictionary training captures use the local model")
            check(service.isAsrReady, "A training capture restores the local model's readiness")
            service.releaseExclusiveActivity(training)
            check(service.endedLiveStreams == 1, "A training capture opened no live stream")
            passes += 1

            for activity in [ASRExclusiveActivity.fileTranscription, .localAPI] {
                let lease = try service.acquireExclusiveActivity(activity)
                check(service.frozenTranscriptionProvider === service.localProvider, "Files and the local API use the cached local provider while Live cloud is active")
                check(service.frozenSpeechExecutionSource == .local, "Files and the local API are attributed to the local engine")
                service.releaseExclusiveActivity(lease)
                passes += 1
            }

            ASRService.formattingCalls = 0
            _ = try await service.transcribeSamplesForAPI([0.1])
            check(service.localProvider.finalCalls.count == 1 && ASRService.formattingCalls == 3, "The local API applies local transformations while Live cloud is active")
            passes += 1

            let recording = try service.acquireExclusiveActivity(.dictation)
            guard let active = service.frozenTranscriptionProvider as? LiveCloudTranscriptionProvider else { fatalError("Expected live provider") }
            settings.cloudDictationLanguageCode = "pt"
            service.refreshActiveCloudDictationLanguage()
            for _ in 0..<20 where active.reconfiguredLanguages.isEmpty { await Task.yield() }
            check(active.reconfiguredLanguages == ["pt"], "A language picked during a live recording reconfigures the session")
            check(service.frozenTranscriptionProvider === active, "A language change keeps the same live provider")
            settings.cloudDictationLanguageCode = nil
            service.releaseExclusiveActivity(recording)
            passes += 1
        }
        do {
            // Provider test: an armed test replaces the active engine for dictation only, and the stop path reads it after release.
            let settings = SettingsStore.shared
            let test = LiveProviderTestCoordinator.shared
            settings.speechExecutionSource = .cloud
            test.overrideConfiguration = LiveTranscriptionConfiguration(provider: "deepgram", modelID: "nova-3")
            defer {
                settings.speechExecutionSource = .local
                test.overrideConfiguration = nil
            }
            let service = ASRService()
            let dictation = try service.acquireExclusiveActivity(.dictation)
            guard let live = service.frozenTranscriptionProvider as? LiveCloudTranscriptionProvider else {
                fatalError("An armed provider test must freeze the tested live provider")
            }
            check(live.configuration.provider == "deepgram" && live.apiKey == "live-fixture-credential", "The test uses the armed provider and its key")
            check(service.frozenSpeechExecutionSource == .liveCloud && service.frozenCloudConfiguration == nil, "A test lease is not an OpenRouter lease")
            check(service.liveProviderTestRun?.provider == "deepgram", "The lease records the provider test")
            check(service.dictationEngineBadge == "DEEPGRAM · LIVE", "The overlay names the tested provider, never the engine in settings")
            service.releaseExclusiveActivity(dictation)
            check(service.dictationEngineBadge == "OPENROUTER · CLOUD", "With no recording the overlay names the engine in settings")
            check(service.liveProviderTestRun?.provider == "deepgram", "The test run outlives the lease for the stop path")
            passes += 1

            let file = try service.acquireExclusiveActivity(.fileTranscription)
            check(service.frozenTranscriptionProvider is CloudTranscriptionProvider, "Files keep the active engine while a test is armed")
            service.releaseExclusiveActivity(file)
            let training = try service.acquireExclusiveActivity(.dictation)
            service.freezeLocalProviderForDictionaryTrainingCapture(true)
            check(service.liveProviderTestRun == nil, "A dictionary training capture is not a provider test")
            service.releaseExclusiveActivity(training)
            passes += 1

            test.overrideConfiguration = nil
            let normal = try service.acquireExclusiveActivity(.dictation)
            check(service.liveProviderTestRun == nil && service.frozenTranscriptionProvider is CloudTranscriptionProvider, "Disarmed, dictation uses the active engine")
            service.releaseExclusiveActivity(normal)
            passes += 1
        }
        print("PASS \(passes) API scenarios using production API methods, activity ownership and transcription executor")
    }
}
'''.replace('TYPES', types).replace('EXECUTOR', executor).replace('LEASES', leases).replace('METHODS', methods).replace('ROUTING', routing)
with tempfile.TemporaryDirectory(prefix="fluidvoice-api-regression-") as directory:
    root = Path(directory)
    (root / 'api-proof.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(root/'api-proof.swift'), '-o', str(root/'api-proof')], check=True)
    subprocess.run([str(root/'api-proof')], check=True)
