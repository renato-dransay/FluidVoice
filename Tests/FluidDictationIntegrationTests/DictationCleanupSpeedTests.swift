@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The dictation cleanup speed-ups: request options, the transport's repeats, the warm-up policy and
/// the Reasoning row's wording.
@MainActor
final class DictationCleanupSpeedTests: XCTestCase {
    private typealias Options = TextRequestOptions

    override func setUp() {
        super.setUp()
        Options.resetSuppressionForTesting()
    }

    override func tearDown() {
        Options.resetSuppressionForTesting()
        super.tearDown()
    }

    private static let google = "https://generativelanguage.googleapis.com/v1beta/openai"
    private static let openAI = "https://api.openai.com/v1"
    private static let groq = "https://api.groq.com/openai/v1"
    private static let openRouter = "https://openrouter.ai/api/v1"

    private func resolve(
        _ purpose: TextRequestPurpose = .dictationCleanup,
        baseURL: String,
        model: String,
        transcript: String? = "hello there",
        saved: Options.Saved = .nothing,
        lowReasoning: Bool = true,
        predicted: Bool = true,
        suppressed: Bool = false
    ) -> Options {
        Options.resolve(Options.Input(
            purpose: purpose,
            baseURL: baseURL,
            model: model,
            transcript: transcript,
            saved: saved,
            lowReasoningEnabled: lowReasoning,
            predictedOutputsEnabled: predicted,
            suppressed: suppressed
        ))
    }

    private func effort(_ value: String) -> Options.Reasoning {
        Options.Reasoning(name: "reasoning_effort", value: .string(value))
    }

    // MARK: - Built-in default (characterisation of today's rules)

    func testBuiltInDefaultsMatchTodaysPresets() throws {
        XCTAssertEqual(Options.builtInDefault(forModel: "gpt-5.1"), self.effort("low"))
        XCTAssertEqual(Options.builtInDefault(forModel: "openai/gpt-5.1"), self.effort("low"))
        XCTAssertEqual(Options.builtInDefault(forModel: "o3"), self.effort("medium"))
        XCTAssertEqual(Options.builtInDefault(forModel: "openai/o3"), self.effort("low"), "the openai/ rule wins, as before")
        XCTAssertEqual(Options.builtInDefault(forModel: "openai/gpt-oss-120b"), self.effort("low"))
        XCTAssertEqual(Options.builtInDefault(forModel: "deepseek-reasoner"), Options.Reasoning(name: "enable_thinking", value: .bool(true)))
        XCTAssertNil(Options.builtInDefault(forModel: "gpt-4.1"))
        XCTAssertNil(Options.builtInDefault(forModel: "gpt-6-sol"))
        XCTAssertNil(Options.builtInDefault(forModel: "gemini-2.5-flash"))

        XCTAssertEqual(try SettingsStore.reasoningConfig(XCTUnwrap(Options.builtInDefault(forModel: "gpt-5.1"))), .openAIGPT5)
        XCTAssertEqual(try SettingsStore.reasoningConfig(XCTUnwrap(Options.builtInDefault(forModel: "o3"))), .openAIO1)
        XCTAssertEqual(try SettingsStore.reasoningConfig(XCTUnwrap(Options.builtInDefault(forModel: "gpt-oss-120b"))), .groqGPTOSS)
        XCTAssertEqual(try SettingsStore.reasoningConfig(XCTUnwrap(Options.builtInDefault(forModel: "deepseek-reasoner"))), .deepSeekReasoner)
    }

    func testGeneralRequestsSendTodaysParameters() {
        for (model, expected) in [("gpt-5.1", ["reasoning_effort": "low"]), ("o3", ["reasoning_effort": "medium"]), ("gpt-4.1", [:])] {
            let options = self.resolve(.general, baseURL: Self.openAI, model: model, transcript: nil)
            XCTAssertEqual(options.extraParameters as? [String: String], expected, model)
            XCTAssertNil(options.prediction, model)
        }
        let deepSeek = self.resolve(.general, baseURL: "https://api.deepseek.com/v1", model: "deepseek-reasoner", transcript: nil)
        XCTAssertEqual(deepSeek.extraParameters["enable_thinking"] as? Bool, true)
    }

    func testASavedConfigurationWinsForEveryPurpose() {
        let saved = self.effort("high")
        for purpose in [TextRequestPurpose.general, .dictationCleanup] {
            XCTAssertEqual(self.resolve(purpose, baseURL: Self.google, model: "gemini-2.5-flash", saved: .on(saved)).reasoning, saved)
            XCTAssertNil(self.resolve(purpose, baseURL: Self.google, model: "gemini-2.5-flash", saved: .off).reasoning)
            XCTAssertNil(self.resolve(purpose, baseURL: Self.openAI, model: "gpt-5.1", saved: .off).reasoning)
        }
        XCTAssertEqual(Options.reasoning(name: "enable_thinking", value: "false"), Options.Reasoning(name: "enable_thinking", value: .bool(false)))
    }

    // MARK: - Lower reasoning effort for cleanup (RSN-2)

    func testCleanupUsesTheLowestDocumentedEffortOnTheVendorsOwnServer() {
        let rows: [(String, String, String?)] = [
            (Self.google, "gemini-2.5-flash", "none"),
            (Self.google, "gemini-2.5-flash-lite", "none"),
            (Self.google, "models/gemini-2.5-flash", "none"),
            (Self.google, "google/gemini-2.5-flash", "none"),
            (Self.google, "gemini-2.5-pro", "low"),
            (Self.google, "gemini-3.1-pro-preview", "low"),
            (Self.google, "gemini-3-flash-preview", "minimal"),
            (Self.groq, "qwen/qwen3-32b", "none"),
            (Self.openAI, "o3", "low"),
            (Self.openAI, "o4-mini", "low"),
        ]
        for (baseURL, model, expected) in rows {
            XCTAssertEqual(self.resolve(baseURL: baseURL, model: model).reasoning, expected.map(self.effort), model)
        }
    }

    func testCleanupKeepsTheDefaultWhereNoRowApplies() {
        XCTAssertEqual(self.resolve(baseURL: Self.openAI, model: "gpt-5.1").reasoning, self.effort("low"))
        XCTAssertNil(self.resolve(baseURL: Self.openAI, model: "gpt-6-sol").reasoning)
        XCTAssertEqual(self.resolve(baseURL: Self.groq, model: "openai/gpt-oss-120b").reasoning, self.effort("low"))
        XCTAssertNil(self.resolve(baseURL: Self.openAI, model: "gpt-4.1", predicted: false).reasoning)
        XCTAssertNil(self.resolve(baseURL: Self.openRouter, model: "google/gemini-2.5-flash").reasoning, "OpenRouter may not forward it")
        XCTAssertEqual(self.resolve(baseURL: Self.openRouter, model: "openai/o3").reasoning, self.effort("low"), "the built-in default")
    }

    func testTheLowerEffortIsOffForGeneralUseTheComparisonKeyAndASuppressedPair() {
        XCTAssertNil(self.resolve(.general, baseURL: Self.google, model: "gemini-2.5-flash").reasoning)
        XCTAssertNil(self.resolve(baseURL: Self.google, model: "gemini-2.5-flash", lowReasoning: false).reasoning)
        XCTAssertNil(self.resolve(baseURL: Self.google, model: "gemini-2.5-flash", suppressed: true).reasoning)
        XCTAssertEqual(self.resolve(.general, baseURL: Self.openAI, model: "o3").reasoning, self.effort("medium"))
    }

    func testOSeriesCleanupGoesToTheResponsesAPIAsReasoningEffort() throws {
        let options = self.resolve(baseURL: Self.openAI, model: "o3")
        let config = LLMClient.Config(messages: [["role": "user", "content": "x"]], model: "o3", baseURL: Self.openAI, apiKey: "k", streaming: false)
            .applying(options)
        let request = try LLMClient.shared.buildRequest(config)
        XCTAssertTrue(request.url?.absoluteString.hasSuffix("/responses") == true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(body["prediction"])
    }

    func testGeminiCleanupSendsReasoningEffortNone() throws {
        let options = self.resolve(baseURL: Self.google, model: "gemini-2.5-flash")
        let config = LLMClient.Config(messages: [["role": "user", "content": "x"]], model: "gemini-2.5-flash", baseURL: Self.google, apiKey: "k", streaming: true)
            .applying(options)
        let body = LLMClient.shared.buildChatCompletionsBody(config)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
    }

    // MARK: - Predicted Outputs (PRED-1)

    func testPredictionOnlyForTheFiveOpenAIChatModels() {
        for model in ["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini", "gpt-4o-2024-08-06"] {
            XCTAssertEqual(self.resolve(baseURL: Self.openAI, model: model).prediction, "hello there", model)
        }
        for model in ["gpt-4o-audio-preview", "gpt-4o-transcribe", "ft:gpt-4.1:org::abc", "gpt-5.1", "o3"] {
            XCTAssertNil(self.resolve(baseURL: Self.openAI, model: model).prediction, model)
        }
        XCTAssertNil(self.resolve(baseURL: Self.openRouter, model: "gpt-4.1").prediction)
        XCTAssertNil(self.resolve(.general, baseURL: Self.openAI, model: "gpt-4.1").prediction)
        XCTAssertNil(self.resolve(baseURL: Self.openAI, model: "gpt-4.1", predicted: false).prediction)
        XCTAssertNil(self.resolve(baseURL: Self.openAI, model: "gpt-4.1", suppressed: true).prediction)
        XCTAssertNil(self.resolve(baseURL: Self.openAI, model: "gpt-4.1", transcript: "  ").prediction)
        XCTAssertNil(self.resolve(baseURL: "https://api.openai.com/v1/responses", model: "gpt-4.1").prediction)
    }

    func testPredictionBodyAndUsageRequest() {
        let options = self.resolve(baseURL: Self.openAI, model: "gpt-4.1")
        let base = LLMClient.Config(messages: [["role": "user", "content": "x"]], model: "gpt-4.1", baseURL: Self.openAI, apiKey: "k", streaming: true)
        let streamed = LLMClient.shared.buildChatCompletionsBody(base.applying(options))
        XCTAssertEqual((streamed["prediction"] as? [String: String])?["content"], "hello there")
        XCTAssertEqual((streamed["prediction"] as? [String: String])?["type"], "content")
        XCTAssertEqual((streamed["stream_options"] as? [String: Bool])?["include_usage"], true)

        let plain = LLMClient.shared.buildChatCompletionsBody(base.applying(options).withoutStreaming())
        XCTAssertNotNil(plain["prediction"])
        XCTAssertNil(plain["stream_options"])

        var limited = base.applying(options)
        limited.maxTokens = 50
        XCTAssertNil(LLMClient.shared.buildChatCompletionsBody(limited)["prediction"])
        let withoutPrediction = LLMClient.shared.buildChatCompletionsBody(base)
        XCTAssertNil(withoutPrediction["prediction"])
        XCTAssertNil(withoutPrediction["stream_options"])
    }

    func testWithoutStreamingKeepsTheRequestAndDropsCallbacks() {
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "x"]],
            model: "m",
            baseURL: Self.openAI,
            apiKey: "k",
            streaming: true,
            temperature: 0.2,
            extraParameters: ["reasoning_effort": "low"],
            benchmarkID: "A"
        )
        config.onContentChunk = { _ in }
        config.prediction = "p"
        let copy = config.withoutStreaming()
        XCTAssertFalse(copy.streaming)
        XCTAssertNil(copy.onContentChunk)
        XCTAssertEqual(copy.benchmarkID, "A")
        XCTAssertEqual(copy.temperature, 0.2)
        XCTAssertEqual(copy.extraParameters["reasoning_effort"] as? String, "low")
        XCTAssertEqual(copy.prediction, "p")
    }

    func testMetricsDelegateOnlyForMeasuredRequests() {
        let unmeasured = LLMClient.Config(messages: [], model: "m", baseURL: Self.openAI, apiKey: "k")
        XCTAssertNil(LLMClient.metricsDelegate(for: unmeasured))
    }

    // MARK: - Transport (XPORT)

    private final class Script {
        var results: [Result<String, Error>]
        var sent: [LLMClient.Config] = []
        init(_ results: [Result<String, Error>]) { self.results = results }

        func send(_ config: LLMClient.Config) throws -> LLMClient.Response {
            self.sent.append(config)
            let result = self.results.removeFirst()
            return try LLMClient.Response(thinking: nil, content: result.get(), toolCalls: [])
        }
    }

    private func send(_ script: Script, streaming: Bool, options: Options, plain: Options, pair: String = "google:gemini-2.5-flash") async throws -> String {
        let config = LLMClient.Config(messages: [["role": "user", "content": "x"]], model: "gemini-2.5-flash", baseURL: Self.google, apiKey: "k", streaming: streaming)
        return try await TextRequestTransport.send(config, options: options, plain: plain, pair: pair) { config in
            try script.send(config)
        }.content
    }

    private var plainGemini: Options { self.resolve(baseURL: Self.google, model: "gemini-2.5-flash", suppressed: true) }
    private var optimisedGemini: Options { self.resolve(baseURL: Self.google, model: "gemini-2.5-flash") }

    func testWithoutAnOptimisationTheSequenceIsTodays() async throws {
        let plain = self.plainGemini
        var script = Script([.success("ok")])
        let first = try await self.send(script, streaming: true, options: plain, plain: plain)
        XCTAssertEqual(first, "ok")
        XCTAssertEqual(script.sent.count, 1)

        script = Script([.failure(LLMError.httpError(400, "bad")), .success("ok")])
        let afterStreamed400 = try await self.send(script, streaming: true, options: plain, plain: plain)
        XCTAssertEqual(afterStreamed400, "ok")
        XCTAssertEqual(script.sent.map(\.streaming), [true, false])

        script = Script([.failure(LLMError.httpError(500, "down")), .success("ok")])
        _ = try await self.send(script, streaming: true, options: plain, plain: plain)
        XCTAssertEqual(script.sent.map(\.streaming), [true, false])

        script = Script([.failure(LLMError.networkError(URLError(.notConnectedToInternet)))])
        do {
            _ = try await self.send(script, streaming: true, options: plain, plain: plain)
            XCTFail("a transport failure is not repeated")
        } catch {}
        XCTAssertEqual(script.sent.count, 1)

        script = Script([.failure(LLMError.httpError(400, "bad"))])
        do {
            _ = try await self.send(script, streaming: false, options: plain, plain: plain)
            XCTFail("a non-streamed failure is thrown")
        } catch {}
        XCTAssertEqual(script.sent.count, 1)
        XCTAssertFalse(Options.isSuppressed("google:gemini-2.5-flash"))
    }

    func testARejectedOptimisationIsRepeatedPlainAndSuppressed() async throws {
        let script = Script([.failure(LLMError.httpError(400, "unknown reasoning_effort")), .success("ok")])
        let text = try await self.send(script, streaming: true, options: self.optimisedGemini, plain: self.plainGemini)
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(script.sent.map(\.streaming), [true, true])
        XCTAssertEqual(script.sent[0].extraParameters["reasoning_effort"] as? String, "none")
        XCTAssertNil(script.sent[1].extraParameters["reasoning_effort"])
        XCTAssertTrue(Options.isSuppressed("google:gemini-2.5-flash"))

        let next = Options.resolve(purpose: .dictationCleanup, providerKey: "google", baseURL: Self.google, model: "gemini-2.5-flash", transcript: "x")
        XCTAssertEqual(next.options, next.plain, "a suppressed pair gets plain options at once")
    }

    func testAFailingPlainRepeatSuppressesNothingAndThrowsThePlainError() async {
        let script = Script([
            .failure(LLMError.httpError(400, "optimised")),
            .failure(LLMError.httpError(400, "plain streamed")),
            .failure(LLMError.httpError(400, "plain")),
        ])
        do {
            _ = try await self.send(script, streaming: true, options: self.optimisedGemini, plain: self.plainGemini)
            XCTFail("expected the plain error")
        } catch let LLMError.httpError(_, message) {
            XCTAssertEqual(message, "plain")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(script.sent.map(\.streaming), [true, true, false])
        XCTAssertNil(script.sent[2].extraParameters["reasoning_effort"])
        XCTAssertFalse(Options.isSuppressed("google:gemini-2.5-flash"))
    }

    func testAPlainNonStreamedSuccessAfterARejectionSuppresses() async throws {
        let script = Script([
            .failure(LLMError.httpError(400, "optimised")),
            .failure(LLMError.httpError(400, "plain streamed")),
            .success("ok"),
        ])
        _ = try await self.send(script, streaming: true, options: self.optimisedGemini, plain: self.plainGemini)
        XCTAssertTrue(Options.isSuppressed("google:gemini-2.5-flash"))
    }

    func testAnOptimisedServerErrorFallsBackToAPlainNonStreamedRequest() async throws {
        let script = Script([.failure(LLMError.httpError(500, "down")), .success("ok")])
        _ = try await self.send(script, streaming: true, options: self.optimisedGemini, plain: self.plainGemini)
        XCTAssertEqual(script.sent.map(\.streaming), [true, false])
        XCTAssertNil(script.sent[1].extraParameters["reasoning_effort"])
        XCTAssertFalse(Options.isSuppressed("google:gemini-2.5-flash"), "a 500 is no evidence against the parameter")
    }

    // MARK: - Warm-up policy (WARM-3)

    private func warmOrigin(
        isRecordingDictation: Bool = true,
        isPromptTest: Bool = false,
        cleanupConfigured: Bool = true,
        usesFluidIntelligence: Bool = false,
        combinedCloudDictation: Bool = false,
        baseURL: String = DictationCleanupSpeedTests.openAI,
        isLocalEndpoint: Bool = false,
        warmUpEnabled: Bool = true
    ) -> URL? {
        DictationCleanupWarmPolicy.origin(.init(
            isRecordingDictation: isRecordingDictation,
            isPromptTest: isPromptTest,
            cleanupConfigured: cleanupConfigured,
            usesFluidIntelligence: usesFluidIntelligence,
            combinedCloudDictation: combinedCloudDictation,
            baseURL: baseURL,
            isLocalEndpoint: isLocalEndpoint,
            warmUpEnabled: warmUpEnabled
        ))
    }

    func testWarmUpTargetsTheProviderOriginOnly() {
        XCTAssertEqual(self.warmOrigin()?.absoluteString, "https://api.openai.com/")
        XCTAssertEqual(self.warmOrigin(baseURL: "https://example.com:8443/v1/")?.absoluteString, "https://example.com:8443/")
    }

    func testNoWarmUpWhenNoCleanupRequestToARemoteProviderCanFollow() {
        XCTAssertNil(self.warmOrigin(isRecordingDictation: false))
        XCTAssertNil(self.warmOrigin(isPromptTest: true))
        XCTAssertNil(self.warmOrigin(cleanupConfigured: false))
        XCTAssertNil(self.warmOrigin(usesFluidIntelligence: true))
        XCTAssertNil(self.warmOrigin(combinedCloudDictation: true))
        XCTAssertNil(self.warmOrigin(isLocalEndpoint: true))
        XCTAssertNil(self.warmOrigin(warmUpEnabled: false))
        XCTAssertNil(self.warmOrigin(baseURL: ""))
    }

    // MARK: - Reasoning row and editor (RSN-5, RSN-6)

    private func viewModel(provider: String, model: String) -> AIEnhancementSettingsViewModel {
        self.preserveAppPreferences()
        self.pinLocalSpeechExecutionSource()
        let settings = SettingsStore.shared
        UserDefaults.standard.removeObject(forKey: DictationSpeedComparison.lowReasoningKey)
        settings.selectedProviderID = provider
        var models = settings.selectedModelByProvider
        models[provider] = model
        settings.selectedModelByProvider = models
        settings.setReasoningConfig(nil, forModel: model, provider: provider)
        let viewModel = AIEnhancementSettingsViewModel(settings: settings, menuBarManager: MenuBarManager(), promptTest: .shared)
        viewModel.selectedModelByProvider[provider] = model
        viewModel.selectedModel = model
        return viewModel
    }

    func testReasoningRowSaysWhatIsSent() {
        let viewModel = self.viewModel(provider: "openai", model: "gpt-5.1")
        XCTAssertEqual(viewModel.reasoningStateSummary(for: "openai").detail, "Automatic: reasoning_effort = low")
        SettingsStore.shared.setReasoningConfig(.init(parameterName: "reasoning_effort", parameterValue: "high", isEnabled: true), forModel: "gpt-5.1", provider: "openai")
        XCTAssertEqual(viewModel.reasoningStateSummary(for: "openai").detail, "Custom: reasoning_effort = high")
        SettingsStore.shared.setReasoningConfig(.init(parameterName: "", parameterValue: "", isEnabled: false), forModel: "gpt-5.1", provider: "openai")
        XCTAssertEqual(viewModel.reasoningStateSummary(for: "openai").detail, "Custom: model's own default")

        let plain = self.viewModel(provider: "openai", model: "gpt-4.1")
        XCTAssertEqual(plain.reasoningStateSummary(for: "openai").detail, "Automatic: model's own default")
        XCTAssertNil(plain.reasoningStateSummary(for: "openai").note)
    }

    func testTheCleanupNoteAppearsOnlyWhereItIsTrue() {
        let viewModel = self.viewModel(provider: "google", model: "gemini-2.5-flash")
        let note = viewModel.reasoningStateSummary(for: "google").note
        XCTAssertEqual(note, "Cleanup Styles on this model send reasoning_effort = none instead, so dictation finishes sooner. "
            + "Command Mode, Edit and meeting summaries use the setting above.")

        UserDefaults.standard.set(false, forKey: DictationSpeedComparison.lowReasoningKey)
        XCTAssertNil(viewModel.reasoningStateSummary(for: "google").note, "comparison key off")
        UserDefaults.standard.removeObject(forKey: DictationSpeedComparison.lowReasoningKey)

        Options.suppress(Options.pair(providerKey: "google", model: "gemini-2.5-flash"))
        XCTAssertNil(viewModel.reasoningStateSummary(for: "google").note, "suppressed after a rejection")
        Options.resetSuppressionForTesting()

        SettingsStore.shared.selectedProviderID = "openai"
        XCTAssertNil(viewModel.reasoningStateSummary(for: "google").note, "not the default text provider")
        SettingsStore.shared.selectedProviderID = "google"

        SettingsStore.shared.setReasoningConfig(.init(parameterName: "", parameterValue: "", isEnabled: false), forModel: "gemini-2.5-flash", provider: "google")
        viewModel.reasoningConfigVersion += 1
        XCTAssertNil(viewModel.reasoningStateSummary(for: "google").note, "a saved configuration wins")
    }

    func testEditorPrefillMatchesWhatIsSent() {
        let o3 = self.viewModel(provider: "openai", model: "o3")
        o3.openReasoningConfig()
        XCTAssertTrue(o3.editingReasoningEnabled)
        XCTAssertEqual(o3.editingReasoningParamValue, "medium", "the value general use sends")

        let gemini = self.viewModel(provider: "google", model: "gemini-2.5-flash")
        gemini.openReasoningConfig()
        XCTAssertFalse(gemini.editingReasoningEnabled)
        XCTAssertEqual(gemini.editingReasoningParamName, "reasoning_effort")

        SettingsStore.shared.setReasoningConfig(.init(parameterName: "", parameterValue: "", isEnabled: false), forModel: "o3", provider: "openai")
        o3.openReasoningConfig()
        XCTAssertFalse(o3.editingReasoningEnabled, "saved as off reopens off")
        XCTAssertEqual(o3.editingReasoningParamName, "reasoning_effort")
        XCTAssertEqual(o3.editingReasoningParamValue, "medium")
    }

    func testSaveRulesAndResetToAutomatic() {
        let viewModel = self.viewModel(provider: "google", model: "gemini-2.5-flash")
        viewModel.openReasoningConfig()
        XCTAssertTrue(viewModel.canSaveReasoningConfig, "saving an untouched Automatic draft is how a user opts out")
        viewModel.saveReasoningConfig()
        XCTAssertEqual(SettingsStore.shared.savedReasoning(forModel: "gemini-2.5-flash", provider: "google"), .off)

        viewModel.openReasoningConfig()
        XCTAssertFalse(viewModel.canSaveReasoningConfig, "an untouched saved configuration")
        viewModel.editingReasoningEnabled = true
        XCTAssertTrue(viewModel.canSaveReasoningConfig)
        viewModel.editingReasoningEnabled = false
        XCTAssertFalse(viewModel.canSaveReasoningConfig, "toggled on and off again")
        viewModel.editingReasoningEnabled = true
        viewModel.editingReasoningParamName = " "
        XCTAssertFalse(viewModel.canSaveReasoningConfig)
        XCTAssertEqual(viewModel.reasoningSaveBlocker, "Enter a parameter name and value.")

        XCTAssertTrue(viewModel.hasSavedReasoningConfig)
        viewModel.resetReasoningToAutomatic()
        XCTAssertFalse(viewModel.hasSavedReasoningConfig)
        XCTAssertFalse(viewModel.showingReasoningConfig)
        XCTAssertEqual(viewModel.reasoningStateSummary(for: "google").detail, "Automatic: model's own default")
    }

    func testChangingTheModelClosesTheEditor() {
        let viewModel = self.viewModel(provider: "google", model: "gemini-2.5-flash")
        viewModel.openReasoningConfig()
        XCTAssertTrue(viewModel.showingReasoningConfig)
        viewModel.selectedModel = "gemini-2.5-pro"
        XCTAssertFalse(viewModel.showingReasoningConfig)
    }
}
