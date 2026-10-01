#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

final class LiveTranscriptAssemblerTests: XCTestCase {
    func testFinalSegmentsAppendAndPendingTextReplaces() {
        var assembler = LiveTranscriptAssembler()
        assembler.apply(.segment(.init(id: "1", text: "Olá", isFinal: true, audioEndMilliseconds: 700)))
        assembler.apply(.pending(" mun"))
        XCTAssertEqual(assembler.displayText, "Olá mun")
        assembler.apply(.segment(.init(id: "2", text: " mundo", isFinal: true, audioEndMilliseconds: 1_200)))
        assembler.apply(.pending(""))
        XCTAssertEqual(assembler.displayText, "Olá mundo")
        XCTAssertEqual(assembler.finalText, "Olá mundo")
    }

    func testSegmentsWithoutLeadingSpaceAreJoinedWithOneSpaceButPunctuationIsNot() {
        var assembler = LiveTranscriptAssembler()
        assembler.apply(.segment(.init(id: "a", text: "hello world", isFinal: true, audioEndMilliseconds: nil)))
        assembler.apply(.segment(.init(id: "b", text: "how are you", isFinal: true, audioEndMilliseconds: nil)))
        assembler.apply(.segment(.init(id: "c", text: "?", isFinal: true, audioEndMilliseconds: nil)))
        XCTAssertEqual(assembler.finalText, "hello world how are you?")
    }

    func testSegmentsInScriptsWithoutSpacesAreJoinedWithoutASpace() {
        XCTAssertEqual(LiveTranscriptAssembler.join(["こんにちは", "世界"]), "こんにちは世界")
        XCTAssertEqual(LiveTranscriptAssembler.join(["今天", "天气很好", "。"]), "今天天气很好。")
        XCTAssertEqual(LiveTranscriptAssembler.join(["สวัสดี", "ครับ"]), "สวัสดีครับ")
        XCTAssertEqual(LiveTranscriptAssembler.join(["東京", "in Japan"]), "東京in Japan", "A boundary next to an unspaced script is never a word gap")
        XCTAssertEqual(LiveTranscriptAssembler.join(["안녕하세요", "세계"]), "안녕하세요 세계", "Korean separates words with spaces")
    }

    func testKeyedSegmentsAreReplacedInPlace() {
        var assembler = LiveTranscriptAssembler()
        assembler.apply(.segment(.init(id: "turn-0", text: "My name", isFinal: false, audioEndMilliseconds: nil)))
        assembler.apply(.segment(.init(id: "turn-1", text: "Second", isFinal: false, audioEndMilliseconds: nil)))
        assembler.apply(.segment(.init(id: "turn-0", text: "My name is Sonny.", isFinal: true, audioEndMilliseconds: 1_600)))
        XCTAssertEqual(assembler.displayText, "My name is Sonny. Second")
    }

    func testReplaceAllOnlyReplacesTheCurrentConnection() {
        var assembler = LiveTranscriptAssembler()
        assembler.apply(.segment(.init(id: "1", text: "First part.", isFinal: true, audioEndMilliseconds: 2_000)))
        XCTAssertEqual(assembler.beginGeneration(), 2_000)
        assembler.apply(.segment(.init(id: "1", text: "draft", isFinal: false, audioEndMilliseconds: nil)))
        assembler.apply(.replaceAll("Second part."))
        XCTAssertEqual(assembler.finalText, "First part. Second part.")
    }

    func testNewConnectionReplaysFromTheLastTimedFinalAndDropsProvisionalText() {
        var assembler = LiveTranscriptAssembler()
        assembler.apply(.segment(.init(id: "1", text: "kept", isFinal: true, audioEndMilliseconds: 1_500)))
        assembler.apply(.segment(.init(id: "2", text: "draft", isFinal: false, audioEndMilliseconds: nil)))
        assembler.apply(.pending("more"))
        XCTAssertEqual(assembler.beginGeneration(), 1_500)
        XCTAssertEqual(assembler.displayText, "kept")
        // Times from the new connection are relative to its own first sample.
        assembler.apply(.segment(.init(id: "1", text: "again", isFinal: true, audioEndMilliseconds: 400)))
        XCTAssertEqual(assembler.beginGeneration(), 1_900)
        XCTAssertEqual(assembler.finalText, "kept again")
    }

    func testUntimedFinalsCannotBeResumedSoTheirConnectionIsReplayedWhole() {
        var assembler = LiveTranscriptAssembler()
        assembler.apply(.segment(.init(id: "1", text: "untimed", isFinal: true, audioEndMilliseconds: nil)))
        XCTAssertEqual(assembler.beginGeneration(), 0)
        XCTAssertEqual(assembler.finalText, "")
    }

    func testErrorMessagesNameTheProviderAndCarryNoServerText() {
        XCTAssertEqual(
            LiveTranscriptionError.authentication.message(providerName: "Soniox"),
            "Soniox rejected the API key. Update it in Voice Engine settings and retry."
        )
        XCTAssertEqual(
            LiveTranscriptionError.sessionClosed("limit_exceeded").message(providerName: "Deepgram"),
            "Deepgram ended the session early (limit_exceeded). Your recording is kept; retry, transcribe locally, or discard it."
        )
    }

    func testEveryProviderHasOneCatalogEntryWithADefaultModel() {
        for id in LiveTranscriptionProviderID.allCases {
            XCTAssertEqual(LiveTranscriptionCatalog.all.filter { $0.id == id }.count, 1, "\(id)")
            XCTAssertFalse(LiveTranscriptionCatalog.info(for: id).defaultModelID.isEmpty)
        }
    }
}
