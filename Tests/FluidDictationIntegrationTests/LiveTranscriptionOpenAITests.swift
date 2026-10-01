#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

final class LiveTranscriptionOpenAITests: XCTestCase {
    private let automatic = LiveTranscriptionConfiguration(provider: .openAI, modelID: "gpt-live-transcribe", languageCode: nil, languageHints: ["en", "pt"])

    func testConnectionUsesTheTranscriptionIntentAndBearerKey() throws {
        let request = try OpenAILiveAdapter().connectionRequest(apiKey: "k", configuration: self.automatic)
        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?intent=transcription")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testOpeningConfiguresA24kHzTranscriptionSessionWithoutTurnDetection() throws {
        let opening = try OpenAILiveAdapter().openingMessages(apiKey: "k", configuration: self.automatic)
        XCTAssertEqual(opening.count, 1)
        let update = try XCTUnwrap(opening.first.flatMap(LiveJSON.object))
        XCTAssertEqual(update["type"] as? String, "session.update")
        let session = try XCTUnwrap(update["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["languages"] as? [String], ["en", "pt"])
        XCTAssertNil(transcription["language"], "Never `language` together with `languages`")
        XCTAssertTrue(input["turn_detection"] is NSNull, "gpt-live-transcribe needs turn_detection null")
    }

    func testChosenLanguageReplacesTheHintsAndNoLanguagesAreSentWithoutAny() throws {
        let chosen = try OpenAILiveAdapter().openingMessages(apiKey: "k", configuration: self.automatic.with(languageCode: "pt"))
        let chosenTranscription = try XCTUnwrap(Self.transcription(chosen))
        XCTAssertEqual(chosenTranscription["languages"] as? [String], ["pt"])
        let none = LiveTranscriptionConfiguration(provider: .openAI, modelID: "gpt-live-transcribe", languageCode: nil, languageHints: [])
        let noneTranscription = try XCTUnwrap(Self.transcription(try OpenAILiveAdapter().openingMessages(apiKey: "k", configuration: none)))
        XCTAssertNil(noneTranscription["languages"])
        XCTAssertNil(noneTranscription["language"])
    }

    func testRealtimeWhisperTakesOnlyAPickedLanguageAsTheSingularField() throws {
        let whisper = LiveTranscriptionConfiguration(provider: .openAI, modelID: "gpt-realtime-whisper", languageCode: nil, languageHints: ["en", "pt"])
        let hinted = try XCTUnwrap(Self.transcription(try OpenAILiveAdapter().openingMessages(apiKey: "k", configuration: whisper)))
        XCTAssertEqual(hinted["model"] as? String, "gpt-realtime-whisper")
        XCTAssertNil(hinted["languages"], "gpt-realtime-whisper does not take `languages`")
        XCTAssertNil(hinted["language"], "Hints are not a single language")
        let picked = try XCTUnwrap(Self.transcription(try OpenAILiveAdapter().openingMessages(apiKey: "k", configuration: whisper.with(languageCode: "pt"))))
        XCTAssertEqual(picked["language"] as? String, "pt")
        XCTAssertNil(picked["languages"], "Never `language` together with `languages`")
    }

    func testAudioIsResampledTo24kHzBase64JSON() throws {
        var adapter = OpenAILiveAdapter()
        let samples = (0 ..< 1_600).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let object = try XCTUnwrap(LiveJSON.object(adapter.audioMessage(LivePCM16.encode(samples))))
        XCTAssertEqual(object["type"] as? String, "input_audio_buffer.append")
        let audio = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["audio"] as? String)))
        XCTAssertEqual(audio.count / 2, 2_399, "The last output waits for the next chunk's first sample")
        let next = try XCTUnwrap(LiveJSON.object(adapter.audioMessage(LivePCM16.encode(samples))))
        let nextAudio = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(next["audio"] as? String)))
        XCTAssertEqual(nextAudio.count / 2, 2_400)
    }

    func testResamplerKeepsTheCountAndFrequencyAcrossChunks() {
        var resampler = LiveResampler16kTo24k()
        let frequency = 440.0
        let input = (0 ..< 16_000).map { Float(sin(2 * Double.pi * frequency * Double($0) / 16_000)) }
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: 1_601) {
            output += resampler.process(Array(input[start ..< min(start + 1_601, input.count)]))
        }
        XCTAssertEqual(output.count, input.count * 3 / 2 - 1, "One sample is held for the next chunk")
        for (index, sample) in output.enumerated() {
            let expected = Float(sin(2 * Double.pi * frequency * Double(index) / 24_000))
            XCTAssertEqual(sample, expected, accuracy: 0.01, "sample \(index)")
        }
        let crossings = zip(output, output.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        XCTAssertEqual(Double(crossings), 2 * frequency, accuracy: 2)
    }

    func testDeltasBuildAProvisionalItemThatCompletedReplaces() {
        var adapter = OpenAILiveAdapter()
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_3","content_index":0,"delta":"Hello,"}"#)),
            [.segment(.init(id: "item_3", text: "Hello,", isFinal: false, audioEndMilliseconds: nil))]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_3","content_index":0,"delta":" how"}"#)),
            [.segment(.init(id: "item_3", text: "Hello, how", isFinal: false, audioEndMilliseconds: nil))]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_3","content_index":0,"transcript":"Hello, how are you?"}"#)),
            [.segment(.init(id: "item_3", text: "Hello, how are you?", isFinal: true, audioEndMilliseconds: nil))]
        )
    }

    func testFinishCommitsAndTheCommittedItemsCompletionFinishes() {
        var adapter = OpenAILiveAdapter()
        XCTAssertEqual(adapter.finishMessages(), [.text(#"{"type":"input_audio_buffer.commit"}"#)])
        XCTAssertEqual(adapter.parse(.text(#"{"type":"input_audio_buffer.committed","previous_item_id":null,"item_id":"item_9"}"#)), [])
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_9","transcript":"done"}"#)),
            [.segment(.init(id: "item_9", text: "done", isFinal: true, audioEndMilliseconds: nil)), .finished]
        )
    }

    func testCompletionBeforeTheCommitAcknowledgementStillFinishes() {
        var adapter = OpenAILiveAdapter()
        _ = adapter.finishMessages()
        _ = adapter.parse(.text(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_9","transcript":"done"}"#))
        XCTAssertEqual(adapter.parse(.text(#"{"type":"input_audio_buffer.committed","item_id":"item_9"}"#)), [.finished])
    }

    func testAnEmptyCommitMeansNothingToTranscribeAndOtherErrorsMap() {
        var adapter = OpenAILiveAdapter()
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"error","error":{"type":"invalid_request_error","code":"input_audio_buffer_commit_empty","message":"PRIVATE"}}"#)),
            [.finished]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_api_key","message":"PRIVATE"}}"#)),
            [.failure(.authentication)]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"error","error":{"type":"invalid_request_error","code":"insufficient_quota","message":"PRIVATE"}}"#)),
            [.failure(.quotaExhausted)]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_event","message":"PRIVATE"}}"#)),
            [.failure(.sessionClosed("invalid_event"))]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"i","error":{"type":"transcription_error","code":"audio_unintelligible","message":"PRIVATE"}}"#)),
            [.failure(.sessionClosed("audio_unintelligible"))]
        )
    }

    func testKeyCheck() throws {
        let request = try OpenAILiveAdapter().keyCheckRequest(apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testSessionSends24kHzAudioAndReturnsTheCommittedText() async throws {
        let transport = FakeLiveTransport()
        transport.respond = { message in
            guard message == .text(#"{"type":"input_audio_buffer.commit"}"#) else { return [] }
            return [
                .success(.text(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#)),
                .success(.text(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"hello world"}"#)),
            ]
        }
        let session = LiveTranscriptionSession(adapter: OpenAILiveAdapter(), configuration: self.automatic, apiKey: "k") { transport }
        try await session.start()
        await session.append([Float](repeating: 0.1, count: 16_000))
        let text = try await session.finish()
        XCTAssertEqual(text, "hello world")
        let streamedSamples = transport.sent.reduce(0) { total, message in
            guard let object = LiveJSON.object(message), object["type"] as? String == "input_audio_buffer.append",
                  let audio = (object["audio"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return total }
            return total + audio.count / 2
        }
        XCTAssertEqual(streamedSamples, 16_000 * 3 / 2 - 1)
        XCTAssertEqual(LiveJSON.object(try XCTUnwrap(transport.sent.first))?["type"] as? String, "session.update")
    }

    private static func transcription(_ opening: [LiveTransportMessage]) -> [String: Any]? { // swiftlint:disable:this discouraged_optional_collection
        let session = opening.first.flatMap(LiveJSON.object)?["session"] as? [String: Any]
        return ((session?["audio"] as? [String: Any])?["input"] as? [String: Any])?["transcription"] as? [String: Any]
    }
}
