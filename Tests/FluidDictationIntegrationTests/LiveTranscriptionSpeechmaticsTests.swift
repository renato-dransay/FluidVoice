#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

final class LiveTranscriptionSpeechmaticsTests: XCTestCase {
    private let automatic = LiveTranscriptionConfiguration(provider: .speechmatics, modelID: "enhanced", languageCode: nil, languageHints: ["pt", "en"])

    func testConnectionUsesTheEURegionAndBearerKey() throws {
        let request = try SpeechmaticsLiveAdapter().connectionRequest(apiKey: "k", configuration: self.automatic)
        XCTAssertEqual(request.url?.absoluteString, "wss://eu.rt.speechmatics.com/v2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testStartRecognitionUsesThePrimaryLanguageWithoutAChoice() throws {
        let opening = try SpeechmaticsLiveAdapter().openingMessages(apiKey: "k", configuration: self.automatic)
        XCTAssertEqual(opening.count, 1)
        let start = try XCTUnwrap(opening.first.flatMap(LiveJSON.object))
        XCTAssertEqual(start["message"] as? String, "StartRecognition")
        let format = try XCTUnwrap(start["audio_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "raw")
        XCTAssertEqual(format["encoding"] as? String, "pcm_s16le")
        XCTAssertEqual(format["sample_rate"] as? Int, 16_000)
        let config = try XCTUnwrap(start["transcription_config"] as? [String: Any])
        XCTAssertEqual(config["language"] as? String, "pt")
        XCTAssertEqual(config["model"] as? String, "enhanced")
        XCTAssertEqual(config["enable_partials"] as? Bool, true)
        XCTAssertEqual(config["max_delay"] as? Double, 0.7)
        XCTAssertEqual(config["max_delay_mode"] as? String, "flexible")
    }

    func testAChosenLanguageWinsOverThePrimary() throws {
        let opening = try SpeechmaticsLiveAdapter().openingMessages(apiKey: "k", configuration: self.automatic.with(languageCode: "en"))
        let config = opening.first.flatMap(LiveJSON.object)?["transcription_config"] as? [String: Any]
        XCTAssertEqual(config?["language"] as? String, "en")
    }

    func testNoLanguageAtAllIsRefusedBeforeConnecting() async {
        let none = LiveTranscriptionConfiguration(provider: .speechmatics, modelID: "enhanced", languageCode: nil, languageHints: [])
        XCTAssertThrowsError(try SpeechmaticsLiveAdapter().openingMessages(apiKey: "k", configuration: none)) { error in
            XCTAssertEqual(error as? LiveTranscriptionError, .languageRequired)
        }
        let transport = FakeLiveTransport()
        let session = LiveTranscriptionSession(adapter: SpeechmaticsLiveAdapter(), configuration: none, apiKey: "k") { transport }
        do {
            try await session.start()
            XCTFail("Expected a missing language")
        } catch {
            XCTAssertEqual(error as? LiveTranscriptionError, .languageRequired)
        }
        XCTAssertTrue(transport.openedRequests.isEmpty, "Nothing reaches the provider without a language")
        XCTAssertTrue(LiveTranscriptionError.languageRequired.isPermanent)
        XCTAssertEqual(
            LiveTranscriptionError.languageRequired.message(providerName: "Speechmatics"),
            "Speechmatics needs one set language. Choose a Primary language under Dictation language in Voice Engine settings, or activate another provider."
        )
    }

    func testAudioIsBinaryAndEndOfStreamCountsTheFramesSent() {
        var adapter = SpeechmaticsLiveAdapter()
        XCTAssertEqual(adapter.audioMessage(Data([1, 2])), .data(Data([1, 2])))
        XCTAssertEqual(adapter.audioMessage(Data([3, 4])), .data(Data([3, 4])))
        XCTAssertEqual(adapter.audioMessage(Data([5, 6])), .data(Data([5, 6])))
        XCTAssertEqual(adapter.finishMessages(), [.text(#"{"last_seq_no":3,"message":"EndOfStream"}"#)])
    }

    func testRecognitionStartedIsReadyPartialsArePendingAndFinalsCarryTheirEnd() {
        var adapter = SpeechmaticsLiveAdapter()
        XCTAssertTrue(adapter.waitsForReady)
        XCTAssertEqual(adapter.parse(.text(#"{"message":"RecognitionStarted","id":"r","language_pack_info":{}}"#)), [.ready])
        XCTAssertEqual(adapter.parse(.text(#"{"message":"AudioAdded","seq_no":1}"#)), [])
        XCTAssertEqual(adapter.parse(.text(#"{"message":"Info","type":"recognition_quality"}"#)), [])
        XCTAssertEqual(
            adapter.parse(.text(#"{"message":"AddPartialTranscript","format":"2.1","metadata":{"start_time":1.2,"end_time":2.0,"transcript":"hello wor"},"results":[]}"#)),
            [.pending("hello wor")]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"message":"AddTranscript","format":"2.1","metadata":{"start_time":1.2,"end_time":2.3,"transcript":"Hello world. "},"results":[]}"#)),
            [.segment(.init(id: "f1", text: "Hello world. ", isFinal: true, audioEndMilliseconds: 2_300)), .pending("")]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"message":"AddTranscript","metadata":{"start_time":2.3,"end_time":2.5,"transcript":""},"results":[]}"#)),
            [.pending("")]
        )
        XCTAssertEqual(adapter.parse(.text(#"{"message":"EndOfTranscript"}"#)), [.finished])
    }

    func testErrorsAndCloseCodesMap() {
        var adapter = SpeechmaticsLiveAdapter()
        XCTAssertEqual(adapter.parse(.text(#"{"message":"Error","type":"not_authorised","reason":"PRIVATE"}"#)), [.failure(.authentication)])
        XCTAssertEqual(adapter.parse(.text(#"{"message":"Error","type":"timelimit_exceeded","reason":"PRIVATE"}"#)), [.failure(.quotaExhausted)])
        XCTAssertEqual(adapter.parse(.text(#"{"message":"Error","type":"quota_exceeded","reason":"PRIVATE"}"#)), [.failure(.rateLimited)])
        XCTAssertEqual(adapter.parse(.text(#"{"message":"Error","type":"invalid_language","reason":"PRIVATE"}"#)), [.failure(.unsupportedLanguage("this language"))])
        XCTAssertEqual(adapter.parse(.text(#"{"message":"Error","type":"job_error","reason":"PRIVATE"}"#)), [.failure(.sessionClosed("job_error"))])
        XCTAssertEqual(adapter.parse(.text(#"{"message":"Warning","type":"duration_limit_exceeded"}"#)), [])
        XCTAssertEqual(adapter.failure(closeCode: 4001, reason: nil), .authentication)
        XCTAssertEqual(adapter.failure(closeCode: 4005, reason: nil), .rateLimited)
        XCTAssertEqual(adapter.failure(closeCode: 4006, reason: nil), .quotaExhausted)
        XCTAssertEqual(adapter.failure(closeCode: 1006, reason: nil), .connectionLost)
        XCTAssertEqual(adapter.failure(closeCode: 4013, reason: nil), .sessionClosed("close 4013"))
    }

    func testKeyCheck() throws {
        let request = try SpeechmaticsLiveAdapter().keyCheckRequest(apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://eu1.asr.api.speechmatics.com/v2/jobs?limit=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testCatalogNeedsAPrimaryLanguage() {
        let info = LiveTranscriptionCatalog.info(for: .speechmatics)
        XCTAssertFalse(info.detectsLanguageAutomatically)
        XCTAssertEqual(info.defaultModelID, "enhanced")
        XCTAssertTrue(info.needsPrimaryLanguage(primaryLanguageCode: nil))
        XCTAssertFalse(info.needsPrimaryLanguage(primaryLanguageCode: "pt"))
        XCTAssertFalse(LiveTranscriptionCatalog.info(for: .soniox).needsPrimaryLanguage(primaryLanguageCode: nil))
    }

    func testSessionFinishesAfterEndOfStreamWithTheFrameCount() async throws {
        let transport = FakeLiveTransport()
        transport.respond = { message in
            guard case .text(let text) = message, text.contains("EndOfStream") else { return [] }
            return [
                .success(.text(#"{"message":"AddTranscript","metadata":{"end_time":1.0,"transcript":"Olá mundo."}}"#)),
                .success(.text(#"{"message":"EndOfTranscript"}"#)),
            ]
        }
        let session = LiveTranscriptionSession(adapter: SpeechmaticsLiveAdapter(), configuration: self.automatic, apiKey: "k") { transport }
        try await session.start()
        transport.deliver(.success(.text(#"{"message":"RecognitionStarted"}"#)))
        await session.append([Float](repeating: 0.1, count: 16_000))
        let text = try await session.finish()
        XCTAssertEqual(text, "Olá mundo.")
        let frames = transport.sent.filter { if case .data = $0 { true } else { false } }.count
        XCTAssertEqual(transport.sent.last, .text(#"{"last_seq_no":\#(frames),"message":"EndOfStream"}"#))
    }
}
