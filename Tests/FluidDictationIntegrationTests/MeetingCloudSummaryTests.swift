@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingCloudSummaryTests: XCTestCase {
    private let openRouterURL = "https://openrouter.ai/api/v1"

    func testSelectedProviderWithKeyIsUsed() {
        let route = self.resolve(
            provider: DictationProviderRoute(providerID: "groq", providerKey: "groq", baseURL: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-120b", apiKey: "groq-key"),
            openRouterSpeechKey: "voice-key"
        )
        XCTAssertEqual(route, MeetingCloudSummaryRoute(
            providerKey: "groq", providerName: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-120b", apiKey: "groq-key"
        ))
    }

    func testSelectedOpenRouterWithoutTextKeyUsesVoiceEngineKey() {
        let route = self.resolve(
            provider: DictationProviderRoute(providerID: "openrouter", providerKey: "openrouter", baseURL: self.openRouterURL, model: "openai/gpt-oss-20b", apiKey: ""),
            openRouterSpeechKey: " voice-key "
        )
        XCTAssertEqual(route?.model, "openai/gpt-oss-20b")
        XCTAssertEqual(route?.apiKey, "voice-key")
    }

    func testSelectedOpenRouterPrefersItsTextKeyOverItsSpeechKey() {
        let route = self.resolve(
            provider: DictationProviderRoute(providerID: "openrouter", providerKey: "openrouter", baseURL: self.openRouterURL, model: "openai/gpt-oss-20b", apiKey: "text-key"),
            openRouterSpeechKey: "voice-key"
        )
        XCTAssertEqual(route?.apiKey, "text-key")
    }

    func testVoiceEngineReplacesTheHiddenOpenRouterTextModel() {
        let route = self.resolve(
            provider: DictationProviderRoute(providerID: "openrouter", providerKey: "openrouter", baseURL: self.openRouterURL, model: "openai/gpt-oss-20b", apiKey: ""),
            usesVoiceEngine: true,
            openRouterSpeechKey: "voice-key",
            openRouterModel: "google/gemini-3.8-flash"
        )
        XCTAssertEqual(route, MeetingCloudSummaryRoute(
            providerKey: "openrouter", providerName: "OpenRouter", baseURL: self.openRouterURL, model: "google/gemini-3.8-flash", apiKey: "voice-key"
        ))
    }

    func testVoiceEngineKeepsAnotherSelectedProvider() {
        let route = self.resolve(
            provider: DictationProviderRoute(providerID: "groq", providerKey: "groq", baseURL: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-120b", apiKey: "groq-key"),
            usesVoiceEngine: true,
            openRouterSpeechKey: "voice-key"
        )
        XCTAssertEqual(route?.providerKey, "groq")
    }

    func testMissingProviderFallsBackToOpenRouterVoiceEngine() {
        let route = self.resolve(
            provider: DictationProviderRoute(providerID: "", providerKey: "", baseURL: "", model: "", apiKey: ""),
            openRouterSpeechKey: "voice-key",
            openRouterModel: "google/gemini-3.8-flash"
        )
        XCTAssertEqual(route, MeetingCloudSummaryRoute(
            providerKey: "openrouter", providerName: "OpenRouter", baseURL: self.openRouterURL, model: "google/gemini-3.8-flash", apiKey: "voice-key"
        ))
    }

    func testFluidIntelligenceRouteFallsBackToOpenRouterVoiceEngine() {
        let privateID = PrivateAIProviderFeature.shared.providerID
        let route = self.resolve(
            provider: DictationProviderRoute(providerID: privateID, providerKey: privateID, baseURL: "", model: "local", apiKey: ""),
            openRouterSpeechKey: "voice-key",
            openRouterModel: "google/gemini-3.8-flash"
        )
        XCTAssertEqual(route?.providerKey, "openrouter")
    }

    func testRemoteProviderWithoutAnyKeyIsUnavailable() {
        let route = self.resolve(
            provider: DictationProviderRoute(providerID: "openai", providerKey: "openai", baseURL: "https://api.openai.com/v1", model: "gpt-5", apiKey: ""),
            openRouterSpeechKey: ""
        )
        XCTAssertNil(route)
    }

    func testLocalEndpointNeedsNoKey() {
        let route = self.resolve(
            provider: DictationProviderRoute(providerID: "ollama", providerKey: "ollama", baseURL: "http://localhost:11434/v1", model: "llama3", apiKey: ""),
            isLocalEndpoint: true,
            openRouterSpeechKey: ""
        )
        XCTAssertEqual(route?.model, "llama3")
        XCTAssertEqual(route?.apiKey, "")
    }

    func testCloudEngineKeepsSummariesFromAnyCloudModelButNotOnDeviceOnes() {
        let route = MeetingCloudSummaryRoute(providerKey: "openrouter", providerName: "OpenRouter", baseURL: self.openRouterURL, model: "a", apiKey: "k")
        let cloud = MeetingSummaryEngine.cloud(route)
        XCTAssertEqual(cloud.savedModelID, "cloud:openrouter:a")
        XCTAssertTrue(cloud.accepts(savedModelID: "cloud:groq:b"))
        XCTAssertFalse(cloud.accepts(savedModelID: "fluid-summary-1"))
        let local = MeetingSummaryEngine.onDevice(modelID: "fluid-summary-1")
        XCTAssertTrue(local.accepts(savedModelID: "fluid-summary-1"))
        XCTAssertFalse(local.accepts(savedModelID: "cloud:openrouter:a"))
    }

    func testEveryKindHasItsOwnTaskAndSharedRules() {
        let prompts = MeetingSummaryKind.allCases.map(MeetingCloudSummaryPrompt.systemPrompt(for:))
        XCTAssertEqual(Set(prompts).count, MeetingSummaryKind.allCases.count)
        for prompt in prompts {
            XCTAssertTrue(prompt.contains("Never invent names"))
            XCTAssertTrue(prompt.contains("Task: "))
        }
        XCTAssertTrue(MeetingCloudSummaryPrompt.systemPrompt(for: .actions).contains("- [ ]"))
    }

    func testSummarySendsTranscriptAsUserMessageAndStreamsContent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeetingSummaryStreamURLProtocol.self]
        let client = LLMClient(session: URLSession(configuration: configuration))
        let route = MeetingCloudSummaryRoute(
            providerKey: "openrouter", providerName: "OpenRouter", baseURL: "https://meeting-summary.test/api/v1", model: "openai/gpt-oss-20b", apiKey: "secret"
        )
        let chunks = MeetingSummaryChunkRecorder()

        let text = try await MeetingCloudSummaryService.summarize(
            transcript: "Title: Planning\n----------\n**Maya**: Ship on Friday.",
            kind: .decisions,
            route: route,
            extraParameters: ["reasoning_effort": "low"],
            sendsTemperature: false,
            client: client
        ) { chunks.append($0) }

        XCTAssertEqual(text, "- Ship on Friday.")
        XCTAssertEqual(chunks.joined, "- Ship on Friday.")
        let request = try XCTUnwrap(MeetingSummaryStreamURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://meeting-summary.test/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(MeetingSummaryStreamURLProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "openai/gpt-oss-20b")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertNil(body["temperature"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.first?["content"], MeetingCloudSummaryPrompt.systemPrompt(for: .decisions))
        XCTAssertEqual(messages.last?["content"], "Title: Planning\n----------\n**Maya**: Ship on Friday.")
    }

    /// The key migration filled an empty OpenAI text entry with the Live OpenAI key. Before the update that
    /// provider had no text key and summaries went to OpenRouter; they still do until the key is
    /// text-verified or saved again.
    func testAKeyTheMigrationCopiedFromAVoiceEntryWaitsForTextVerification() {
        let openAI = DictationProviderRoute(providerID: "openai", providerKey: "openai", baseURL: "https://api.openai.com/v1", model: "gpt-5-mini", apiKey: "live-key")
        let unconfirmed = self.resolve(provider: openAI, keyAwaitsTextVerification: true, openRouterSpeechKey: "voice-key")
        XCTAssertEqual(unconfirmed?.providerKey, "openrouter")
        XCTAssertEqual(unconfirmed?.apiKey, "voice-key")

        let noFallback = self.resolve(provider: openAI, keyAwaitsTextVerification: true, openRouterSpeechKey: "")
        XCTAssertNil(noFallback, "The copied key is never used for a summary while it waits")

        XCTAssertEqual(self.resolve(provider: openAI, openRouterSpeechKey: "voice-key")?.providerKey, "openai")

        let openRouter = DictationProviderRoute(providerID: "openrouter", providerKey: "openrouter", baseURL: self.openRouterURL, model: "openai/gpt-oss-20b", apiKey: "voice-key")
        XCTAssertEqual(
            self.resolve(provider: openRouter, keyAwaitsTextVerification: true, openRouterSpeechKey: "voice-key")?.model,
            "openai/gpt-oss-20b",
            "OpenRouter summaries used the Voice Engine key before the update too"
        )
    }

    private func resolve(
        provider: DictationProviderRoute,
        isLocalEndpoint: Bool = false,
        usesVoiceEngine: Bool = false,
        keyAwaitsTextVerification: Bool = false,
        openRouterSpeechKey: String,
        openRouterModel: String? = "google/gemini-3.8-flash"
    ) -> MeetingCloudSummaryRoute? {
        MeetingCloudSummaryRouteResolver.resolve(
            provider: provider,
            isLocalEndpoint: isLocalEndpoint,
            usesVoiceEngine: usesVoiceEngine,
            keyAwaitsTextVerification: keyAwaitsTextVerification,
            providerName: ModelRepository.shared.displayName(for: provider.providerID),
            openRouterSpeechKey: openRouterSpeechKey,
            openRouterModel: openRouterModel,
            openRouterBaseURL: self.openRouterURL
        )
    }
}

private final nonisolated class MeetingSummaryChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []

    var joined: String {
        self.lock.withLock { self.chunks.joined() }
    }

    func append(_ chunk: String) {
        self.lock.withLock { self.chunks.append(chunk) }
    }
}

private class MeetingSummaryStreamURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    private static let fixture = #"""
    data: {"choices":[{"index":0,"delta":{"reasoning":"Find decisions."}}]}

    data: {"choices":[{"index":0,"delta":{"content":"- Ship "}}]}

    data: {"choices":[{"index":0,"delta":{"content":"on Friday."},"finish_reason":"stop"}]}

    data: [DONE]

    """#

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "meeting-summary.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest = self.request
        Self.lastBody = self.request.httpBody ?? self.request.httpBodyStream.map(Self.read)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.fixture.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
