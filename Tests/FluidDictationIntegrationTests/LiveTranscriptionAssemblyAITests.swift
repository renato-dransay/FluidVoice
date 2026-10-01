#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

final class LiveTranscriptionAssemblyAITests: XCTestCase {
    private let automatic = LiveTranscriptionConfiguration(provider: .assemblyAI, modelID: "universal-3-6-pro", languageCode: nil, languageHints: ["en", "pt"])

    func testQueryUsesJSONArraysAndThePlainKeyHeader() throws {
        let request = try AssemblyAILiveAdapter().connectionRequest(apiKey: "k", configuration: self.automatic)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(request.url?.host, "streaming.assemblyai.com")
        XCTAssertEqual(request.url?.path, "/v3/ws")
        XCTAssertEqual(items["speech_model"], "universal-3-6-pro")
        XCTAssertEqual(items["encoding"], "pcm_s16le")
        XCTAssertEqual(items["sample_rate"], "16000")
        XCTAssertEqual(items["language_codes"], #"["en","pt"]"#)
        XCTAssertEqual(items["language_detection"], "true")
        XCTAssertNil(items["format_turns"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "k")
    }

    func testUniversalStreamingAsksForFormattedTurns() throws {
        let configuration = LiveTranscriptionConfiguration(provider: .assemblyAI, modelID: "universal-streaming-multilingual", languageCode: "pt", languageHints: [])
        let query = try AssemblyAILiveAdapter().connectionRequest(apiKey: "k", configuration: configuration).url?.query ?? ""
        XCTAssertTrue(query.contains("format_turns=true"))
        XCTAssertTrue(query.contains("language_codes=%5B%22pt%22%5D"))
    }

    func testBeginIsReadyAndTurnsAreReplacedUntilFormattedEnd() {
        var adapter = AssemblyAILiveAdapter()
        XCTAssertTrue(adapter.waitsForReady)
        XCTAssertEqual(adapter.parse(.text(#"{"type":"Begin","id":"s"}"#)), [.ready])
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"Turn","turn_order":0,"end_of_turn":false,"turn_is_formatted":false,"transcript":"my name is","words":[{"end":900}]}"#)),
            [.segment(.init(id: "turn-0", text: "my name is", isFinal: false, audioEndMilliseconds: 900))]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"Turn","turn_order":0,"end_of_turn":true,"turn_is_formatted":true,"transcript":"My name is Sonny.","words":[{"end":1627}]}"#)),
            [.segment(.init(id: "turn-0", text: "My name is Sonny.", isFinal: true, audioEndMilliseconds: 1_627))]
        )
    }

    func testTerminationFinishesAndErrorsMap() {
        var adapter = AssemblyAILiveAdapter()
        XCTAssertEqual(adapter.parse(.text(#"{"type":"Termination","audio_duration_seconds":3}"#)), [.finished])
        XCTAssertEqual(adapter.parse(.text(#"{"type":"Error","error_code":3009,"error":"PRIVATE"}"#)), [.failure(.rateLimited)])
        XCTAssertEqual(adapter.failure(closeCode: 1008, reason: "Too many concurrent sessions"), .rateLimited)
        XCTAssertEqual(adapter.failure(closeCode: 1008, reason: "Unauthorized Connection"), .authentication)
    }

    func testFinishForcesTheEndpointThenTerminates() {
        XCTAssertEqual(AssemblyAILiveAdapter().finishMessages(), [.text(#"{"type":"ForceEndpoint"}"#), .text(#"{"type":"Terminate"}"#)])
        XCTAssertEqual(AssemblyAILiveAdapter().maximumReplaySpeed, 1.2)
    }

    func testKeyCheck() throws {
        let request = try AssemblyAILiveAdapter().keyCheckRequest(apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://streaming.assemblyai.com/v3/token?expires_in_seconds=60")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "k")
    }
}
