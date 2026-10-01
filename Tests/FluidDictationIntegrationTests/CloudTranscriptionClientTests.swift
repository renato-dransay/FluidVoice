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
        XCTAssertNotNil(body.range(of: Data("fLaC".utf8)))
        XCTAssertNotNil(body.range(of: Data("filename=\"recording.flac\"\r\nContent-Type: audio/flac".utf8)))
    }

    func testRequestTimingLineCarriesSizesAndDurationsOnly() {
        let audio = CloudEncodedAudio(data: Data(count: 12_345), format: "flac", mimeType: "audio/flac", fileName: "recording.flac", encodeDuration: 0.0123)
        let line = OpenRouterTranscriptionClient.requestTimingLine(endpoint: "chat", audio: audio, audioSamples: 32_000, requestDuration: 1.5, status: "200")
        XCTAssertEqual(line, "CLOUD_REQUEST endpoint=chat format=flac audioMs=2000 uploadBytes=12345 encodeMs=12 requestMs=1500 status=200")
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
        for model in CloudTranscriptionModel.builtIn {
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
            XCTAssertEqual(audio["format"], "flac")
            let flac = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(audio["data"])))
            XCTAssertEqual(String(data: flac.prefix(4), encoding: .utf8), "fLaC")
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

    func testCatalogListsEveryTranscriptionModelWithoutCredentials() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"data":[{"id":"deepgram/nova-3","name":"Deepgram: Nova-3"},{"id":"unnamed/model"}]}"#.utf8))
        }
        let entries = try await self.client().transcriptionCatalog()
        XCTAssertEqual(entries, [
            CloudTranscriptionCatalogEntry(id: "deepgram/nova-3", name: "Deepgram: Nova-3"),
            CloudTranscriptionCatalogEntry(id: "unnamed/model", name: "unnamed/model"),
        ])
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/models")
        XCTAssertEqual(request.url?.query, "output_modalities=transcription")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The public catalog must not receive the key")
    }

    func testEmptyOrUnreadableCatalogFailsInsteadOfListingNothing() async throws {
        for (body, expected) in [(#"{"data":[]}"#, CloudTranscriptionError.catalogUnavailable), ("not json", .malformedResponse)] {
            CloudURLProtocol.install { _ in (200, [:], Data(body.utf8)) }
            do {
                _ = try await self.client().transcriptionCatalog()
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, expected)
            }
        }
    }

    func testWordTimingCheckRequestsTimingsFromAModelOutsideTheCatalog() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"text":"The quick fox.","words":[{"word":"The","start":0,"end":0.2},{"word":"quick","start":0.2,"end":0.5},{"word":"fox.","start":0.5,"end":0.9}]}"#.utf8))
        }
        let supported = try await self.client().checkWordTimings(
            modelID: "unlisted/new-model", speechSamples: [Float](repeating: 0.1, count: 16_000), apiKey: "test-key"
        )
        XCTAssertTrue(supported)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(body.range(of: Data("name=\"model\"\r\n\r\nunlisted/new-model".utf8)))
        XCTAssertNotNil(body.range(of: Data("name=\"response_format\"\r\n\r\nverbose_json".utf8)))
        XCTAssertNotNil(body.range(of: Data("name=\"timestamp_granularities[]\"\r\n\r\nword".utf8)))
    }

    func testWordTimingCheckReportsUnsupportedWhenTimingsAreMissingOrInvalid() async throws {
        let responses = [
            #"{"text":"The quick fox."}"#,
            #"{"text":"The quick fox.","words":[]}"#,
            #"{"text":"The quick fox.","words":[{"word":"The","start":0.4,"end":0.2}]}"#,
        ]
        for body in responses {
            CloudURLProtocol.install { _ in (200, [:], Data(body.utf8)) }
            let supported = try await self.checkWordTimings()
            XCTAssertFalse(supported, "\(body) must not verify word timings")
        }
    }

    func testWordTimingCheckTreatsARefusalAsUnsupportedOnlyWhenPlainTextStillWorks() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            let asksForTimings = request.httpBody?.range(of: Data("verbose_json".utf8)) != nil
            return asksForTimings
                ? (400, [:], Data(#"{"error":{"message":"verbose_json is not supported"}}"#.utf8))
                : (200, [:], Data(#"{"text":"The quick fox."}"#.utf8))
        }
        let supported = try await self.checkWordTimings()
        XCTAssertFalse(supported)
        XCTAssertEqual(recorder.requests.count, 2)
        let plain = try XCTUnwrap(recorder.requests.last?.httpBody)
        XCTAssertNotNil(plain.range(of: Data("name=\"response_format\"\r\n\r\njson".utf8)))
        XCTAssertNil(plain.range(of: Data("timestamp_granularities".utf8)))

        // A provider that rejects the clip outright says nothing about timings.
        CloudURLProtocol.install { _ in (400, [:], Data(#"{"error":{"message":"unsupported audio"}}"#.utf8)) }
        do {
            _ = try await self.checkWordTimings()
            XCTFail("A request refused in both forms must not become a verdict")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .server(400))
        }
    }

    func testWordTimingCheckNeverTurnsAFailedRequestIntoAVerdict() async throws {
        let responses: [(Int, String, CloudTranscriptionError)] = [
            (200, #"{"text":" ","words":[]}"#, .wordTimingCheckInconclusive),
            (200, #"{"text":""}"#, .wordTimingCheckInconclusive),
            (401, "{}", .authentication),
            (402, "{}", .creditsExhausted),
            (404, "{}", .modelUnavailable),
            (500, "{}", .server(500)),
            (200, "not json", .malformedResponse),
        ]
        for (status, body, expected) in responses {
            CloudURLProtocol.install { _ in (status, [:], Data(body.utf8)) }
            do {
                _ = try await self.checkWordTimings()
                XCTFail("HTTP \(status) \(body) must throw \(expected)")
            } catch {
                XCTAssertEqual(error as? CloudTranscriptionError, expected)
            }
        }
    }

    func testTranscriptionStillRejectsAModelOutsideTheCatalogBeforeUploading() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"text":"unexpected"}"#.utf8))
        }
        do {
            _ = try await self.client().transcribe(samples: [0.1], configuration: .init(modelID: "unlisted/new-model"), apiKey: "test-key", wordTimings: false)
            XCTFail("An unlisted model must fail before uploading audio")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .unsupportedModel)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testCatalogStoreOffersBuiltInModelsBeforeAnyFetch() throws {
        let (store, _, cleanup) = try self.catalogStore()
        defer { cleanup() }
        XCTAssertEqual(store.models, CloudTranscriptionModel.builtIn)
        XCTAssertTrue(store.isRefreshDue())
        XCTAssertEqual(store.models.filter(\.supportsWordTimings).map(\.id), ["openai/whisper-large-v3-turbo", "openai/whisper-large-v3"])
    }

    func testCatalogStoreAddsListedModelsAsUnverifiedAndKeepsBuiltInCapabilities() throws {
        let (store, defaults, cleanup) = try self.catalogStore()
        defer { cleanup() }
        store.replaceListedModels([
            .init(id: "mistralai/voxtral-mini-transcribe", name: "Mistral: Voxtral Mini Transcribe"),
            .init(id: "openai/whisper-large-v3", name: "OpenAI: Whisper Large V3"),
            .init(id: " deepgram/nova-3 ", name: "  "),
            .init(id: "mistralai/voxtral-mini-transcribe", name: "Duplicate"),
            .init(id: "", name: "Blank"),
        ])
        XCTAssertEqual(store.models.map(\.id), CloudTranscriptionModel.builtIn.map(\.id) + ["deepgram/nova-3", "mistralai/voxtral-mini-transcribe"])
        let whisper = try XCTUnwrap(store.models.first { $0.id == "openai/whisper-large-v3" })
        XCTAssertEqual(whisper, CloudTranscriptionModel.builtIn[1], "A listing must not rename or downgrade a built-in model")
        let nova = try XCTUnwrap(store.models.first { $0.id == "deepgram/nova-3" })
        XCTAssertEqual(nova.name, "deepgram/nova-3")
        XCTAssertEqual(nova.wordTimingSupport, .unverified)
        XCTAssertFalse(nova.supportsWordTimings)
        XCTAssertTrue(nova.languageHintProviderTags.isEmpty, "Unverified providers receive no prompt")
        XCTAssertEqual(CloudTranscriptionCatalogStore(defaults: defaults).models, store.models, "The listing must survive a relaunch")
    }

    func testCatalogStoreRemembersWordTimingChecksAndNeverDowngradesDocumentedSupport() throws {
        let (store, defaults, cleanup) = try self.catalogStore()
        defer { cleanup() }
        store.replaceListedModels([.init(id: "deepgram/nova-3", name: "Deepgram: Nova-3"), .init(id: "google/chirp-3", name: "Google: Chirp 3")])
        store.recordWordTimingCheck(modelID: "deepgram/nova-3", supported: true)
        store.recordWordTimingCheck(modelID: "google/chirp-3", supported: false)
        store.recordWordTimingCheck(modelID: "openai/whisper-large-v3", supported: false)
        store.recordWordTimingCheck(modelID: "openai/gpt-4o-transcribe", supported: true)
        let restored = CloudTranscriptionCatalogStore(defaults: defaults)
        let support = Dictionary(uniqueKeysWithValues: restored.models.map { ($0.id, $0.wordTimingSupport) })
        XCTAssertEqual(support["deepgram/nova-3"], .supported)
        XCTAssertEqual(support["google/chirp-3"], .unsupported)
        XCTAssertEqual(support["openai/whisper-large-v3"], .supported)
        XCTAssertEqual(support["openai/gpt-4o-transcribe"], .supported)
        XCTAssertEqual(support["openai/gpt-4o-mini-transcribe"], .unsupported)
        store.recordWordTimingCheck(modelID: "deepgram/nova-3", supported: false)
        XCTAssertEqual(store.models.first { $0.id == "deepgram/nova-3" }?.wordTimingSupport, .unsupported, "A later check replaces the earlier result")
    }

    func testCatalogStoreRefreshesOnlyWhenStaleAndKeepsTheListOnFailure() async throws {
        let (store, _, cleanup) = try self.catalogStore()
        defer { cleanup() }
        let recorder = CloudRequestRecorder()
        let audioCatalog = #"""
        {"data":[{"id":"google/gemini-3.5-flash","name":"Google: Gemini 3.5 Flash",
         "architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]},
         "supported_parameters":["response_format","structured_outputs"]}]}
        """#
        CloudURLProtocol.install { request in
            recorder.append(request)
            guard request.url?.query == "output_modalities=transcription" else { return (200, [:], Data(audioCatalog.utf8)) }
            return (200, [:], Data(#"{"data":[{"id":"deepgram/nova-3","name":"Deepgram: Nova-3"}]}"#.utf8))
        }
        let start = Date(timeIntervalSince1970: 1_000_000)
        let fetched = try await store.refresh(using: self.client(), now: start)
        XCTAssertTrue(fetched)
        XCTAssertEqual(store.models.last?.id, "deepgram/nova-3")
        let skipped = try await store.refresh(using: self.client(), now: start.addingTimeInterval(CloudTranscriptionCatalogStore.refreshInterval - 1))
        XCTAssertFalse(skipped)
        XCTAssertEqual(recorder.requests.count, 2, "One transcription fetch and one audio fetch")

        CloudURLProtocol.install { request in
            recorder.append(request)
            guard request.url?.query == "output_modalities=transcription" else { return (200, [:], Data(audioCatalog.utf8)) }
            return (200, [:], Data(#"{"data":[{"id":"google/chirp-3","name":"Google: Chirp 3"}]}"#.utf8))
        }
        let forced = try await store.refresh(using: self.client(), force: true, now: start.addingTimeInterval(60))
        XCTAssertTrue(forced)
        XCTAssertEqual(store.models.map(\.id), CloudTranscriptionModel.builtIn.map(\.id) + ["google/chirp-3"], "A withdrawn model stops being offered")

        CloudURLProtocol.install { _ in (503, [:], Data()) }
        let stale = start.addingTimeInterval(CloudTranscriptionCatalogStore.refreshInterval * 2)
        do {
            _ = try await store.refresh(using: self.client(), now: stale)
            XCTFail("A failed fetch must be reported")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .server(503))
        }
        XCTAssertEqual(store.models.last?.id, "google/chirp-3", "A failed fetch keeps the cached list")
        XCTAssertTrue(store.isRefreshDue(now: stale), "A failed fetch stays due")
        store.replaceListedModels([], now: stale)
        XCTAssertEqual(store.models.last?.id, "google/chirp-3", "An empty listing never clears the catalog")
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

    func testAudioDictationCatalogKeepsOnlyStructuredAudioChatModelsWithoutCredentials() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            let catalog = #"""
            {"data":[
                {"id":"google/gemini-3.5-flash","name":"Google: Gemini 3.5 Flash",
                 "architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]},
                {"id":"google/gemini-3.5-flash:batch","name":"Google: Gemini 3.5 Flash (batch)",
                 "architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]},
                {"id":"openrouter/auto","name":"Auto Router",
                 "architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]},
                {"id":"~google/gemini-flash-latest","name":"Google: Gemini Flash Latest",
                 "architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]},
                {"id":"openai/gpt-audio",
                 "architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]},
                {"id":"openai/gpt-5","name":"Text only",
                 "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]},
                {"id":"some/audio-no-schema","name":"No schema",
                 "architecture":{"input_modalities":["audio"],"output_modalities":["text"]},
                 "supported_parameters":["response_format"]}
            ]}
            """#
            return (200, [:], Data(catalog.utf8))
        }
        let entries = try await self.client().audioDictationCatalog()
        XCTAssertEqual(entries, [
            CloudTranscriptionCatalogEntry(id: "google/gemini-3.5-flash", name: "Google: Gemini 3.5 Flash"),
            CloudTranscriptionCatalogEntry(id: "openai/gpt-audio", name: "openai/gpt-audio"),
        ])
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/models")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testCatalogStoreListsAudioDictationModelsAndRefreshesBothCatalogs() async throws {
        let (store, defaults, cleanup) = try self.catalogStore()
        defer { cleanup() }
        XCTAssertEqual(store.audioDictationModels, CloudAudioDictationModel.builtIn)
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            if request.url?.query == "output_modalities=transcription" {
                return (200, [:], Data(#"{"data":[{"id":"deepgram/nova-3","name":"Deepgram: Nova-3"}]}"#.utf8))
            }
            let catalog = #"""
            {"data":[
                {"id":"google/gemini-2.5-flash","name":"Google: Gemini 2.5 Flash",
                 "architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]},
                {"id":"openai/gpt-audio","name":"OpenAI: GPT Audio",
                 "architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]},
                {"id":"google/gemini-3.5-flash","name":"Google: Gemini 3.5 Flash",
                 "architecture":{"input_modalities":["audio","text"],"output_modalities":["text"]},
                 "supported_parameters":["response_format","structured_outputs"]}
            ]}
            """#
            return (200, [:], Data(catalog.utf8))
        }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fetched = try await store.refresh(using: self.client(), now: now)
        XCTAssertTrue(fetched)
        XCTAssertEqual(recorder.requests.map { $0.url?.query }, ["output_modalities=transcription", nil])
        XCTAssertEqual(store.models.last?.id, "deepgram/nova-3")
        XCTAssertEqual(
            store.audioDictationModels.map(\.id),
            CloudAudioDictationModel.builtIn.map(\.id) + ["openai/gpt-audio"],
            "Listed Gemini generations older than the built-in ones are hidden; other families follow"
        )
        XCTAssertEqual(CloudTranscriptionCatalogStore(defaults: defaults).audioDictationModels, store.audioDictationModels)

        CloudURLProtocol.install { request in
            request.url?.query == "output_modalities=transcription"
                ? (200, [:], Data(#"{"data":[{"id":"deepgram/nova-3","name":"Deepgram: Nova-3"}]}"#.utf8))
                : (503, [:], Data())
        }
        do {
            _ = try await store.refresh(using: self.client(), force: true, now: now.addingTimeInterval(60))
            XCTFail("A failed audio catalog fetch must be reported")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .server(503))
        }
        XCTAssertEqual(store.audioDictationModels.last?.id, "openai/gpt-audio", "A failed fetch keeps the cached audio list")
    }

    func testAudioDictationListKeepsOnlyTheNewestModelOfEachFamily() {
        // The audio-capable chat models OpenRouter listed on 30 September 2026.
        let listed = [
            "google/gemini-2.5-flash", "google/gemini-2.5-flash-lite", "google/gemini-2.5-pro", "google/gemini-2.5-pro-preview",
            "google/gemini-3-flash-preview", "google/gemini-3.1-flash-lite", "google/gemini-3.1-flash-lite-preview",
            "google/gemini-3.1-pro-preview", "google/gemini-3.1-pro-preview-customtools", "google/gemini-3.5-flash",
            "google/gemini-3.5-flash-lite", "google/gemini-3.6-flash", "google/gemini-3.7-flash", "google/gemini-3.8-flash",
            "mistralai/voxtral-small-24b-2507", "openai/gpt-audio", "openai/gpt-audio-mini", "qwen/qwen3.8-omni-flash",
            "xiaomi/mimo-v2.5", "xiaomi/mimo-v2.6-flash", "xiaomi/mimo-v2.6-pro", "xiaomi/mimo-v2.6-pro-ultraspeed",
        ].map { CloudAudioDictationModel(id: $0, name: $0) }
        let expected = [
            "google/gemini-3.8-flash", "google/gemini-3.5-flash-lite", "google/gemini-3.1-pro-preview",
            "mistralai/voxtral-small-24b-2507", "openai/gpt-audio", "openai/gpt-audio-mini", "qwen/qwen3.8-omni-flash",
            "xiaomi/mimo-v2.5", "xiaomi/mimo-v2.6-flash", "xiaomi/mimo-v2.6-pro", "xiaomi/mimo-v2.6-pro-ultraspeed",
        ]
        // Older generations, previews with a stable successor and tool variants are hidden; the newest Gemini Flash leads.
        XCTAssertEqual(CloudAudioDictationModel.current(listed).map(\.id), expected)
    }

    func testAudioDictationListPrefersAStableReleaseOverAPreviewOfTheSameVersion() {
        let listed = ["google/gemini-4-flash-preview", "google/gemini-4-flash", "google/gemini-3.8-flash"]
            .map { CloudAudioDictationModel(id: $0, name: $0) }
        XCTAssertEqual(CloudAudioDictationModel.current(listed).map(\.id), ["google/gemini-4-flash"])
    }

    func testFailedAudioCatalogFetchKeepsTheRefreshDue() async throws {
        let (store, _, cleanup) = try self.catalogStore()
        defer { cleanup() }
        CloudURLProtocol.install { request in
            request.url?.query == "output_modalities=transcription"
                ? (200, [:], Data(#"{"data":[{"id":"deepgram/nova-3","name":"Deepgram: Nova-3"}]}"#.utf8))
                : (503, [:], Data())
        }
        let now = Date(timeIntervalSince1970: 1_000_000)
        do {
            _ = try await store.refresh(using: self.client(), now: now)
            XCTFail("A failed audio catalog fetch must be reported")
        } catch {
            XCTAssertEqual(error as? CloudTranscriptionError, .server(503))
        }
        XCTAssertEqual(store.models.last?.id, "deepgram/nova-3", "The transcription list that did arrive is kept")
        XCTAssertTrue(store.isRefreshDue(now: now.addingTimeInterval(60)), "A partial refresh must not postpone the next attempt")
    }

    func testFailureSummaryNamesKindAndModelWithoutPayload() {
        XCTAssertEqual(
            CloudTranscriptionFailureSummary.line(for: CloudTranscriptionError.server(400), modelID: "deepgram/nova-3"),
            "Cloud transcription failed: server(400); model=deepgram/nova-3. No transcript or request payload logged."
        )
        XCTAssertEqual(
            CloudTranscriptionFailureSummary.line(for: CloudTranscriptionError.modelUnavailable, modelID: nil),
            "Cloud transcription failed: modelUnavailable; model=unknown. No transcript or request payload logged."
        )
        XCTAssertEqual(
            CloudTranscriptionFailureSummary.line(for: CancellationError(), modelID: "openai/whisper-large-v3"),
            "Cloud transcription failed: cancelled; model=openai/whisper-large-v3. No transcript or request payload logged."
        )
        XCTAssertEqual(
            CloudTranscriptionFailureSummary.line(for: URLError(.notConnectedToInternet), modelID: "openai/whisper-large-v3"),
            "Cloud transcription failed: URLError.-1009; model=openai/whisper-large-v3. No transcript or request payload logged."
        )
        struct Leaky: LocalizedError { var errorDescription: String? { "PRIVATE transcript and test-key" } }
        let line = CloudTranscriptionFailureSummary.line(for: Leaky(), modelID: "openai/whisper-large-v3")
        XCTAssertTrue(line.contains("Leaky"), "Unknown errors are named by type")
        XCTAssertFalse(line.contains("PRIVATE"), "An error description can carry transcript text and must never be logged")
        XCTAssertFalse(line.contains("test-key"))
    }

    func testPrewarmSendsOneKeyRequestThenStaysQuietWhileTheConnectionIsFresh() async {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (200, [:], Data(#"{"data":{}}"#.utf8))
        }
        let client = self.client()
        await client.prewarmIfIdle(apiKey: "test-key", now: 100)
        await client.prewarmIfIdle(apiKey: "test-key", now: 130)
        XCTAssertEqual(recorder.requests.count, 1, "A request within 60 seconds keeps the connection warm")
        XCTAssertEqual(recorder.requests.first?.url?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(recorder.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        await client.prewarmIfIdle(apiKey: "test-key", now: 161)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testPrewarmIgnoresFailuresAndEmptyKeys() async {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            return (500, [:], Data())
        }
        let client = self.client()
        await client.prewarmIfIdle(apiKey: "  ", now: 100)
        XCTAssertEqual(recorder.requests.count, 0)
        await client.prewarmIfIdle(apiKey: "test-key", now: 100)
        await client.prewarmIfIdle(apiKey: "test-key", now: 101)
        XCTAssertEqual(recorder.requests.count, 2, "A failed prewarm does not count as a warm connection")
    }

    private func client() -> OpenRouterTranscriptionClient {
        OpenRouterTranscriptionClient(session: CloudURLProtocol.session(), recordsUsage: false)
    }

    private func checkWordTimings() async throws -> Bool {
        try await self.client().checkWordTimings(modelID: "unlisted/new-model", speechSamples: [Float](repeating: 0.1, count: 16_000), apiKey: "test-key")
    }

    /// A store on scratch defaults, so tests never touch the catalog the app itself reads.
    private func catalogStore() throws -> (store: CloudTranscriptionCatalogStore, defaults: UserDefaults, cleanup: () -> Void) {
        let suite = "CloudTranscriptionCatalogStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (CloudTranscriptionCatalogStore(defaults: defaults), defaults, { defaults.removePersistentDomain(forName: suite) })
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
