@testable import FluidVoice_Debug
import Foundation
import XCTest

/// How `ASRService` and the other consumers treat a Cloud provider other than OpenRouter (CLD-5, CLD-6),
/// through the helpers they call. Clients are injected and stubbed; nothing reads the app's own stores.
@MainActor
final class CloudProviderRoutingTests: XCTestCase {
    private static func dictionary(_ text: String) -> String {
        text.replacingOccurrences(of: "fluid voice", with: "FluidVoice")
    }

    func testNonOpenRouterCloudOutputGetsTheCustomDictionary() {
        let skips = ASRService.skipsLocalTextProcessing(cloudProviderID: "deepgram")
        XCTAssertFalse(skips)
        let text = ASRService.processedTranscript(
            "um fluid voice works",
            skipsLocalProcessing: skips,
            removeFillers: { $0.replacingOccurrences(of: "um ", with: "") },
            applyDictionary: Self.dictionary,
            formatPunctuation: { $0 + "." }
        )
        XCTAssertEqual(text, "FluidVoice works.")
    }

    func testOpenRouterOutputIsOnlyTrimmed() {
        let skips = ASRService.skipsLocalTextProcessing(cloudProviderID: "openrouter")
        XCTAssertTrue(skips)
        let text = ASRService.processedTranscript(
            "  um fluid voice works \n",
            skipsLocalProcessing: skips,
            removeFillers: { _ in XCTFail("OpenRouter output keeps its fillers"); return "" },
            applyDictionary: { _ in XCTFail("OpenRouter output gets no dictionary"); return "" },
            formatPunctuation: { _ in XCTFail("OpenRouter output gets no formatting"); return "" }
        )
        XCTAssertEqual(text, "um fluid voice works")
    }

    func testADictionaryTrainingCaptureSkipsTheDictionary() {
        let text = ASRService.processedTranscript(
            "fluid voice",
            skipsLocalProcessing: false,
            isDictionaryTraining: true,
            removeFillers: { $0 },
            applyDictionary: Self.dictionary,
            formatPunctuation: { $0 + "." }
        )
        XCTAssertEqual(text, "fluid voice")
    }

    func testRetryUsesTheFrozenProviderAndItsCurrentKey() {
        let keys = ["openrouter": "or-key", "deepgram": "dg-key-replaced"]
        let frozen = CloudTranscriptionConfiguration(providerID: "deepgram", modelID: "nova-3", languageCode: "de")
        let session = ASRService.cloudRetrySession(configuration: frozen, speechAPIKey: { keys[$0] ?? "" })
        XCTAssertEqual(session.configuration, frozen)
        XCTAssertEqual(session.client.providerID, "deepgram")
        XCTAssertEqual(session.apiKey, "dg-key-replaced", "Never OpenRouter's key")
        let provider = session.provider(persistChunks: false)
        XCTAssertEqual(provider.name, "Deepgram")
        XCTAssertTrue(provider.supportsWordTimings)
    }

    func testRetryOfAnOpenRouterRecordingStaysOnOpenRouter() {
        let session = ASRService.cloudRetrySession(configuration: CloudTranscriptionConfiguration(), speechAPIKey: { $0 == "openrouter" ? "or-key" : "" })
        XCTAssertEqual(session.client.providerID, "openrouter")
        XCTAssertEqual(session.apiKey, "or-key")
    }

    /// A retried non-OpenRouter Cloud recording gets the local text processing its first attempt would have
    /// had (CLD-5). OpenRouter, Live cloud and "Transcribe locally" retries stay trimmed only, as before.
    func testARetriedNonOpenRouterRecordingGetsTheLocalTextProcessing() {
        func retried(_ failed: ASRService.FailedRemoteDictation, useLocal: Bool = false) -> String {
            ASRService.retriedTranscript(
                "  um fluid voice works \n",
                of: failed,
                useLocal: useLocal,
                removeFillers: { $0.replacingOccurrences(of: "um ", with: "") },
                applyDictionary: Self.dictionary,
                formatPunctuation: { $0.trimmingCharacters(in: .whitespacesAndNewlines) + "." }
            )
        }
        let samples: [Float] = [0.1]
        for providerID in ["deepgram", "speechmatics", "soniox", "assemblyai", "gladia"] {
            let configuration = CloudTranscriptionConfiguration(providerID: providerID, modelID: CloudTranscriptionCatalog.defaultModelID(for: providerID) ?? "")
            XCTAssertEqual(retried(.cloud(samples: samples, configuration: configuration)), "FluidVoice works.", providerID)
        }
        XCTAssertEqual(retried(.cloud(samples: samples, configuration: CloudTranscriptionConfiguration())), "um fluid voice works", "OpenRouter is unchanged")
        let deepgram = CloudTranscriptionConfiguration(providerID: "deepgram", modelID: "nova-3")
        XCTAssertEqual(retried(.cloud(samples: samples, configuration: deepgram), useLocal: true), "um fluid voice works", "Transcribe locally is unchanged")
        let live = LiveTranscriptionConfiguration(provider: .soniox, modelID: "stt-rt-v5", languageCode: nil, languageHints: [])
        XCTAssertEqual(retried(.live(samples: samples, configuration: live)), "um fluid voice works", "Live cloud retry is unchanged")
    }

    /// VE-5 item 7: the activation row of a provider other than OpenRouter names the missing verified text
    /// provider. A speech check never counts, because only the text record is read.
    func testCleanupStylesHintShowsForOtherProvidersWithoutAVerifiedTextProvider() {
        typealias Model = VoiceEngineSettingsViewModel
        for providerID in ["deepgram", "elevenlabs", "mistral", "speechmatics", "soniox", "assemblyai", "gladia"] {
            XCTAssertTrue(Model.showsVerifiedTextProviderHint(providerID: providerID, verifiedTextProviderKeys: [], isTextVerified: { _ in true }), providerID)
            XCTAssertTrue(
                Model.showsVerifiedTextProviderHint(providerID: providerID, verifiedTextProviderKeys: ["openai"], isTextVerified: { _ in false }),
                "A stale record is not a verified provider"
            )
            XCTAssertFalse(Model.showsVerifiedTextProviderHint(providerID: providerID, verifiedTextProviderKeys: ["openai"], isTextVerified: { $0 == "openai" }))
        }
        XCTAssertFalse(Model.showsVerifiedTextProviderHint(providerID: "openrouter", verifiedTextProviderKeys: [], isTextVerified: { _ in false }))
    }

    /// A Deepgram dictation, from the frozen session to the transcript, never sends a request to openrouter.ai.
    func testNoRequestGoesToOpenRouterWhenTheCloudProviderIsDeepgram() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"results":{"channels":[{"alternatives":[{"transcript":"fluid voice"}]}]}}"#.utf8))
        }
        let clients: (String) -> any CloudTranscriptionClient = { providerID in
            providerID == "deepgram"
                ? DeepgramTranscriptionClient(session: CloudURLProtocol.session())
                : OpenRouterTranscriptionClient(session: CloudURLProtocol.session(), recordsUsage: false)
        }
        let session = CloudTranscriptionSession(
            configuration: .init(providerID: "deepgram", modelID: "nova-3"),
            speechAPIKey: { $0 == "deepgram" ? "dg-key" : "or-key" },
            clients: clients
        )
        await session.prewarm()
        let provider = session.provider(persistChunks: false)
        try await provider.prepare(progressHandler: nil)
        let result = try await provider.transcribe([Float](repeating: 0.1, count: 16_000))
        let text = ASRService.processedTranscript(
            result.text,
            skipsLocalProcessing: !session.appliesLocalTextProcessing,
            removeFillers: { $0 },
            applyDictionary: Self.dictionary,
            formatPunctuation: { $0 }
        )
        XCTAssertEqual(text, "FluidVoice")
        XCTAssertEqual(recorder.requests.map(\.url?.host), ["api.deepgram.com", "api.deepgram.com"], "Key check, then the upload")
        XCTAssertFalse(recorder.requests.contains { $0.url?.host == "openrouter.ai" })
    }

    func testHistoryNamesTheCloudProvider() {
        XCTAssertEqual(CloudTranscriptionClients.historyProviderName(for: "openrouter"), "openrouter")
        XCTAssertEqual(CloudTranscriptionClients.historyProviderName(for: "elevenlabs"), "cloud-elevenlabs")
    }

    // MARK: - File Transcription (CLD-6)

    func testSpeakerLabelsAreDroppedOnlyForAModelWithoutWordTimings() {
        typealias Service = FileTranscriptionService
        XCTAssertEqual(Service.cloudSpeakerLabels(requested: false, cloudProviderID: "mistral", supportsWordTimings: false), .disabled)
        XCTAssertEqual(Service.cloudSpeakerLabels(requested: true, cloudProviderID: "mistral", supportsWordTimings: false), .droppedForModel)
        XCTAssertEqual(Service.cloudSpeakerLabels(requested: true, cloudProviderID: "deepgram", supportsWordTimings: true), .enabled)
        XCTAssertEqual(Service.cloudSpeakerLabels(requested: true, cloudProviderID: "openrouter", supportsWordTimings: false), .unavailable)
        XCTAssertEqual(Service.cloudSpeakerLabels(requested: true, cloudProviderID: nil, supportsWordTimings: false), .enabled, "Local files diarize on their own")
    }
}
