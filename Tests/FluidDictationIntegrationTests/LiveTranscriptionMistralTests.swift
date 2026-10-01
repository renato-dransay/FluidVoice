#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

final class LiveTranscriptionMistralTests: XCTestCase {
    private let automatic = LiveTranscriptionConfiguration(provider: .mistral, modelID: "voxtral-mini-transcribe-realtime-2602", languageCode: nil, languageHints: ["en", "pt"])

    func testConnectionCarriesTheModelAndBearerKeyAndNoLanguage() throws {
        let request = try MistralLiveAdapter().connectionRequest(apiKey: "k", configuration: self.automatic.with(languageCode: "pt"))
        XCTAssertEqual(request.url?.absoluteString, "wss://api.mistral.ai/v1/audio/transcriptions/realtime?model=voxtral-mini-transcribe-realtime-2602")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertTrue(try MistralLiveAdapter().openingMessages(apiKey: "k", configuration: self.automatic).isEmpty)
    }

    func testSessionCreatedIsAnsweredWithTheAudioFormatAndUpdatedIsReady() throws {
        var adapter = MistralLiveAdapter()
        XCTAssertTrue(adapter.waitsForReady)
        let updates = adapter.parse(.text(#"{"type":"session.created","session":{"request_id":"r","model":"m","audio_format":{"encoding":"pcm_s16le","sample_rate":16000}}}"#))
        guard case .reply(let replies) = try XCTUnwrap(updates.first), updates.count == 1 else { return XCTFail("\(updates)") }
        let update = try XCTUnwrap(replies.first.flatMap(LiveJSON.object))
        XCTAssertEqual(update["type"] as? String, "session.update")
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        let format = try XCTUnwrap(session["audio_format"] as? [String: Any])
        XCTAssertEqual(format["encoding"] as? String, "pcm_s16le")
        XCTAssertEqual(format["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(session["target_streaming_delay_ms"] as? Int, 480)
        XCTAssertEqual(adapter.parse(.text(#"{"type":"session.updated","session":{}}"#)), [.ready])
    }

    func testAudioIsBase64JSON() throws {
        var adapter = MistralLiveAdapter()
        let pcm = Data([9, 8, 7, 6])
        let object = try XCTUnwrap(LiveJSON.object(adapter.audioMessage(pcm)))
        XCTAssertEqual(object["type"] as? String, "input_audio.append")
        XCTAssertEqual(object["audio"] as? String, pcm.base64EncodedString())
    }

    func testDeltasAccumulateAndDoneReplacesTheTextAndFinishes() {
        var adapter = MistralLiveAdapter()
        var assembler = LiveTranscriptAssembler()
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"transcription.text.delta","text":"Olá"}"#)),
            [.segment(.init(id: "stream", text: "Olá", isFinal: false, audioEndMilliseconds: nil))]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"transcription.text.delta","text":" mundo"}"#)),
            [.segment(.init(id: "stream", text: "Olá mundo", isFinal: false, audioEndMilliseconds: nil))]
        )
        XCTAssertEqual(adapter.parse(.text(#"{"type":"transcription.language","audio_language":"pt"}"#)), [])
        let done = adapter.parse(.text(#"{"type":"transcription.done","model":"m","text":"Olá, mundo.","language":"pt","segments":[]}"#))
        XCTAssertEqual(done, [.replaceAll("Olá, mundo."), .finished])
        done.forEach { assembler.apply($0) }
        XCTAssertEqual(assembler.finalText, "Olá, mundo.")
    }

    func testFinishFlushesThenEnds() {
        var adapter = MistralLiveAdapter()
        XCTAssertEqual(adapter.finishMessages(), [.text(#"{"type":"input_audio.flush"}"#), .text(#"{"type":"input_audio.end"}"#)])
    }

    func testErrorFramesMapWithoutTheirMessage() {
        var adapter = MistralLiveAdapter()
        XCTAssertEqual(adapter.parse(.text(#"{"type":"error","error":{"message":"PRIVATE","code":401}}"#)), [.failure(.authentication)])
        XCTAssertEqual(adapter.parse(.text(#"{"type":"error","error":{"message":"PRIVATE","code":429}}"#)), [.failure(.rateLimited)])
        XCTAssertEqual(adapter.parse(.text(#"{"type":"error","error":{"message":{"detail":"PRIVATE"},"code":3001}}"#)), [.failure(.sessionClosed("error 3001"))])
    }

    func testKeyCheck() throws {
        let request = try MistralLiveAdapter().keyCheckRequest(apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testCatalogListsTheRealtimeLanguagesAndSendsNoLanguageChoice() {
        let info = LiveTranscriptionCatalog.info(for: .mistral)
        XCTAssertTrue(info.supports(languageCode: "pt"))
        XCTAssertFalse(info.supports(languageCode: "pl"))
        XCTAssertFalse(info.sendsLanguageChoice)
        XCTAssertTrue(LiveTranscriptionCatalog.info(for: .soniox).sendsLanguageChoice)
        XCTAssertEqual(info.keyURL?.absoluteString, "https://console.mistral.ai/home?profile_dialog=api-keys")
        XCTAssertEqual(info.usageURL?.absoluteString, "https://admin.mistral.ai/organization/usage")
    }

    func testSessionWaitsForTheHandshakeBeforeAudio() async throws {
        let transport = FakeLiveTransport()
        transport.respond = { message in
            switch message {
            case .text(let text) where text.contains(#""type":"session.update""#):
                return [.success(.text(#"{"type":"session.updated","session":{}}"#))]
            case .text(#"{"type":"input_audio.end"}"#):
                return [.success(.text(#"{"type":"transcription.done","text":"hello world"}"#))]
            default:
                return []
            }
        }
        let session = LiveTranscriptionSession(adapter: MistralLiveAdapter(), configuration: self.automatic, apiKey: "k") { transport }
        try await session.start()
        await session.append([Float](repeating: 0.1, count: 3_200))
        XCTAssertTrue(transport.sent.isEmpty, "No audio before the server's greeting")
        transport.deliver(.success(.text(#"{"type":"session.created","session":{}}"#)))
        let text = try await session.finish()
        XCTAssertEqual(text, "hello world")
        let types = transport.sent.compactMap { LiveJSON.object($0)?["type"] as? String }
        XCTAssertEqual(types.first, "session.update")
        XCTAssertEqual(Array(types.suffix(2)), ["input_audio.flush", "input_audio.end"])
        XCTAssertTrue(types.contains("input_audio.append"))
    }

    @MainActor
    func testALanguageChoiceDoesNotReconnectAProviderThatIgnoresIt() async {
        let transports = LockedQueue([FakeLiveTransport(), FakeLiveTransport()])
        let all = transports.snapshot
        let provider = LiveCloudTranscriptionProvider(configuration: self.automatic, apiKey: "k", localProvider: nil, makeTransport: { transports.next() })
        await provider.begin()
        await provider.reconfigure(languageCode: "pt")
        XCTAssertEqual(all[0].openedRequests.count, 1)
        XCTAssertEqual(all[1].openedRequests.count, 0, "Mistral cannot take the language, so the stream is kept")
        await provider.cancel()
    }
}
