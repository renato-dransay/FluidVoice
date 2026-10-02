#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

/// The pieces every Cloud transcription vendor shares (CLD-1, CLD-2, CLD-4, CLD-6) and the job helpers
/// the job vendors use.
final class CloudVendorSupportTests: XCTestCase {
    // MARK: - Configuration, catalog and preferences

    func testAConfigurationWithoutAProviderDecodesAsOpenRouter() throws {
        let old = Data(#"{"modelID":"openai/whisper-large-v3","languageCode":"de"}"#.utf8)
        let restored = try JSONDecoder().decode(CloudTranscriptionConfiguration.self, from: old)
        XCTAssertEqual(restored.providerID, "openrouter")
        XCTAssertEqual(restored.languageCode, "de")
        let deepgram = CloudTranscriptionConfiguration(providerID: "deepgram", modelID: "nova-3", languageCode: "en")
        XCTAssertEqual(try JSONDecoder().decode(CloudTranscriptionConfiguration.self, from: JSONEncoder().encode(deepgram)), deepgram)
    }

    func testValidationUsesTheProvidersOwnCatalog() {
        XCTAssertNoThrow(try CloudTranscriptionConfiguration(providerID: "deepgram", modelID: "nova-3").validate(wordTimings: true))
        XCTAssertNoThrow(try CloudTranscriptionConfiguration(providerID: "mistral", modelID: "voxtral-mini-latest").validate(wordTimings: false))
        XCTAssertThrowsError(try CloudTranscriptionConfiguration(providerID: "mistral", modelID: "voxtral-mini-latest").validate(wordTimings: true)) {
            XCTAssertEqual($0 as? CloudTranscriptionError, .unsupportedWordTimings)
        }
        XCTAssertThrowsError(try CloudTranscriptionConfiguration(providerID: "deepgram", modelID: CloudTranscriptionModel.defaultDictationID).validate(wordTimings: false))
        XCTAssertThrowsError(try CloudTranscriptionConfiguration(providerID: "unknown", modelID: "nova-3").validate(wordTimings: false))
        let styled = CloudTranscriptionConfiguration(
            providerID: "deepgram", modelID: "nova-3", audioDictation: .init(modelID: CloudAudioDictationModel.defaultID, promptText: nil)
        )
        XCTAssertThrowsError(try styled.validate(wordTimings: false), "The style model is OpenRouter's alone")
    }

    func testCatalogsAndClientsCoverEveryShippedProvider() {
        XCTAssertEqual(CloudTranscriptionCatalog.models(for: "openrouter").map(\.id), CloudTranscriptionModel.catalog.map(\.id))
        XCTAssertEqual(CloudTranscriptionCatalog.models(for: "deepgram").map(\.id), ["nova-3", "nova-2", "nova-3-medical"])
        XCTAssertEqual(CloudTranscriptionCatalog.models(for: "elevenlabs").map(\.id), ["scribe_v2", "scribe_v2_medical"])
        XCTAssertEqual(CloudTranscriptionCatalog.models(for: "mistral").map(\.id), ["voxtral-mini-latest", "voxtral-mini-2602"])
        XCTAssertEqual(CloudTranscriptionCatalog.models(for: "speechmatics").map(\.id), ["enhanced", "standard", "melia-1"])
        XCTAssertEqual(CloudTranscriptionCatalog.models(for: "soniox").map(\.id), ["stt-async-v5"])
        XCTAssertEqual(CloudTranscriptionCatalog.models(for: "assemblyai").map(\.id), ["universal-3-5-pro", "universal-2"])
        XCTAssertEqual(CloudTranscriptionCatalog.models(for: "gladia").map(\.id), ["solaria-1", "solaria-3"])
        XCTAssertEqual(
            CloudTranscriptionClients.providerIDs,
            ["openrouter", "deepgram", "elevenlabs", "mistral", "speechmatics", "soniox", "assemblyai", "gladia"]
        )
        XCTAssertTrue(CloudTranscriptionCatalog.models(for: "unknown").isEmpty)
        for id in CloudTranscriptionClients.providerIDs {
            XCTAssertEqual(CloudTranscriptionClients.client(for: id)?.providerID, id)
            XCTAssertFalse(CloudTranscriptionCatalog.models(for: id).isEmpty, id)
        }
        XCTAssertEqual(CloudTranscriptionClients.client(for: "openrouter")?.maximumRequestSeconds, 120)
        for id in CloudTranscriptionClients.providerIDs where id != "openrouter" {
            XCTAssertEqual(CloudTranscriptionClients.client(for: id)?.maximumRequestSeconds, 780, id)
        }
        XCTAssertNil(CloudTranscriptionClients.client(for: "unknown"))
        XCTAssertEqual(CloudTranscriptionClients.historyProviderName(for: "openrouter"), "openrouter")
        XCTAssertEqual(CloudTranscriptionClients.historyProviderName(for: "deepgram"), "cloud-deepgram")
    }

    func testAnUnknownProviderNeverSendsAnything() async {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data())
        }
        let client = CloudTranscriptionClients.make("retired-vendor")
        do {
            try await client.checkKey(apiKey: "k")
            XCTFail("An unknown provider has no key check")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .unsupportedModel)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    @MainActor
    func testEachProviderKeepsItsOwnSpeechModel() throws {
        let suite = "CloudVendorSupportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.modelID(for: "deepgram"), "nova-3", "A provider starts on its default model")
        XCTAssertEqual(preferences.modelID, CloudTranscriptionModel.defaultDictationID)
        preferences.modelID = "openai/whisper-1"
        preferences.setModelID("not-a-model", for: "deepgram")
        XCTAssertNil(defaults.string(forKey: "CloudTranscriptionModel.deepgram"), "A model outside the catalog is never stored")
        preferences.setModelID("nova-3", for: "deepgram")
        XCTAssertEqual(defaults.string(forKey: "CloudTranscriptionModel"), "openai/whisper-1", "OpenRouter keeps its stored key")
        XCTAssertEqual(defaults.string(forKey: "CloudTranscriptionModel.deepgram"), "nova-3")
        XCTAssertEqual(preferences.modelID(for: "unknown"), "")

        preferences.providerID = "deepgram"
        preferences.primaryLanguageCode = "de"
        XCTAssertEqual(preferences.configuration.providerID, "deepgram")
        XCTAssertEqual(preferences.configuration.modelID, "nova-3")
        XCTAssertEqual(preferences.dictationConfiguration.providerID, "deepgram")
        XCTAssertEqual(preferences.dictationConfiguration.primaryLanguageCode, "de")
        preferences.providerID = "openrouter"
        XCTAssertEqual(preferences.configuration.modelID, "openai/whisper-1")
    }

    func testDefaultsStayAndEveryListedModelPassesValidation() {
        let defaults = [
            "openrouter": CloudTranscriptionModel.defaultDictationID, "deepgram": "nova-3", "elevenlabs": "scribe_v2",
            "mistral": "voxtral-mini-latest", "speechmatics": "enhanced", "soniox": "stt-async-v5",
            "assemblyai": "universal-3-5-pro", "gladia": "solaria-1",
        ]
        for id in CloudTranscriptionClients.providerIDs {
            XCTAssertEqual(CloudTranscriptionCatalog.defaultModelID(for: id), defaults[id], id)
            for model in CloudTranscriptionCatalog.models(for: id) where id != "openrouter" {
                XCTAssertNoThrow(try CloudTranscriptionConfiguration(providerID: id, modelID: model.id).validate(wordTimings: model.supportsWordTimings), model.id)
                XCTAssertEqual(CloudTranscriptionCatalog.models(for: id).filter { $0.id == model.id }.count, 1, "Listed once: \(model.id)")
            }
        }
    }

    /// A model the user chose stays chosen after an update drops it from the catalog: it is still sent, its
    /// word timings count as unchecked, and a model typed anywhere else must still be listed.
    @MainActor
    func testAStoredModelTheCatalogNoLongerListsKeepsWorking() throws {
        let suite = "CloudVendorSupportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("nova-0", forKey: "CloudTranscriptionModel.deepgram")
        defaults.set("vendor/withdrawn-speech-model", forKey: "CloudTranscriptionModel")
        var preferences = CloudTranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.modelID(for: "deepgram"), "nova-0")
        XCTAssertEqual(preferences.modelID, "vendor/withdrawn-speech-model", "OpenRouter's stored choice is kept too")
        XCTAssertTrue(preferences.isUnlistedModel(for: "deepgram"))

        preferences.providerID = "deepgram"
        let configuration = preferences.dictationConfiguration
        XCTAssertEqual(configuration.modelID, "nova-0")
        XCTAssertTrue(configuration.allowsUnlistedModel)
        XCTAssertNoThrow(try configuration.validate(wordTimings: false))
        XCTAssertThrowsError(try configuration.validate(wordTimings: true)) {
            XCTAssertEqual($0 as? CloudTranscriptionError, .unsupportedWordTimings, "Unchecked timings never feed speaker labels")
        }
        XCTAssertFalse(configuration.with(modelID: "nova-9").allowsUnlistedModel, "Another model must be listed")
        XCTAssertThrowsError(try configuration.with(modelID: "nova-9").validate(wordTimings: false))
        XCTAssertEqual(try JSONDecoder().decode(CloudTranscriptionConfiguration.self, from: JSONEncoder().encode(configuration)), configuration)

        let listed = CloudTranscriptionConfiguration(providerID: "deepgram", modelID: "nova-3")
        let encoded = try XCTUnwrap(String(bytes: JSONEncoder().encode(listed), encoding: .utf8))
        XCTAssertFalse(encoded.contains("allowsUnlistedModel"), "A listed model encodes as before, keeping its chunk cache")

        preferences.setModelID("nova-2", for: "deepgram")
        XCTAssertEqual(preferences.modelID(for: "deepgram"), "nova-2")
        XCTAssertFalse(preferences.isUnlistedModel(for: "deepgram"))
        XCTAssertFalse(preferences.configuration.allowsUnlistedModel)
    }

    // MARK: - Errors and HTTP

    func testErrorsNameTheProviderAndKeepOpenRouterWording() {
        XCTAssertEqual(CloudTranscriptionError.rateLimited.errorDescription, CloudTranscriptionError.rateLimited.message(providerName: "OpenRouter"))
        XCTAssertEqual(
            CloudTranscriptionError.missingAPIKey.message(providerName: "Deepgram"),
            "Add a Deepgram API key in AI Providers."
        )
        XCTAssertEqual(
            CloudTranscriptionError.authentication.message(providerName: "Mistral"),
            "Mistral rejected the API key. Update it in AI Providers and retry."
        )
        XCTAssertTrue(CloudTranscriptionError.modelUnavailable.message(providerName: "OpenRouter").contains("allowed providers"))
        XCTAssertFalse(CloudTranscriptionError.modelUnavailable.message(providerName: "Deepgram").contains("openrouter.ai"))
        XCTAssertTrue(CloudTranscriptionError.server(500).message(providerName: "ElevenLabs").hasPrefix("ElevenLabs transcription failed (HTTP 500)"))
        XCTAssertEqual(CloudTranscriptionError.message(for: CancellationError(), providerName: "Deepgram"), CancellationError().localizedDescription)
    }

    func testStatusMapping() {
        XCTAssertNil(CloudVendorHTTP.error(forStatus: 200))
        XCTAssertEqual(CloudVendorHTTP.error(forStatus: 401), .authentication)
        XCTAssertEqual(CloudVendorHTTP.error(forStatus: 403), .authentication)
        XCTAssertEqual(CloudVendorHTTP.error(forStatus: 402), .creditsExhausted)
        XCTAssertEqual(CloudVendorHTTP.error(forStatus: 429), .rateLimited)
        XCTAssertEqual(CloudVendorHTTP.error(forStatus: 408), .timeout)
        XCTAssertEqual(CloudVendorHTTP.error(forStatus: 504), .timeout)
        XCTAssertEqual(CloudVendorHTTP.error(forStatus: 413), .oversizedAudio)
        XCTAssertEqual(CloudVendorHTTP.error(forStatus: 500), .server(500))
        XCTAssertEqual(CloudVendorHTTP.error(forStatus: 400), .server(400))
        XCTAssertEqual(CloudVendorHTTP.singleRequestTimeout(audioSamples: 16_000 * 30), 90)
    }

    func testRequestLineCarriesNoSecretsOrText() {
        let line = CloudVendorHTTP.requestLine(
            providerID: "deepgram", endpoint: "listen", modelID: "nova-3", audioBytes: 1_234, audioSamples: 32_000, requestDuration: 0.25, status: "200"
        )
        XCTAssertEqual(line, "CLOUD_REQUEST provider=deepgram endpoint=listen model=nova-3 audioMs=2000 uploadBytes=1234 requestMs=250 status=200")
    }

    func testMultipartFormEncodesFieldsAndFiles() throws {
        var form = CloudMultipartForm(boundary: "B")
        form.append(field: "model", value: "m")
        form.append(file: "file", fileName: "a.wav", mimeType: "audio/wav", data: Data("RIFF".utf8))
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=B")
        let text = try XCTUnwrap(String(data: form.data, encoding: .utf8))
        XCTAssertEqual(
            text,
            "--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF\r\n--B--\r\n"
        )
    }

    // MARK: - Session (KEY-8, retry)

    @MainActor
    func testADeepgramSessionNeverContactsOpenRouter() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"results":{"channels":[{"alternatives":[{"transcript":"hi"}]}]}}"#.utf8))
        }
        let clients = Self.stubbedClients()
        let keys = ["openrouter": "or-key", "deepgram": "dg-key"]
        let session = CloudTranscriptionSession(
            configuration: .init(providerID: "deepgram", modelID: "nova-3"), speechAPIKey: { keys[$0] ?? "" }, clients: clients
        )
        XCTAssertEqual(session.apiKey, "dg-key")
        await session.prewarm()
        let result = try await session.provider(persistChunks: false).transcribe([Float](repeating: 0.1, count: 16_000))
        XCTAssertEqual(result.text, "hi")
        XCTAssertFalse(recorder.requests.isEmpty)
        XCTAssertFalse(recorder.requests.contains { $0.url?.host == "openrouter.ai" }, "No request may go to openrouter.ai")
        XCTAssertFalse(recorder.requests.contains { ($0.value(forHTTPHeaderField: "Authorization") ?? "").contains("or-key") })
    }

    func testAnOpenRouterSessionPrewarmsWithItsOwnKey() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data("{}".utf8))
        }
        let session = CloudTranscriptionSession(
            configuration: .init(), speechAPIKey: { $0 == "openrouter" ? "or-key" : "other" }, clients: Self.stubbedClients()
        )
        await session.prewarm()
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer or-key")
    }

    func testAChangedConfigurationKeepsTheFrozenProviderAndKey() {
        let session = CloudTranscriptionSession(
            configuration: .init(providerID: "deepgram", modelID: "nova-3"), speechAPIKey: { _ in "dg-key" }, clients: Self.stubbedClients()
        )
        let updated = session.with(configuration: session.configuration.with(languageCode: "de"))
        XCTAssertEqual(updated.providerID, "deepgram")
        XCTAssertEqual(updated.apiKey, "dg-key")
        XCTAssertEqual(updated.client.providerID, "deepgram")
        XCTAssertEqual(updated.configuration.languageCode, "de")
        XCTAssertEqual(updated.configuration.modelID, "nova-3")
    }

    // MARK: - Job polling

    func testPollingScheduleAndDeadline() async throws {
        let clock = FakeClock()
        let poller = CloudJobPoller(now: { clock.now }, sleep: { clock.advance($0) })
        var polls = 0
        do {
            let _: String = try await poller.poll(audioSeconds: 5) {
                polls += 1
                return .pending
            }
            XCTFail("A job that never finishes must time out")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .timeout)
        }
        XCTAssertEqual(CloudJobPoller.deadline(audioSeconds: 5), 130)
        XCTAssertEqual(Array(clock.sleeps.prefix(11)), Array(repeating: 1, count: 10) + [2])
        XCTAssertEqual(clock.now, 130, accuracy: 0.001, "The last wait stops at the deadline")
        XCTAssertEqual(polls, clock.sleeps.count + 1)
    }

    func testPollingReturnsTheResultAndReportsAFailedJob() async throws {
        let clock = FakeClock()
        let poller = CloudJobPoller(now: { clock.now }, sleep: { clock.advance($0) })
        var polls = 0
        let result: String = try await poller.poll(audioSeconds: 1) {
            polls += 1
            return polls < 3 ? .pending : .completed("done")
        }
        XCTAssertEqual(result, "done")
        XCTAssertEqual(clock.sleeps, [1, 1])
        do {
            let _: String = try await poller.poll(audioSeconds: 1) { .failed() }
            XCTFail("A failed job must throw")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .jobFailed)
        }
    }

    // MARK: - Remote cleanup

    func testCleanupRunsAfterSuccessAndFailureAndIgnoresFailedDeletes() async throws {
        let log = DeletionLog()
        let value = try await CloudRemoteCleanup.run(providerID: "test") { cleanup in
            cleanup.register("upload") { log.append("upload") }
            cleanup.register("transcript") {
                log.append("transcript")
                throw CloudTranscriptionError.server(500)
            }
            return "result"
        }
        XCTAssertEqual(value, "result")
        XCTAssertEqual(log.entries, ["transcript", "upload"], "Newest first, and a failed delete does not stop the others")
        do {
            let _: String = try await CloudRemoteCleanup.run(providerID: "test") { cleanup in
                cleanup.register("job") { log.append("job") }
                throw CloudTranscriptionError.jobFailed
            }
            XCTFail("The failure must propagate")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .jobFailed)
        }
        XCTAssertEqual(log.entries.last, "job")
    }

    func testCleanupStillRunsWhenTheTranscriptionIsCancelled() async throws {
        let log = DeletionLog()
        let registered = self.expectation(description: "Job created")
        let task = Task {
            try await CloudRemoteCleanup.run(providerID: "test") { cleanup -> String in
                cleanup.register("job") { log.append(Task.isCancelled ? "cancelled-delete" : "job") }
                registered.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return "unreachable"
            }
        }
        await self.fulfillment(of: [registered], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled transcription returns nothing")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try await log.waitForEntries(1)
        XCTAssertEqual(log.entries, ["job"], "The delete goes out outside the cancelled task")
    }

    func testACancelledTranscriptionDoesNotWaitForItsDeletes() async throws {
        let registered = self.expectation(description: "Job created")
        let deleteStarted = self.expectation(description: "Delete started")
        let task = Task {
            try await CloudRemoteCleanup.run(providerID: "test") { cleanup -> String in
                cleanup.register("job") {
                    deleteStarted.fulfill()
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                }
                registered.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return "unreachable"
            }
        }
        await self.fulfillment(of: [registered], timeout: 2)
        let cancelled = ProcessInfo.processInfo.systemUptime
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelled, 1, "The cancelled caller returns before the slow delete ends")
        await self.fulfillment(of: [deleteStarted], timeout: 2)
    }

    func testARefusedDeleteIsRetriedInTheBackgroundAndTheOtherDeletesDoNotWaitForIt() async throws {
        let clock = FakeClock()
        let retry = CloudCleanupRetry(now: { clock.now }, sleep: { clock.advance($0) })
        let log = DeletionLog()
        let refusals = DeletionLog()
        let value = try await CloudRemoteCleanup.run(providerID: "test", retry: retry) { cleanup in
            cleanup.register("file") { log.append("file") }
            cleanup.register("transcription", refusedWhileProcessing: CloudRemoteCleanup.refused(withStatus: 409)) {
                if refusals.entries.count < 3 {
                    refusals.append("409")
                    throw CloudTranscriptionError.server(409)
                }
                log.append("transcription")
            }
            return "result"
        }
        XCTAssertEqual(value, "result")
        try await log.waitForEntries(2)
        XCTAssertEqual(log.entries, ["file", "transcription"], "The file is deleted at once, not behind the refused transcription")
        XCTAssertEqual(clock.sleeps, [5, 5, 5])
    }

    func testRetriesSlowDownAfterAMinuteAndGiveUpAfterTenMinutes() async throws {
        let clock = FakeClock()
        let retry = CloudCleanupRetry(now: { clock.now }, sleep: { clock.advance($0) })
        let attempts = DeletionLog()
        let cleanup = CloudRemoteCleanup(providerID: "test", retry: retry)
        cleanup.register("job", refusedWhileProcessing: CloudRemoteCleanup.refused(withStatus: 403)) {
            attempts.append("attempt")
            throw CloudTranscriptionError.server(403)
        }
        await cleanup.deleteAll()
        // 12 waits of 5 s fill the first minute; 36 waits of 15 s fill the other nine.
        try await attempts.waitForEntries(1 + 12 + 36)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(attempts.entries.count, 49, "No attempt after ten minutes")
        XCTAssertEqual(clock.sleeps, Array(repeating: 5, count: 12) + Array(repeating: 15, count: 36))
        XCTAssertEqual(clock.now, CloudCleanupRetry.giveUpAfter, accuracy: 0.001)
    }

    // MARK: - Helpers

    private static func stubbedClients() -> (String) -> any CloudTranscriptionClient {
        { providerID in
            switch providerID {
            case "openrouter": OpenRouterTranscriptionClient(session: CloudURLProtocol.session(), recordsUsage: false)
            case "deepgram": DeepgramTranscriptionClient(session: CloudURLProtocol.session())
            case "elevenlabs": ElevenLabsTranscriptionClient(session: CloudURLProtocol.session())
            case "mistral": MistralTranscriptionClient(session: CloudURLProtocol.session())
            case "speechmatics": SpeechmaticsTranscriptionClient(session: CloudURLProtocol.session())
            case "soniox": SonioxTranscriptionClient(session: CloudURLProtocol.session())
            case "assemblyai": AssemblyAITranscriptionClient(session: CloudURLProtocol.session())
            case "gladia": GladiaTranscriptionClient(session: CloudURLProtocol.session())
            default: UnavailableCloudTranscriptionClient(providerID: providerID)
            }
        }
    }
}

/// Finds a multipart text field in a request body.
enum CloudMultipartAssert {
    static func contains(_ body: Data, field: String, value: String) -> Bool {
        body.range(of: Data("name=\"\(field)\"\r\n\r\n\(value)\r\n".utf8)) != nil
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var recorded: [TimeInterval] = []
    var now: TimeInterval { self.lock.withLock { self.current } }
    var sleeps: [TimeInterval] { self.lock.withLock { self.recorded } }
    func advance(_ seconds: TimeInterval) {
        self.lock.withLock {
            self.recorded.append(seconds)
            self.current += seconds
        }
    }
}

private final class DeletionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var entries: [String] { self.lock.withLock { self.storage } }
    func append(_ entry: String) { self.lock.withLock { self.storage.append(entry) } }

    /// Waits for deletions that run in the background.
    func waitForEntries(_ count: Int, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while self.entries.count < count {
            guard Date() < deadline else {
                XCTFail("\(self.entries.count) of \(count) deletions")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
