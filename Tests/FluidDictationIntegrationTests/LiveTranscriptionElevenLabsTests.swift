#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

final class LiveTranscriptionElevenLabsTests: XCTestCase {
    private let automatic = LiveTranscriptionConfiguration(provider: .elevenLabs, modelID: "scribe_v2_realtime", languageCode: nil, languageHints: ["en", "pt"])

    func testConnectionQueryAndKeyHeader() throws {
        let request = try ElevenLabsLiveAdapter().connectionRequest(apiKey: "k", configuration: self.automatic)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "api.elevenlabs.io")
        XCTAssertEqual(request.url?.path, "/v1/speech-to-text/realtime")
        XCTAssertEqual(items["model_id"], "scribe_v2_realtime")
        XCTAssertEqual(items["audio_format"], "pcm_16000")
        XCTAssertEqual(items["commit_strategy"], "manual")
        XCTAssertEqual(items["include_timestamps"], "true")
        XCTAssertNil(items["language_code"], "Automatic detection sends no language")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "k")
        XCTAssertTrue(try ElevenLabsLiveAdapter().openingMessages(apiKey: "k", configuration: self.automatic).isEmpty)
    }

    func testChosenLanguageIsSent() throws {
        let request = try ElevenLabsLiveAdapter().connectionRequest(apiKey: "k", configuration: self.automatic.with(languageCode: "pt"))
        XCTAssertTrue(request.url?.query?.contains("language_code=pt") == true)
    }

    func testAudioIsBase64JSONAndNotCommitted() throws {
        var adapter = ElevenLabsLiveAdapter()
        let pcm = Data([1, 2, 3, 4])
        let object = try XCTUnwrap(LiveJSON.object(adapter.audioMessage(pcm)))
        XCTAssertEqual(object["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(object["audio_base_64"] as? String, pcm.base64EncodedString())
        XCTAssertEqual(object["commit"] as? Bool, false)
        XCTAssertEqual(object["sample_rate"] as? Int, 16_000)
    }

    func testSessionStartedIsReadyAndPartialsReplaceThePendingText() {
        var adapter = ElevenLabsLiveAdapter()
        XCTAssertTrue(adapter.waitsForReady)
        XCTAssertEqual(adapter.parse(.text(#"{"message_type":"session_started","session_id":"s","config":{"sample_rate":16000}}"#)), [.ready])
        XCTAssertEqual(adapter.parse(.text(#"{"message_type":"partial_transcript","text":"olá como"}"#)), [.pending("olá como")])
    }

    func testCommitsAppendFinalSegmentsWithTheLastWordEnd() {
        var adapter = ElevenLabsLiveAdapter()
        XCTAssertEqual(
            adapter.parse(.text(#"{"message_type":"committed_transcript_with_timestamps","text":"Olá, como vai?","language_code":"pt","words":[{"text":"Olá","start":0.1,"end":0.4},{"text":"vai?","start":1.0,"end":1.25}]}"#)),
            [.segment(.init(id: "c1", text: "Olá, como vai?", isFinal: true, audioEndMilliseconds: 1_250)), .pending("")]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"message_type":"committed_transcript","text":"Tudo bem."}"#)),
            [.segment(.init(id: "c2", text: "Tudo bem.", isFinal: true, audioEndMilliseconds: nil)), .pending("")]
        )
    }

    func testBothVariantsOfOneCommitFormOneSegment() {
        var adapter = ElevenLabsLiveAdapter()
        var assembler = LiveTranscriptAssembler()
        for message in [
            #"{"message_type":"committed_transcript","text":"Hello there."}"#,
            #"{"message_type":"committed_transcript_with_timestamps","text":"Hello there.","words":[{"text":"there.","start":0.5,"end":0.9}]}"#,
            #"{"message_type":"committed_transcript_with_timestamps","text":"Bye.","words":[{"text":"Bye.","start":1.5,"end":1.8}]}"#,
            #"{"message_type":"committed_transcript","text":"Bye."}"#,
        ] {
            adapter.parse(.text(message)).forEach { assembler.apply($0) }
        }
        XCTAssertEqual(assembler.finalText, "Hello there. Bye.")
        XCTAssertEqual(assembler.beginGeneration(), 1_800, "The paired commit keeps the timed variant's end")
    }

    func testFinishCommitsAndTheNextCommittedTranscriptFinishes() {
        var adapter = ElevenLabsLiveAdapter()
        XCTAssertEqual(
            adapter.parse(.text(#"{"message_type":"committed_transcript","text":"auto commit"}"#)),
            [.segment(.init(id: "c1", text: "auto commit", isFinal: true, audioEndMilliseconds: nil)), .pending("")],
            "A commit before the finish request is an ordinary segment"
        )
        let finish = adapter.finishMessages()
        XCTAssertEqual(finish.count, 1)
        let commit = finish.first.flatMap(LiveJSON.object)
        XCTAssertEqual(commit?["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(commit?["audio_base_64"] as? String, "")
        XCTAssertEqual(commit?["commit"] as? Bool, true)
        XCTAssertEqual(commit?["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(
            adapter.parse(.text(#"{"message_type":"committed_transcript","text":"last words"}"#)),
            [.segment(.init(id: "c2", text: "last words", isFinal: true, audioEndMilliseconds: nil)), .pending(""), .finished]
        )
    }

    func testErrorMessagesMap() {
        var adapter = ElevenLabsLiveAdapter()
        XCTAssertEqual(adapter.parse(.text(#"{"message_type":"auth_error","error":"PRIVATE"}"#)), [.failure(.authentication)])
        XCTAssertEqual(adapter.parse(.text(#"{"message_type":"quota_exceeded","error":"PRIVATE"}"#)), [.failure(.quotaExhausted)])
        XCTAssertEqual(adapter.parse(.text(#"{"message_type":"rate_limited","error":"PRIVATE"}"#)), [.failure(.rateLimited)])
        XCTAssertEqual(adapter.parse(.text(#"{"message_type":"resource_exhausted","error":"PRIVATE"}"#)), [.failure(.rateLimited)])
        XCTAssertEqual(adapter.parse(.text(#"{"message_type":"input_error","error":"PRIVATE"}"#)), [.failure(.sessionClosed("input_error"))])
        XCTAssertEqual(adapter.parse(.text(#"{"message_type":"warning","warning":"PRIVATE"}"#)), [])
    }

    func testKeyCheck() throws {
        let request = try ElevenLabsLiveAdapter().keyCheckRequest(apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "k")
    }

    func testSessionStreamsBase64AudioAfterTheGreetingAndFinishesOnTheCommit() async throws {
        let transport = FakeLiveTransport()
        transport.respond = { message in
            guard case .text(let text) = message, text.contains(#""commit":true"#) else { return [] }
            return [.success(.text(#"{"message_type":"committed_transcript","text":"hello world"}"#))]
        }
        let session = LiveTranscriptionSession(adapter: ElevenLabsLiveAdapter(), configuration: self.automatic, apiKey: "k") { transport }
        try await session.start()
        transport.deliver(.success(.text(#"{"message_type":"session_started","session_id":"s"}"#)))
        await session.append([Float](repeating: 0.1, count: 3_200))
        let text = try await session.finish()
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(transport.sentAudioBytes, 0, "Audio goes out as JSON text, never binary")
        let chunks = transport.sent.compactMap { message -> String? in
            guard case .text(let text) = message, text.contains(#""commit":false"#) else { return nil }
            return text
        }
        XCTAssertFalse(chunks.isEmpty)
    }
}
