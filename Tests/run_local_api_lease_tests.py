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
types = source[source.index('enum ASRExclusiveActivity:'):source.index('nonisolated enum ASRHardwareListenerEventDisposition:')]
executor = source[source.index('actor TranscriptionExecutor {'):source.index('private nonisolated func logTranscriptionExecutorPhase')]
swift = r'''
import Foundation
TYPES
EXECUTOR
func logTranscriptionExecutorPhase(_ phase: String, sessionID: Int?) {}
struct ASRTranscriptionResult { let text: String; let confidence: Float }
enum SpeechExecutionSource { case local, openRouter }
struct CloudTranscriptionConfiguration: Equatable {
    let modelID: String
    let languageCode: String?
}
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var speechExecutionSource = SpeechExecutionSource.local
    var cloudTranscriptionConfiguration = CloudTranscriptionConfiguration(modelID: "original", languageCode: "en")
    var openRouterTranscriptionAPIKey = "fixture-credential"
    var usesCloudTranscription: Bool { speechExecutionSource == .openRouter }
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
    var frozenCloudConfiguration: CloudTranscriptionConfiguration?
    var transcriptionProvider: Provider { frozenTranscriptionProvider ?? localProvider }
    var isUsingCloudTranscription: Bool {
        (frozenSpeechExecutionSource ?? SettingsStore.shared.speechExecutionSource) == .openRouter
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
            settings.speechExecutionSource = .openRouter
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
            settings.speechExecutionSource = .openRouter
            for activity in [ASRExclusiveActivity.dictation, .fileTranscription, .localAPI] {
                let lease = try service.acquireExclusiveActivity(activity)
                guard let next = service.frozenTranscriptionProvider as? CloudTranscriptionProvider else { fatalError("Expected cloud provider") }
                check(next.configuration == settings.cloudTranscriptionConfiguration, "Only subsequent operations adopt model and language changes")
                check(next.persistChunks == (activity != .dictation), "Dictation must not persist cloud chunks; files and API may resume")
                service.releaseExclusiveActivity(lease)
                passes += 1
            }
            settings.speechExecutionSource = .local
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
        print("PASS \(passes) API scenarios using production API methods, activity ownership and transcription executor")
    }
}
'''.replace('TYPES', types).replace('EXECUTOR', executor).replace('LEASES', leases).replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix="fluidvoice-api-regression-") as directory:
    root = Path(directory)
    (root / 'api-proof.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(root/'api-proof.swift'), '-o', str(root/'api-proof')], check=True)
    subprocess.run([str(root/'api-proof')], check=True)
