#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

final class CloudTranscriptionAudioDictationTests: XCTestCase {
    func testCombinedRequestContainsAudioStyleAndStrictSchemaInOnePost() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], try Self.response(transcript: "um hello world", text: "Hello, world.", cost: 0.002))
        }
        let instructions = CloudAudioDictationInstructions(
            modelID: CloudAudioDictationModel.defaultID,
            promptText: "Use sentence case and remove filler words.",
            appContext: "Email composer",
            precedingText: "Dear colleague,",
            spokenSendPhrase: "send message"
        )
        let result = try await self.client().transcribe(
            samples: [Float](repeating: 0.1, count: 16_000),
            configuration: .init(languageCode: "de", audioDictation: instructions),
            apiKey: "test-key",
            wordTimings: false
        )
        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, instructions.modelID)
        let provider = try XCTUnwrap(body["provider"] as? [String: Any])
        XCTAssertEqual(provider["require_parameters"] as? Bool, true)
        XCTAssertEqual(provider["allow_fallbacks"] as? Bool, false)
        XCTAssertNil(body["models"])
        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["strict"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(system.contains("Use sentence case and remove filler words."))
        XCTAssertTrue(system.contains("Never answer"))
        XCTAssertTrue(system.contains("de"))
        let userContent = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let audio = try XCTUnwrap(userContent.first { $0["type"] as? String == "input_audio" }?["input_audio"] as? [String: String])
        XCTAssertEqual(audio["format"], "wav")
        let wav = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(audio["data"])))
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .utf8), "RIFF")
        let context = try XCTUnwrap(userContent.first { $0["type"] as? String == "text" }?["text"] as? String)
        XCTAssertTrue(context.contains("Email composer"))
        XCTAssertTrue(context.contains("Dear colleague,"))
        XCTAssertEqual(result.text, "um hello world")
        XCTAssertEqual(result.dictationOutput?.transcript, "um hello world")
        XCTAssertEqual(result.dictationOutput?.text, "Hello, world.")
        XCTAssertEqual(result.dictationOutput?.modelID, instructions.modelID)
        XCTAssertEqual(result.dictationOutput?.styleApplied, true)
        XCTAssertEqual(result.usage?.cost, 0.002)
        XCTAssertEqual(result.usage?.seconds, 1)
        XCTAssertEqual(result.requestID, "generation-combined")
        XCTAssertNil(result.words)
    }

    func testCleanupOffUsesRawTranscriptEvenIfModelReturnsChangedText() async throws {
        CloudURLProtocol.install { _ in (200, [:], try Self.response(transcript: "Hallo\nWelt.", text: "Hello world.")) }
        let result = try await self.client().transcribe(
            samples: [0.1], configuration: self.configuration(prompt: nil), apiKey: "test-key", wordTimings: false
        )
        XCTAssertEqual(result.text, "Hallo\nWelt.")
        XCTAssertEqual(result.dictationOutput?.text, result.text)
        XCTAssertEqual(result.dictationOutput?.styleApplied, false)
    }

    func testCombinedLanguageHintsKeepAutomaticDetectionInOneRequest() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], try Self.response(transcript: "Bonjour, monde.", text: "Bonjour, monde."))
        }
        let configuration = CloudTranscriptionConfiguration(
            primaryLanguageCode: "de",
            secondaryLanguageCode: "pt",
            audioDictation: .init(modelID: CloudAudioDictationModel.defaultID, promptText: nil)
        )
        let result = try await self.client().transcribe(samples: [0.1], configuration: configuration, apiKey: "test-key", wordTimings: false)
        XCTAssertEqual(result.dictationOutput?.text, "Bonjour, monde.")
        XCTAssertNil(configuration.languageCode)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.httpMethod, "POST")
        XCTAssertEqual(recorder.requests.first?.url?.path, "/api/v1/chat/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(recorder.requests.first?.httpBody)) as? [String: Any])
        XCTAssertNil(body["language"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(system.contains("German and Portuguese"))
        XCTAssertTrue(system.contains("Other languages may also be spoken"))
        XCTAssertTrue(system.contains("Detect the spoken language automatically"))
        XCTAssertTrue(system.contains("these hints do not request translation"))
        XCTAssertFalse(system.contains("Expected spoken language code:"))
    }

    func testInvalidCombinedLanguageHintsFailBeforeUpload() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], try Self.response(transcript: "unexpected", text: "unexpected"))
        }
        let instructions = CloudAudioDictationInstructions(modelID: CloudAudioDictationModel.defaultID, promptText: nil)
        for configuration in [
            CloudTranscriptionConfiguration(primaryLanguageCode: "invalid", audioDictation: instructions),
            CloudTranscriptionConfiguration(primaryLanguageCode: "de", secondaryLanguageCode: "invalid", audioDictation: instructions),
        ] {
            do {
                _ = try await self.client().transcribe(samples: [0.1], configuration: configuration, apiKey: "test-key", wordTimings: false)
                XCTFail("Invalid primary or secondary language hints must fail before uploading audio")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, .invalidLanguage)
            }
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testAuthoredTemplateSupportsTranslationOfFinalTextAndEveryTranscriptPlaceholder() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], try Self.response(transcript: "Guten Morgen.", text: "Good morning."))
        }
        let template = "Translate ${transcript} into English. Use ${transcript} as the only source."
        let result = try await self.client().transcribe(
            samples: [0.1], configuration: self.configuration(prompt: template), apiKey: "test-key", wordTimings: false
        )
        XCTAssertEqual(result.text, "Guten Morgen.")
        XCTAssertEqual(result.dictationOutput?.text, "Good morning.")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(recorder.requests.first?.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(system.contains("Each literal ${transcript}"))
        XCTAssertTrue(system.contains("at every occurrence"))
        XCTAssertTrue(system.contains("Never emit an unresolved placeholder"))
        XCTAssertTrue(system.contains("Translate only the final text when the cleanup style explicitly requests translation"))
        XCTAssertTrue(system.contains(template))
    }

    func testBlankAuthoredStyleStaysDistinctFromCleanupOff() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], try Self.response(transcript: "raw words", text: "raw words"))
        }
        let configuration = self.configuration(prompt: "")
        XCTAssertEqual(configuration.audioDictation?.promptText, "")
        let result = try await self.client().transcribe(samples: [0.1], configuration: configuration, apiKey: "test-key", wordTimings: false)
        XCTAssertEqual(result.dictationOutput?.styleApplied, true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(recorder.requests.first?.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertFalse(system.contains("Cleanup is OFF"))
    }

    func testLongCombinedRecordingFailsBeforeUploadAndNeverChunks() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], try Self.response(transcript: "unexpected", text: "unexpected"))
        }
        let engine = CloudTranscriptionEngine(client: self.client(), cacheDirectory: nil)
        do {
            _ = try await engine.transcribe(
                samples: [Float](repeating: 0.1, count: 120 * 16_000 + 1),
                configuration: self.configuration(),
                apiKey: "test-key",
                wordTimings: false
            )
            XCTFail("Combined dictation exceeding 120 seconds must fail locally")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .dictationTooLong)
            XCTAssertTrue(error.localizedDescription.contains("120 seconds"))
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    @MainActor
    func testCombinedEngineAndProviderPreserveBothOutputsWithoutCaching() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], try Self.response(transcript: "raw transcript", text: "Final text."))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = CloudTranscriptionProvider(configuration: self.configuration(), apiKey: "test-key", cacheDirectory: directory, client: self.client())
        let result = try await provider.transcribeFinal([0.1])
        XCTAssertEqual(result.text, "raw transcript")
        XCTAssertEqual(result.cloudDictationOutput?.text, "Final text.")
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDiscoveryRequiresLiveAudioTextAndStructuredOutputCapabilities() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            if request.url?.path == "/api/v1/key" { return (200, [:], Data(#"{"data":{}}"#.utf8)) }
            let catalog = #"""
            {"data":[
                {"id":"google/gemini-3.8-flash","name":"Gemini Flash",
                 "architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]},
                {"id":"google/gemini-3.1-pro-preview","name":"Missing audio",
                 "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]},
                {"id":"google/gemini-3.5-flash-lite","name":"Missing schema",
                 "architecture":{"input_modalities":["audio"],"output_modalities":["text"]},
                 "supported_parameters":["response_format"]},
                {"id":"unknown/audio-model",
                 "architecture":{"input_modalities":["audio"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]}
            ]}
            """#
            return (200, [:], Data(catalog.utf8))
        }
        let models = try await self.client().validateAudioDictation(apiKey: "test-key")
        XCTAssertEqual(models.map(\.id), [CloudAudioDictationModel.defaultID])
        XCTAssertEqual(recorder.requests.map { $0.url?.path }, ["/api/v1/key", "/api/v1/models"])
    }

    func testMalformedAndTruncatedResponsesDoNotRetry() async throws {
        for (response, expected) in [
            (Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"not json"}}]}"#.utf8), CloudTranscriptionError.malformedResponse),
            (Data(#"{"choices":[{"finish_reason":"length","message":{"content":"{}"}}]}"#.utf8), .truncatedDictationResponse),
            (try Self.responseObject(["text": "missing transcript"]), .malformedResponse),
            (try Self.responseObject(["transcript": "raw", "text": "final", "extra": true]), .malformedResponse),
            (try Self.responseObject(["transcript": "raw", "text": ""]), .malformedResponse),
            (try Self.responseObject(["transcript": "", "text": "invented content"]), .malformedResponse),
        ] {
            let recorder = CloudRequestRecorder()
            CloudURLProtocol.install { request in recorder.append(request); return (200, [:], response) }
            do {
                _ = try await self.client().transcribe(samples: [0.1], configuration: self.configuration(), apiKey: "test-key", wordTimings: false)
                XCTFail("Invalid structured output must fail without another AI request")
            } catch { XCTAssertEqual(error as? CloudTranscriptionError, expected) }
            XCTAssertEqual(recorder.requests.count, 1)
        }
    }

    func testCombinedErrorsAndCancellationNeverFallback() async throws {
        for (status, expected) in [(401, CloudTranscriptionError.authentication), (402, .creditsExhausted), (429, .rateLimited), (404, .modelUnavailable)] {
            let recorder = CloudRequestRecorder()
            CloudURLProtocol.install { request in
                recorder.append(request)
                return (status, [:], Data(#"{"error":{"message":"PRIVATE audio and test-key"}}"#.utf8))
            }
            do {
                _ = try await self.client().transcribe(samples: [0.1], configuration: self.configuration(), apiKey: "test-key", wordTimings: false)
                XCTFail("Expected mapped HTTP error")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, expected)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
            }
            XCTAssertEqual(recorder.requests.count, 1)
        }
        let started = self.expectation(description: "Combined request started")
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in recorder.append(request); started.fulfill(); return (0, [:], Data()) }
        let client = self.client()
        let configuration = self.configuration()
        let task = Task { try await client.transcribe(samples: [0.1], configuration: configuration, apiKey: "test-key", wordTimings: false) }
        await self.fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must discard output") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testLegacyConfigurationAndResultDecodeWithoutCombinedFields() throws {
        let configuration = try JSONDecoder().decode(CloudTranscriptionConfiguration.self, from: Data(#"{"modelID":"openai/whisper-large-v3-turbo"}"#.utf8))
        XCTAssertNil(configuration.audioDictation)
        let result = try JSONDecoder().decode(CloudTranscriptionResult.self, from: Data(#"{"text":"legacy","processingDuration":1}"#.utf8))
        XCTAssertNil(result.dictationOutput)
    }

    private func client() -> OpenRouterTranscriptionClient { .init(session: CloudURLProtocol.session(), recordsUsage: false) }
    private func configuration(prompt: String? = "Remove filler words.") -> CloudTranscriptionConfiguration {
        .init(audioDictation: .init(modelID: CloudAudioDictationModel.defaultID, promptText: prompt))
    }
    private nonisolated static func response(transcript: String, text: String, cost: Double? = nil) throws -> Data {
        try self.responseObject(["transcript": transcript, "text": text], cost: cost)
    }
    private nonisolated static func responseObject(_ content: [String: Any], cost: Double? = nil) throws -> Data {
        let encoded = try JSONSerialization.data(withJSONObject: content)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        var response: [String: Any] = ["id": "generation-combined", "choices": [["finish_reason": "stop", "message": ["content": json]]]]
        if let cost { response["usage"] = ["cost": cost] }
        return try JSONSerialization.data(withJSONObject: response)
    }
}
