#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

final class MistralTranscriptionClientTests: XCTestCase {
    private let configuration = CloudTranscriptionConfiguration(providerID: "mistral", modelID: "voxtral-mini-latest")

    func testMultipartContractAndText() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"model":"voxtral-mini-2507","text":"Bonjour.","language":"fr","segments":[]}"#.utf8))
        }
        let result = try await self.client().transcribe(
            samples: [Float](repeating: 0.1, count: 16_000),
            configuration: .init(providerID: "mistral", modelID: "voxtral-mini-latest", languageCode: "fr"),
            apiKey: "ms-key",
            wordTimings: false
        )
        XCTAssertEqual(result.text, "Bonjour.")
        XCTAssertNil(result.words)
        XCTAssertNil(result.usage)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ms-key")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertTrue(CloudMultipartAssert.contains(body, field: "model", value: "voxtral-mini-latest"))
        XCTAssertTrue(CloudMultipartAssert.contains(body, field: "language", value: "fr"))
        XCTAssertNil(body.range(of: Data("timestamp_granularities".utf8)), "Timings cannot be combined with a language")
        XCTAssertNotNil(body.range(of: Data("filename=\"recording.flac\"\r\nContent-Type: audio/flac".utf8)))
    }

    func testAutomaticLanguageSendsNoLanguage() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"text":"Hi."}"#.utf8))
        }
        _ = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "ms-key", wordTimings: false)
        let body = try XCTUnwrap(recorder.requests.first?.httpBody)
        XCTAssertNil(body.range(of: Data("name=\"language\"".utf8)))
    }

    func testWordTimingsAreRefusedBeforeUploading() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data())
        }
        XCTAssertFalse(try XCTUnwrap(CloudTranscriptionCatalog.models(for: "mistral").first).supportsWordTimings)
        do {
            _ = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "ms-key", wordTimings: true)
            XCTFail("Mistral offers no word timings")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .unsupportedWordTimings)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testErrorsAreMapped() async throws {
        for (status, expected) in [(401, CloudTranscriptionError.authentication), (402, .creditsExhausted), (429, .rateLimited), (502, .server(502))] {
            CloudURLProtocol.install { _ in (status, [:], Data(#"{"message":"PRIVATE ms-key"}"#.utf8)) }
            do {
                _ = try await self.client().transcribe(samples: [0.1], configuration: self.configuration, apiKey: "ms-key", wordTimings: false)
                XCTFail("HTTP \(status) must fail")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, expected)
                let message = CloudTranscriptionError.message(for: error, providerName: "Mistral")
                XCTAssertTrue(message.contains("Mistral"))
                XCTAssertFalse(message.contains("PRIVATE"))
            }
        }
    }

    func testKeyCheckUsesTheModelsEndpoint() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"data":[]}"#.utf8))
        }
        try await self.client().checkKey(apiKey: "ms-key")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ms-key")
    }

    // MARK: - Engine

    func testEngineAcceptsTheDefaultModelAndRejectsAnUnknownOne() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"text":"ok"}"#.utf8))
        }
        let defaultModel = try XCTUnwrap(CloudTranscriptionCatalog.defaultModelID(for: "mistral"))
        let engine = CloudTranscriptionEngine(client: self.client(), cacheDirectory: nil)
        let result = try await engine.transcribe(samples: [0.1], configuration: .init(providerID: "mistral", modelID: defaultModel), apiKey: "ms-key", wordTimings: false)
        XCTAssertEqual(result.text, "ok")
        do {
            _ = try await engine.transcribe(samples: [0.1], configuration: .init(providerID: "mistral", modelID: "mistral-small-latest"), apiKey: "ms-key", wordTimings: false)
            XCTFail("An unknown model must be rejected")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .unsupportedModel)
        }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    private func client() -> MistralTranscriptionClient {
        MistralTranscriptionClient(session: CloudURLProtocol.session())
    }
}
