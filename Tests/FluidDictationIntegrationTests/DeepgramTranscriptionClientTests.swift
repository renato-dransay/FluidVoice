#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

final class DeepgramTranscriptionClientTests: XCTestCase {
    private let configuration = CloudTranscriptionConfiguration(providerID: "deepgram", modelID: "nova-3")

    func testRequestContractAndWordTimesInSeconds() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"""
            {"metadata":{"request_id":"req-1"},"results":{"channels":[{"alternatives":[{"transcript":"hello world","words":[
            {"word":"hello","punctuated_word":"Hello","start":0.08,"end":0.4},
            {"word":"world","punctuated_word":"world.","start":0.5,"end":0.9}]}]}]}}
            """#.utf8))
        }
        let result = try await self.client().transcribe(
            samples: [Float](repeating: 0.1, count: 16_000), configuration: self.configuration, apiKey: " dg-key ", wordTimings: true
        )
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.words, [
            CloudTranscriptionWord(word: "Hello", start: 0.08, end: 0.4),
            CloudTranscriptionWord(word: "world.", start: 0.5, end: 0.9),
        ])
        XCTAssertEqual(result.requestID, "req-1")
        XCTAssertNil(result.usage, "Usage is recorded for OpenRouter only")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.deepgram.com")
        XCTAssertEqual(components.path, "/v1/listen")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["model": "nova-3", "smart_format": "true", "detect_language": "true"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token dg-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/flac")
        XCTAssertEqual(request.httpBody?.prefix(4), Data("fLaC".utf8), "The raw audio is the whole body")
        XCTAssertEqual(request.timeoutInterval, 61, accuracy: 0.001, "60 s plus the audio's duration")
    }

    func testAChosenLanguageReplacesDetection() throws {
        let url = try XCTUnwrap(DeepgramTranscriptionClient.listenURL(configuration: .init(providerID: "deepgram", modelID: "nova-3", languageCode: "de", primaryLanguageCode: "de", secondaryLanguageCode: "en")))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "language" }?.value, "de")
        XCTAssertFalse(items.contains { $0.name == "detect_language" })
        XCTAssertFalse(items.contains { $0.name == "mip_opt_out" }, "Opting out of the Model Improvement Program would forfeit Deepgram's discount")
    }

    func testPlainTranscriptOmitsWordsAndMissingTimingsFail() async throws {
        CloudURLProtocol.install { _ in
            (200, [:], Data(#"{"results":{"channels":[{"alternatives":[{"transcript":"Plain text."}]}]}}"#.utf8))
        }
        let plain = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: false)
        XCTAssertEqual(plain.text, "Plain text.")
        XCTAssertNil(plain.words)
        do {
            _ = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "k", wordTimings: true)
            XCTFail("A timed request without word times must fail")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .invalidWordTimings)
        }
    }

    func testErrorsAreMappedAndCarryNoServerText() async throws {
        let cases: [(Int, String, CloudTranscriptionError)] = [
            (401, #"{"err_code":"INVALID_AUTH","err_msg":"PRIVATE dg-key"}"#, .authentication),
            (402, #"{"err_code":"ASR_PAYMENT_REQUIRED","err_msg":"PRIVATE no credits"}"#, .creditsExhausted),
            (429, #"{"err_code":"TOO_MANY_REQUESTS","err_msg":"PRIVATE"}"#, .rateLimited),
            (503, "PRIVATE upstream", .server(503)),
        ]
        for (status, body, expected) in cases {
            CloudURLProtocol.install { _ in (status, [:], Data(body.utf8)) }
            do {
                _ = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "dg-key", wordTimings: false)
                XCTFail("HTTP \(status) must fail")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, expected)
                let message = CloudTranscriptionError.message(for: error, providerName: "Deepgram")
                XCTAssertTrue(message.contains("Deepgram"), message)
                XCTAssertFalse(message.contains("PRIVATE"))
                XCTAssertFalse(message.contains("dg-key"))
            }
        }
        CloudURLProtocol.install { _ in throw URLError(.timedOut) }
        do {
            _ = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "dg-key", wordTimings: false)
            XCTFail("A timeout must fail")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .timeout)
        }
    }

    func testKeyCheckListsProjectsWithoutAudio() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"projects":[]}"#.utf8))
        }
        try await self.client().checkKey(apiKey: "dg-key")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepgram.com/v1/projects")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token dg-key")
        CloudURLProtocol.install { _ in (401, [:], Data()) }
        do {
            try await self.client().checkKey(apiKey: "dg-key")
            XCTFail("A rejected key must fail the check")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .authentication)
        }
    }

    func testOtherProvidersConfigurationsAndMissingKeysSendNothing() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data())
        }
        for (configuration, key) in [
            (CloudTranscriptionConfiguration(), "k"),
            (CloudTranscriptionConfiguration(providerID: "deepgram", modelID: "nova-2"), "k"),
            (self.configuration, " "),
        ] {
            do {
                _ = try await self.client().transcribe(samples: [0.1], configuration: configuration, apiKey: key, wordTimings: false)
                XCTFail("Must fail before sending")
            } catch {}
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    // MARK: - Engine

    func testEngineValidatesTheDefaultModelAndChunksAtTheClientsLimit() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"results":{"channels":[{"alternatives":[{"transcript":"part"}]}]}}"#.utf8))
        }
        let configuration = CloudTranscriptionConfiguration(
            providerID: "deepgram", modelID: try XCTUnwrap(CloudTranscriptionCatalog.defaultModelID(for: "deepgram"))
        )
        XCTAssertNoThrow(try configuration.validate(wordTimings: true))
        let engine = CloudTranscriptionEngine(client: self.client(), cacheDirectory: nil)
        // 800 s is one 780-second chunk and the rest, where OpenRouter's 120-second requests would need seven.
        let result = try await engine.transcribe(samples: [Float](repeating: 0.1, count: 16_000 * 800), configuration: configuration, apiKey: "k", wordTimings: false)
        XCTAssertEqual(result.text, "part part")
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue(recorder.requests.allSatisfy { $0.url?.host == "api.deepgram.com" })
        XCTAssertEqual(CloudAudioChunker.chunks(samples: [Float](repeating: 0.1, count: 16_000 * 800), wordTimings: false).count, 7)
    }

    func testEngineRejectsAnUnknownModelAndAForeignClient() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data())
        }
        let engine = CloudTranscriptionEngine(client: self.client(), cacheDirectory: nil)
        for configuration in [
            CloudTranscriptionConfiguration(providerID: "deepgram", modelID: "whisper-1"),
            CloudTranscriptionConfiguration(providerID: "elevenlabs", modelID: "scribe_v2"),
        ] {
            do {
                _ = try await engine.transcribe(samples: [0.1], configuration: configuration, apiKey: "k", wordTimings: false)
                XCTFail("Must be rejected")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, .unsupportedModel)
            }
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    private func client() -> DeepgramTranscriptionClient {
        DeepgramTranscriptionClient(session: CloudURLProtocol.session())
    }
}
