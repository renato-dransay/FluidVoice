#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

final class CloudTranscriptionClientTests: XCTestCase {
    func testMultipartContractAndReturnedUsage() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, ["X-Generation-Id": "request-123"], Data(#"{"text":"Hello.","words":[{"word":"Hello.","start":0,"end":0.4}],"usage":{"seconds":1,"cost":0.001}}"#.utf8))
        }
        let result = try await self.client().transcribe(
            samples: [Float](repeating: 0.1, count: 16_000),
            configuration: CloudTranscriptionConfiguration(languageCode: "de"),
            apiKey: "test-key",
            wordTimings: true
        )
        XCTAssertEqual(result.text, "Hello.")
        XCTAssertEqual(result.words?.first?.end, 0.4)
        XCTAssertEqual(result.usage?.cost, 0.001)
        XCTAssertEqual(result.requestID, "request-123")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(body.range(of: Data("name=\"timestamp_granularities[]\"\r\n\r\nword".utf8)))
        XCTAssertNotNil(body.range(of: Data("name=\"response_format\"\r\n\r\nverbose_json".utf8)))
        XCTAssertNotNil(body.range(of: Data("name=\"language\"\r\n\r\nde".utf8)))
        XCTAssertNotNil(body.range(of: Data("RIFF".utf8)))
    }

    func testPlainTextDoesNotRequestUnsupportedTiming() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"text":"A plain transcript."}"#.utf8))
        }
        let result = try await self.client().transcribe(
            samples: [0.1], configuration: CloudTranscriptionConfiguration(modelID: "openai/gpt-4o-transcribe"), apiKey: "test-key", wordTimings: false
        )
        XCTAssertNil(result.usage)
        let body = try XCTUnwrap(recorder.requests.first?.httpBody)
        XCTAssertNil(body.range(of: Data("timestamp_granularities".utf8)))
        XCTAssertNil(body.range(of: Data("name=\"language\"".utf8)))
    }

    func testAuthenticationCreditAndRateLimitErrorsAreActionableAndRedacted() async throws {
        for (status, expected) in [(401, CloudTranscriptionError.authentication), (402, .creditsExhausted), (429, .rateLimited)] {
            CloudURLProtocol.install { _ in
                (status, [:], Data(#"{"error":{"message":"PRIVATE transcript and test-key"}}"#.utf8))
            }
            do {
                _ = try await self.client().transcribe(samples: [0.1], configuration: .init(), apiKey: "test-key", wordTimings: false)
                XCTFail("Expected HTTP \(status) to fail")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, expected)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
                XCTAssertFalse(error.localizedDescription.contains("test-key"))
            }
        }
    }

    func testOptionalLanguageHintsUseProviderOptionsWithoutForcingLanguageOrRouting() async throws {
        for model in CloudTranscriptionModel.catalog {
            let recorder = CloudRequestRecorder()
            CloudURLProtocol.install { request in
                recorder.append(request)
                return (200, [:], Data(#"{"text":"Bonjour.","words":[{"word":"Bonjour.","start":0,"end":0.4}]}"#.utf8))
            }
            let configuration = CloudTranscriptionConfiguration(modelID: model.id, primaryLanguageCode: "pt", secondaryLanguageCode: "en")
            _ = try await self.client().transcribe(
                samples: [Float](repeating: 0.1, count: 16_000), configuration: configuration, apiKey: "test-key", wordTimings: model.supportsWordTimings
            )
            let request = try XCTUnwrap(recorder.requests.first)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, model.id)
            XCTAssertNil(body["language"], "Hints must allow a third language to be detected")
            XCTAssertNil(body["prompt"], "OpenRouter ignores top-level prompts")
            let provider = try XCTUnwrap(body["provider"] as? [String: Any])
            XCTAssertNil(provider["only"])
            XCTAssertNil(provider["order"])
            let options = try XCTUnwrap(provider["options"] as? [String: [String: String]])
            let expectedProviders: Set<String> = model.supportsWordTimings ? ["groq", "together"] : ["openai"]
            XCTAssertEqual(Set(options.keys), expectedProviders)
            for hint in options.values {
                XCTAssertTrue(hint["prompt"]?.contains("Portuguese and English") == true)
                XCTAssertTrue(hint["prompt"]?.contains("Other languages") == true)
            }
            let audio = try XCTUnwrap(body["input_audio"] as? [String: String])
            XCTAssertEqual(audio["format"], "wav")
            let wav = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(audio["data"])))
            XCTAssertEqual(String(data: wav.prefix(4), encoding: .utf8), "RIFF")
            XCTAssertEqual(body["response_format"] as? String, model.supportsWordTimings ? "verbose_json" : "json")
            XCTAssertEqual(body["timestamp_granularities"] as? [String], model.supportsWordTimings ? ["word"] : nil)
        }
    }

    func testInvalidHintDoesNotSendAudioAndLegacyConfigurationStillDecodes() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"text":"unexpected"}"#.utf8))
        }
        do {
            _ = try await self.client().transcribe(samples: [0.1], configuration: .init(primaryLanguageCode: "invalid"), apiKey: "test-key", wordTimings: false)
            XCTFail("Invalid hints must fail before uploading audio")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .invalidLanguage)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
        let oldConfiguration = Data(#"{"modelID":"openai/whisper-large-v3","languageCode":"de"}"#.utf8)
        let restored = try JSONDecoder().decode(CloudTranscriptionConfiguration.self, from: oldConfiguration)
        XCTAssertEqual(restored.languageCode, "de")
        XCTAssertNil(restored.primaryLanguageCode)
        XCTAssertNil(restored.secondaryLanguageCode)
    }

    func testMissingKeyAndUnsupportedModelDoNotSendAudio() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"text":"unexpected"}"#.utf8))
        }
        for (configuration, key) in [(CloudTranscriptionConfiguration(), ""), (.init(modelID: "unknown/model"), "test-key")] {
            do {
                _ = try await self.client().transcribe(samples: [0.1], configuration: configuration, apiKey: key, wordTimings: false)
                XCTFail("Invalid configuration must fail locally")
            } catch {}
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testMalformedAndInvalidWordTimingsFailExplicitly() async throws {
        let responses = [
            #"{"invalid":true}"#,
            #"{"text":"spoken","words":[]}"#,
            #"{"text":"spoken","words":[{"word":"spoken","start":-1,"end":0.5}]}"#,
            #"{"text":"spoken","words":[{"word":"spoken","start":0.8,"end":0.5}]}"#,
            #"{"text":"spoken","words":[{"word":"spoken","start":0,"end":500}]}"#,
        ]
        for response in responses {
            CloudURLProtocol.install { _ in (200, [:], Data(response.utf8)) }
            do {
                _ = try await self.client().transcribe(samples: [Float](repeating: 0.1, count: 16_000), configuration: .init(), apiKey: "test-key", wordTimings: true)
                XCTFail("Invalid timed response must not create synthetic timestamps")
            } catch {
                XCTAssertNotNil(error as? CloudTranscriptionError)
            }
        }
    }

    func testSilentTimedResponseAllowsEmptyWords() async throws {
        CloudURLProtocol.install { _ in (200, [:], Data(#"{"text":"","words":[]}"#.utf8)) }
        let result = try await self.client().transcribe(samples: [0], configuration: .init(), apiKey: "test-key", wordTimings: true)
        XCTAssertTrue(result.words?.isEmpty == true)
    }

    func testValidationAuthenticatesBeforeFilteringCatalog() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            if request.url?.path == "/api/v1/key" {
                return (200, [:], Data(#"{"data":{"is_free_tier":false}}"#.utf8))
            }
            return (200, [:], Data(#"{"data":[{"id":"openai/whisper-large-v3"},{"id":"unknown/new-model"}]}"#.utf8))
        }
        let models = try await self.client().validate(apiKey: "test-key")
        XCTAssertEqual(models.map(\.id), ["openai/whisper-large-v3"])
        XCTAssertEqual(recorder.requests.map { $0.url?.path }, ["/api/v1/key", "/api/v1/models"])
        XCTAssertEqual(recorder.requests.last?.url?.query, "output_modalities=transcription")
    }

    func testCancellationAndTimeoutRemainDistinct() async throws {
        for code in [URLError.cancelled, URLError.timedOut] {
            CloudURLProtocol.install { _ in throw URLError(code) }
            do {
                _ = try await self.client().transcribe(samples: [0.1], configuration: .init(), apiKey: "test-key", wordTimings: false)
                XCTFail("Expected transport failure")
            } catch {
                if code == .cancelled {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertEqual(error as? CloudTranscriptionError, .timeout)
                }
            }
        }
    }

    func testAccountProviderRestrictionIsActionableWithoutExposingServerDetails() async throws {
        CloudURLProtocol.install { _ in
            (404, [:], Data(#"{"error":{"message":"No allowed providers available. PRIVATE_ACCOUNT_DETAILS"}}"#.utf8))
        }
        do {
            _ = try await self.client().transcribe(samples: [0.1], configuration: .init(), apiKey: "test-key", wordTimings: false)
            XCTFail("Restricted model should fail explicitly")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .modelUnavailable)
            XCTAssertTrue(error.localizedDescription.contains("allowed providers"))
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE_ACCOUNT_DETAILS"))
        }
    }

    func testCancellingActiveRequestReturnsNoTranscript() async throws {
        let started = self.expectation(description: "Request started")
        CloudURLProtocol.install { _ in
            started.fulfill()
            return (0, [:], Data()) // Deliberately leave the request pending until cancellation.
        }
        let client = self.client()
        let task = Task {
            try await client.transcribe(samples: [0.1], configuration: .init(), apiKey: "test-key", wordTimings: false)
        }
        await self.fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled requests must not return text for insertion")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func client() -> OpenRouterTranscriptionClient {
        OpenRouterTranscriptionClient(session: CloudURLProtocol.session(), recordsUsage: false)
    }
}

final class CloudRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { self.lock.withLock { self.storage } }
    func append(_ request: URLRequest) { self.lock.withLock { self.storage.append(request) } }
}

final class CloudURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(_ handler: @escaping Handler) { self.lock.withLock { self.handler = handler } }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var request = self.request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                request.httpBody = data
            }
            let handler = try XCTUnwrap(Self.lock.withLock { Self.handler })
            let (status, headers, data) = try handler(request)
            if status == 0 { return }
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: headers))
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
