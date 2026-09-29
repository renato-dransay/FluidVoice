@testable import FluidVoice_Debug
import XCTest

final class FileCloudSpeakerAlignmentTests: XCTestCase {
    func testAllWordsSurviveSpeakerAlignmentIncludingUnassignedAndOverlappingSpeech() {
        let words = [
            ASRWordTiming(text: "Hello", start: 0.1, end: 0.4),
            ASRWordTiming(text: "there", start: 0.5, end: 0.8),
            ASRWordTiming(text: "overlap", start: 1.1, end: 1.4),
            ASRWordTiming(text: "unknown", start: 3, end: 3.5),
        ]
        let turns = [
            SpeakerDiarizationService.SpeakerTurn(speakerLabel: "Speaker 1", startSeconds: 0, endSeconds: 2),
            SpeakerDiarizationService.SpeakerTurn(speakerLabel: "Speaker 2", startSeconds: 1, endSeconds: 2),
        ]
        let segments = CloudFileSpeakerAlignment.segments(words: words, turns: turns)
        XCTAssertEqual(segments.map(\.speaker), ["Speaker 1", "Multiple speakers", "Unknown speaker"])
        XCTAssertEqual(segments.map(\.text), ["Hello there", "overlap", "unknown"])
        XCTAssertEqual(segments.first?.startSeconds, 0.1)
        XCTAssertEqual(segments.last?.endSeconds, 3.5)
    }

    func testOneCloudTranscriptCanBeAlignedWithoutRepeatingRecognitionPerSpeakerTurn() {
        let words = [ASRWordTiming(text: "Olá", start: 0.2, end: 0.6)]
        let segments = CloudFileSpeakerAlignment.segments(words: words, turns: [])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, "Olá")
        XCTAssertEqual(segments.first?.speaker, "Unknown speaker")
    }
}
