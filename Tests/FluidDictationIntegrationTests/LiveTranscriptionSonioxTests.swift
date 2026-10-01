#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

final class LiveTranscriptionSonioxTests: XCTestCase {
    private let automatic = LiveTranscriptionConfiguration(provider: .soniox, modelID: "stt-rt-v5", languageCode: nil, languageHints: ["en", "pt"])

    func testConfigurationCarriesKeyModelFormatAndHints() throws {
        let adapter = SonioxLiveAdapter()
        XCTAssertEqual(try adapter.connectionRequest(apiKey: "k", configuration: self.automatic).url?.absoluteString, "wss://stt-rt.soniox.com/transcribe-websocket")
        let opening = try adapter.openingMessages(apiKey: "k", configuration: self.automatic)
        let config = try XCTUnwrap(opening.first.flatMap(LiveJSON.object))
        XCTAssertEqual(config["api_key"] as? String, "k")
        XCTAssertEqual(config["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(config["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(config["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(config["num_channels"] as? Int, 1)
        XCTAssertEqual(config["language_hints"] as? [String], ["en", "pt"])
        XCTAssertNil(config["language_hints_strict"])
        XCTAssertEqual(config["enable_endpoint_detection"] as? Bool, false)
    }

    func testChosenLanguageIsStrict() throws {
        let opening = try SonioxLiveAdapter().openingMessages(apiKey: "k", configuration: self.automatic.with(languageCode: "pt"))
        let config = try XCTUnwrap(opening.first.flatMap(LiveJSON.object))
        XCTAssertEqual(config["language_hints"] as? [String], ["pt"])
        XCTAssertEqual(config["language_hints_strict"] as? Bool, true)
    }

    func testFinalTokensBecomeSegmentsAndNonFinalTokensThePendingText() {
        var adapter = SonioxLiveAdapter()
        let updates = adapter.parse(.text(#"{"tokens":[{"text":"Olá","end_ms":760,"is_final":true},{"text":" mun","is_final":false}],"final_audio_proc_ms":760}"#))
        XCTAssertEqual(updates, [
            .segment(.init(id: "f1", text: "Olá", isFinal: true, audioEndMilliseconds: 760)),
            .pending(" mun"),
        ])
    }

    func testAWordFinalizedAcrossMessagesStaysOneWord() {
        var adapter = SonioxLiveAdapter()
        var assembler = LiveTranscriptAssembler()
        for message in [
            #"{"tokens":[{"text":"Olá","end_ms":500,"is_final":true}]}"#,
            #"{"tokens":[{"text":" mun","end_ms":800,"is_final":true},{"text":"do","is_final":false}]}"#,
            #"{"tokens":[{"text":"do","end_ms":1000,"is_final":true}]}"#,
        ] {
            adapter.parse(.text(message)).forEach { assembler.apply($0) }
        }
        XCTAssertEqual(assembler.finalText, "Olá mundo")
    }

    func testAReconnectStartsANewSegmentInsteadOfExtendingTheOldConnection() async throws {
        let first = FakeLiveTransport()
        let second = FakeLiveTransport()
        second.respond = { message in
            message == .data(Data()) ? [.success(.text(#"{"tokens":[{"text":"tchau","end_ms":300,"is_final":true}],"finished":true}"#))] : []
        }
        let transports = LockedQueue([first, second])
        let session = LiveTranscriptionSession(adapter: SonioxLiveAdapter(), configuration: self.automatic, apiKey: "k") { transports.next() }
        try await session.start()
        await session.append([Float](repeating: 0.1, count: 32_000))
        first.deliver(.success(.text(#"{"tokens":[{"text":"Olá","end_ms":500,"is_final":true}]}"#)))
        first.deliver(.success(.text(#"{"tokens":[{"text":" mun","end_ms":800,"is_final":true}]}"#)))
        first.deliver(.success(.text(#"{"tokens":[{"text":"do","end_ms":1000,"is_final":true}]}"#)))
        first.deliver(.failure(LiveTransportClosed(closeCode: 1006, reason: nil, upgradeStatus: nil)))
        let text = try await session.finish()
        XCTAssertEqual(text, "Olá mundo tchau")
    }

    func testFinMarkerAndFinishedFlag() {
        var adapter = SonioxLiveAdapter()
        XCTAssertEqual(adapter.parse(.text(#"{"tokens":[{"text":"<fin>","is_final":true}]}"#)), [.pending("")])
        XCTAssertEqual(adapter.parse(.text(#"{"tokens":[],"finished":true}"#)), [.pending(""), .finished])
    }

    func testErrorFramesMapToActionableErrors() {
        var adapter = SonioxLiveAdapter()
        XCTAssertEqual(adapter.parse(.text(#"{"tokens":[],"error_code":401,"error_type":"unauthenticated","error_message":"PRIVATE"}"#)), [.failure(.authentication)])
        XCTAssertEqual(adapter.parse(.text(#"{"error_code":402,"error_type":"organization_balance_exhausted"}"#)), [.failure(.quotaExhausted)])
        XCTAssertEqual(adapter.parse(.text(#"{"error_code":429,"error_type":"limit_exceeded"}"#)), [.failure(.rateLimited)])
        XCTAssertEqual(adapter.parse(.text(#"{"error_code":400,"error_type":"model_not_available"}"#)), [.failure(.sessionClosed("model_not_available"))])
    }

    func testFinishSendsFinalizeThenAnEmptyFrame() {
        XCTAssertEqual(SonioxLiveAdapter().finishMessages(), [.text(#"{"type":"finalize"}"#), .data(Data())])
        XCTAssertEqual(SonioxLiveAdapter().trailingSilenceMilliseconds, 200)
    }

    func testKeyCheckUsesBearerOnTheModelsEndpoint() throws {
        let request = try SonioxLiveAdapter().keyCheckRequest(apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.soniox.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }
}
