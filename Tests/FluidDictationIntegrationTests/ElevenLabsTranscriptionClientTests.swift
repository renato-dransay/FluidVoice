#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

final class ElevenLabsTranscriptionClientTests: XCTestCase {
    private let configuration = CloudTranscriptionConfiguration(providerID: "elevenlabs", modelID: "scribe_v2")

    func testMultipartContractAndOnlyWordsKeepTheirTimes() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, ["request-id": "el-1"], Data(#"""
            {"language_code":"en","text":"Hello there.","words":[
            {"text":"Hello","start":0.1,"end":0.4,"type":"word"},
            {"text":" ","start":0.4,"end":0.5,"type":"spacing"},
            {"text":"(laughs)","start":0.5,"end":0.6,"type":"audio_event"},
            {"text":"there.","start":0.6,"end":0.9,"type":"word"}]}
            """#.utf8))
        }
        let result = try await self.client().transcribe(
            samples: [Float](repeating: 0.1, count: 16_000),
            configuration: .init(providerID: "elevenlabs", modelID: "scribe_v2", languageCode: "fr"),
            apiKey: "el-key",
            wordTimings: true
        )
        XCTAssertEqual(result.text, "Hello there.")
        XCTAssertEqual(result.words, [
            CloudTranscriptionWord(word: "Hello", start: 0.1, end: 0.4),
            CloudTranscriptionWord(word: "there.", start: 0.6, end: 0.9),
        ])
        XCTAssertEqual(result.requestID, "el-1")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "el-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertTrue(CloudMultipartAssert.contains(body, field: "model_id", value: "scribe_v2"))
        XCTAssertTrue(CloudMultipartAssert.contains(body, field: "language_code", value: "fr"))
        XCTAssertTrue(CloudMultipartAssert.contains(body, field: "timestamps_granularity", value: "word"))
        XCTAssertTrue(CloudMultipartAssert.contains(body, field: "tag_audio_events", value: "false"))
        XCTAssertNotNil(body.range(of: Data("name=\"file\"; filename=\"recording.flac\"\r\nContent-Type: audio/flac".utf8)))
    }

    func testAutomaticLanguageSendsNoLanguageAndPlainTextAsksForNoTimings() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"text":"Plain."}"#.utf8))
        }
        let result = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "el-key", wordTimings: false)
        XCTAssertEqual(result.text, "Plain.")
        XCTAssertNil(result.words)
        let body = try XCTUnwrap(recorder.requests.first?.httpBody)
        XCTAssertNil(body.range(of: Data("name=\"language_code\"".utf8)))
        XCTAssertTrue(CloudMultipartAssert.contains(body, field: "timestamps_granularity", value: "none"))
    }

    func testErrorsAreMappedAndARefusedKeyMentionsItsPermission() async throws {
        let cases: [(Int, String, CloudTranscriptionError)] = [
            (401, #"{"detail":{"type":"authentication_error","code":"invalid_api_key","message":"PRIVATE"}}"#, .authentication),
            (403, #"{"detail":{"type":"authorization_error","code":"insufficient_permissions","message":"PRIVATE"}}"#, .authentication),
            (402, #"{"detail":{"type":"payment_required","code":"insufficient_credits","message":"PRIVATE"}}"#, .creditsExhausted),
            (401, #"{"detail":{"status":"quota_exceeded","message":"PRIVATE"}}"#, .creditsExhausted),
            (429, #"{"detail":{"type":"rate_limit_error","code":"rate_limit_exceeded"}}"#, .rateLimited),
            (500, "PRIVATE", .server(500)),
        ]
        for (status, body, expected) in cases {
            CloudURLProtocol.install { _ in (status, [:], Data(body.utf8)) }
            do {
                _ = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "el-key", wordTimings: false)
                XCTFail("HTTP \(status) must fail")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, expected, "HTTP \(status) \(body)")
                XCTAssertFalse(CloudTranscriptionError.message(for: error, providerName: "ElevenLabs").contains("PRIVATE"))
            }
        }
        XCTAssertTrue(CloudTranscriptionError.authentication.message(providerName: "ElevenLabs").contains("speech-to-text permission"))
        XCTAssertFalse(CloudTranscriptionError.authentication.message(providerName: "Deepgram").contains("permission"))
    }

    func testKeyCheckUsesTheModelsEndpoint() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data("[]".utf8))
        }
        try await self.client().checkKey(apiKey: "el-key")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "el-key")
    }

    /// A key limited to speech to text lacks `models_read`; ElevenLabs answers the model list with 403
    /// `insufficient_permissions`, which proves the key authenticated.
    func testKeyCheckAcceptsAKeyRestrictedToOtherEndpoints() async throws {
        let restricted = [
            #"{"detail":{"type":"authorization_error","code":"insufficient_permissions","message":"PRIVATE"}}"#,
            #"{"detail":{"status":"missing_permissions","message":"The API key you used is missing the permission models_read"}}"#,
        ]
        for body in restricted {
            CloudURLProtocol.install { _ in (403, [:], Data(body.utf8)) }
            try await self.client().checkKey(apiKey: "el-key")
        }
        let refused: [(Int, String, CloudTranscriptionError)] = [
            (401, #"{"detail":{"type":"authentication_error","code":"invalid_api_key","message":"PRIVATE"}}"#, .authentication),
            (403, #"{"detail":{"type":"authorization_error","code":"ip_not_allowed","message":"PRIVATE"}}"#, .authentication),
            (403, "PRIVATE", .authentication),
            (401, #"{"detail":{"status":"quota_exceeded","message":"PRIVATE"}}"#, .creditsExhausted),
        ]
        for (status, body, expected) in refused {
            CloudURLProtocol.install { _ in (status, [:], Data(body.utf8)) }
            do {
                try await self.client().checkKey(apiKey: "el-key")
                XCTFail("HTTP \(status) \(body) must fail the key check")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, expected, body)
            }
        }
    }

    func testMissingWordTimesFailATimedRequest() async throws {
        CloudURLProtocol.install { _ in (200, [:], Data(#"{"text":"No words."}"#.utf8)) }
        do {
            _ = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "el-key", wordTimings: true)
            XCTFail("Missing timings must fail")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .invalidWordTimings)
        }
    }

    // MARK: - Engine

    func testEngineAcceptsTheDefaultModelAndRejectsAnUnknownOne() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"text":"ok","words":[{"text":"ok","start":0.1,"end":0.5,"type":"word"}]}"#.utf8))
        }
        let defaultModel = try XCTUnwrap(CloudTranscriptionCatalog.defaultModelID(for: "elevenlabs"))
        let engine = CloudTranscriptionEngine(client: self.client(), cacheDirectory: nil)
        let result = try await engine.transcribe(
            samples: [Float](repeating: 0.1, count: 16_000),
            configuration: .init(providerID: "elevenlabs", modelID: defaultModel),
            apiKey: "el-key",
            wordTimings: true
        )
        XCTAssertEqual(result.words?.map(\.word), ["ok"])
        XCTAssertEqual(recorder.requests.count, 1)
        do {
            _ = try await engine.transcribe(samples: [0.1], configuration: .init(providerID: "elevenlabs", modelID: "scribe_v1"), apiKey: "el-key", wordTimings: false)
            XCTFail("An unknown model must be rejected")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .unsupportedModel)
        }
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(self.client().maximumRequestSeconds, 780)
    }

    private func client() -> ElevenLabsTranscriptionClient {
        ElevenLabsTranscriptionClient(session: CloudURLProtocol.session())
    }
}
