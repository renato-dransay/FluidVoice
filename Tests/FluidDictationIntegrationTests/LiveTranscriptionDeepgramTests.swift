#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

final class LiveTranscriptionDeepgramTests: XCTestCase {
    private let automatic = LiveTranscriptionConfiguration(provider: .deepgram, modelID: "nova-3", languageCode: nil, languageHints: ["en", "pt"])

    func testConnectionQueryAndTokenHeader() throws {
        let request = try DeepgramLiveAdapter().connectionRequest(apiKey: "k", configuration: self.automatic)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(request.url?.host, "api.deepgram.com")
        XCTAssertEqual(request.url?.path, "/v1/listen")
        XCTAssertEqual(items["model"], "nova-3")
        XCTAssertEqual(items["encoding"], "linear16")
        XCTAssertEqual(items["sample_rate"], "16000")
        XCTAssertEqual(items["channels"], "1")
        XCTAssertEqual(items["interim_results"], "true")
        XCTAssertEqual(items["smart_format"], "true")
        XCTAssertEqual(items["language"], "multi")
        XCTAssertNil(items["mip_opt_out"], "Opting out of the Model Improvement Program would forfeit Deepgram's discount")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token k")
    }

    func testChosenLanguageReplacesMulti() throws {
        let request = try DeepgramLiveAdapter().connectionRequest(apiKey: "k", configuration: self.automatic.with(languageCode: "pt"))
        XCTAssertTrue(request.url?.query?.contains("language=pt") == true)
    }

    func testEachModelGetsTheLanguageItSupports() throws {
        func language(_ modelID: String, chosen: String? = nil, hints: [String] = []) throws -> String {
            try DeepgramLiveAdapter.language(for: LiveTranscriptionConfiguration(provider: .deepgram, modelID: modelID, languageCode: chosen, languageHints: hints))
        }
        XCTAssertEqual(try language("nova-3", hints: ["de"]), "multi")
        XCTAssertEqual(try language("nova-2", hints: ["de"]), "de", "Nova-2's multi covers only Spanish and English")
        XCTAssertEqual(try language("nova-2"), "multi")
        XCTAssertEqual(try language("nova-2", chosen: "fr", hints: ["de"]), "fr")
        XCTAssertEqual(try language("nova-3-medical", hints: ["de"]), "en", "English only; Primary and Secondary are only hints")
        XCTAssertEqual(try language("nova-3-medical", chosen: "en"), "en")
        XCTAssertThrowsError(try language("nova-3-medical", chosen: "de"), "A chosen language is never replaced") {
            XCTAssertEqual($0 as? LiveTranscriptionError, .unsupportedLanguage("German"))
        }
        let medical = LiveTranscriptionConfiguration(provider: .deepgram, modelID: "nova-3-medical", languageCode: "de", languageHints: [])
        XCTAssertThrowsError(try DeepgramLiveAdapter().connectionRequest(apiKey: "k", configuration: medical))
        XCTAssertEqual(try language("a-retired-model"), "multi", "An unlisted stored model keeps Nova-3's request")
        let info = LiveTranscriptionCatalog.info(for: .deepgram)
        XCTAssertEqual(info.models.map(\.id), ["nova-3", "nova-2", "nova-3-medical"])
        XCTAssertEqual(DeepgramLiveAdapter.olderModelLanguageCodes.count, 33)
        XCTAssertTrue(info.supports(languageCode: "ko", modelID: "nova-2"), "Nova-2 lists Korean, which Nova-3's multi set lacks")
        XCTAssertFalse(info.supports(languageCode: "ko", modelID: "nova-3"))
        XCTAssertFalse(info.supports(languageCode: "de", modelID: "nova-3-medical"))
    }

    func testInterimReplacesPendingAndFinalAppendsWithItsEndTime() {
        var adapter = DeepgramLiveAdapter()
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"Results","start":0.0,"duration":1.04,"is_final":false,"channel":{"alternatives":[{"transcript":"olá mun"}]}}"#)),
            [.pending("olá mun")]
        )
        XCTAssertEqual(
            adapter.parse(.text(#"{"type":"Results","start":0.0,"duration":1.04,"is_final":true,"channel":{"alternatives":[{"transcript":"Olá mundo"}]}}"#)),
            [.segment(.init(id: "f1", text: "Olá mundo", isFinal: true, audioEndMilliseconds: 1_040)), .pending("")]
        )
    }

    func testEmptyFinalsAddNothingAndMetadataMeansFinished() {
        var adapter = DeepgramLiveAdapter()
        XCTAssertEqual(adapter.parse(.text(#"{"type":"Results","start":1.0,"duration":0.5,"is_final":true,"channel":{"alternatives":[{"transcript":""}]}}"#)), [.pending("")])
        XCTAssertEqual(adapter.parse(.text(#"{"type":"Metadata","request_id":"r"}"#)), [.finished])
    }

    func testFinishClosesTheStreamAndNeverSendsAnEmptyFrame() {
        XCTAssertEqual(DeepgramLiveAdapter().finishMessages(), [.text(#"{"type":"CloseStream"}"#)])
    }

    func testKeyCheck() throws {
        let request = try DeepgramLiveAdapter().keyCheckRequest(apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepgram.com/v1/projects")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token k")
    }
}
