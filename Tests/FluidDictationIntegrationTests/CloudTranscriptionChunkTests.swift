#if canImport(CloudTranscriptionHarness)
@testable import CloudTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

final class CloudTranscriptionChunkTests: XCTestCase {
    func testChunkBoundsAndOverlapOwnership() throws {
        let audio = [Float](repeating: 0.2, count: 16_000 * 250)
        let chunks = CloudAudioChunker.chunks(samples: audio, wordTimings: true)
        XCTAssertEqual(chunks.first?.ownedStart, 0)
        XCTAssertEqual(chunks.last?.ownedEnd, audio.count)
        XCTAssertGreaterThan(chunks.count, 2)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(chunk.end - chunk.start, 120 * 16_000)
            if index > 0 {
                XCTAssertEqual(chunk.ownedStart, chunks[index - 1].ownedEnd)
                XCTAssertEqual(chunks[index - 1].end - chunk.start, 16_000)
            }
        }
    }

    func testPlainChunksNeverOverlapAndPreferSilence() {
        var audio = [Float](repeating: 0.2, count: 16_000 * 250)
        audio.replaceSubrange(115 * 16_000 ..< 116 * 16_000, with: repeatElement(Float(0), count: 16_000))
        let chunks = CloudAudioChunker.chunks(samples: audio, wordTimings: false)
        XCTAssertTrue((115 * 16_000 ... 116 * 16_000).contains(chunks[0].end))
        for index in 1 ..< chunks.count { XCTAssertEqual(chunks[index].start, chunks[index - 1].end) }
    }

    func testWAVClipsAndRejectsNonFiniteSamples() throws {
        let data = try CloudWAVEncoder.encode(samples: [-2, -1, 0, 1, 2])
        XCTAssertEqual(data.count, 54)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertThrowsError(try CloudWAVEncoder.encode(samples: [.nan]))
    }

    func testNativeDecoderReadsWAVAtExpectedSampleRate() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let samples = (0 ..< 16_000).map { Float(sin(Double($0) * 0.1) * 0.5) }
        try CloudWAVEncoder.encode(samples: samples).write(to: file)
        let decoded = try await CloudAudioFileDecoder.readSamples(at: file)
        XCTAssertEqual(decoded.count, samples.count)
        XCTAssertEqual(decoded[100], samples[100], accuracy: 0.0001)
    }

    func testDurableResumeSeparatesConfigurationAndNeverRepeatsCompletedChunks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            if recorder.requests.count == 2 { throw URLError(.timedOut) }
            return (200, [:], Data(#"{"text":"cached","usage":{"cost":0.001}}"#.utf8))
        }
        let samples = [Float](repeating: 0.1, count: 16_000 * 130)
        let configuration = CloudTranscriptionConfiguration(modelID: "openai/gpt-4o-mini-transcribe")
        let engine = CloudTranscriptionEngine(client: .init(session: CloudURLProtocol.session(), recordsUsage: false), cacheDirectory: directory)
        do {
            _ = try await engine.transcribe(samples: samples, configuration: configuration, apiKey: "test-key", wordTimings: false)
            XCTFail("Expected second chunk timeout")
        } catch {}
        let resumedEngine = CloudTranscriptionEngine(client: .init(session: CloudURLProtocol.session(), recordsUsage: false), cacheDirectory: directory)
        let result = try await resumedEngine.transcribe(samples: samples, configuration: configuration, apiKey: "test-key", wordTimings: false)
        XCTAssertEqual(result.text, "cached cached")
        XCTAssertEqual(recorder.requests.count, 3)
        _ = try await resumedEngine.transcribe(samples: samples, configuration: .init(modelID: configuration.modelID, languageCode: "de"), apiKey: "test-key", wordTimings: false)
        XCTAssertEqual(recorder.requests.count, 5)
        _ = try await resumedEngine.transcribe(samples: samples, configuration: .init(modelID: "openai/gpt-4o-transcribe"), apiKey: "test-key", wordTimings: false)
        XCTAssertEqual(recorder.requests.count, 7)
        var differentAudio = samples
        differentAudio[0] = 0.3
        _ = try await resumedEngine.transcribe(samples: differentAudio, configuration: configuration, apiKey: "test-key", wordTimings: false)
        XCTAssertEqual(recorder.requests.count, 9)
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(cacheFiles.isEmpty)
        for file in cacheFiles {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let json = try XCTUnwrap(String(data: Data(contentsOf: file), encoding: .utf8))
            XCTAssertFalse(json.contains("test-key"))
        }
    }

    func testTimedChunkBoundaryDeduplicatesByOwnership() async throws {
        let recorder = CloudRequestRecorder()
        CloudURLProtocol.install { request in
            recorder.append(request)
            let response = recorder.requests.count == 1
                ? #"{"text":"first boundary","words":[{"word":"first","start":0,"end":1},{"word":"boundary","start":119.3,"end":119.7}]}"#
                : #"{"text":"boundary last","words":[{"word":"boundary","start":0.3,"end":0.7},{"word":"last","start":2,"end":3}]}"#
            return (200, [:], Data(response.utf8))
        }
        let engine = CloudTranscriptionEngine(client: .init(session: CloudURLProtocol.session(), recordsUsage: false), cacheDirectory: nil)
        let result = try await engine.transcribe(samples: [Float](repeating: 0.2, count: 16_000 * 125), configuration: .init(), apiKey: "test-key", wordTimings: true)
        XCTAssertEqual(result.words?.map(\.word), ["first", "boundary", "last"])
        XCTAssertEqual(result.words?.last?.start, 121)
    }

    @MainActor
    func testUsagePersistsUnknownCostsAndCountsSeparately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CloudTranscriptionUsageStore(directory: directory)
        store.record(.init(modelID: "test/model", costUSD: 0.02, audioSeconds: 60, processingDuration: 1, requestID: "one"))
        store.record(.init(modelID: "test/model", costUSD: nil, audioSeconds: 60, processingDuration: 2, requestID: "two"))
        let restored = CloudTranscriptionUsageStore(directory: directory)
        XCTAssertEqual(restored.knownCostUSD, 0.02)
        XCTAssertEqual(restored.requestCount, 2)
        XCTAssertEqual(restored.unknownCostCount, 1)
        XCTAssertEqual(restored.lastRecord?.requestID, "two")
        XCTAssertNil(restored.persistenceError)
    }

    func testSingleTimedRequestPreservesMultilingualRawFormatting() async throws {
        CloudURLProtocol.install { _ in
            (200, [:], Data(#"{"text":"你好，世界。\n新段落。","words":[{"word":"你好，世界。","start":0,"end":0.5},{"word":"新段落。","start":0.5,"end":1}]}"#.utf8))
        }
        let engine = CloudTranscriptionEngine(client: .init(session: CloudURLProtocol.session(), recordsUsage: false), cacheDirectory: nil)
        let result = try await engine.transcribe(samples: [Float](repeating: 0.1, count: 16_000), configuration: .init(languageCode: "zh"), apiKey: "test-key", wordTimings: true)
        XCTAssertEqual(result.text, "你好，世界。\n新段落。")
    }
}
