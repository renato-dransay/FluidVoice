#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

final class LiveTranscriptionAdapterTests: XCTestCase {
    func testPCM16ClipsAndIsLittleEndian() {
        let data = LivePCM16.encode([0, 1, -1, 2, -2, 0.5])
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map(Int16.init(littleEndian:))
        XCTAssertEqual(values, [0, 32_767, -32_768, 32_767, -32_768, 16_383])
    }

    func testPCM16MapsNonFiniteSamplesToSilence() {
        let data = LivePCM16.encode([.nan, .infinity])
        XCTAssertEqual(data, Data(count: 4))
    }

    func testHTTPStatusesMapToActionableErrors() {
        XCTAssertEqual(LiveHTTPStatus.failure(for: 401), .authentication)
        XCTAssertEqual(LiveHTTPStatus.failure(for: 403), .authentication)
        XCTAssertEqual(LiveHTTPStatus.failure(for: 402), .quotaExhausted)
        XCTAssertEqual(LiveHTTPStatus.failure(for: 429), .rateLimited)
        XCTAssertEqual(LiveHTTPStatus.failure(for: 503), .connectionFailed)
    }

    func testEveryProviderHasAnAdapter() {
        for id in LiveTranscriptionProviderID.allCases {
            XCTAssertEqual(LiveTranscriptionAdapters.make(id).provider, id)
        }
    }
}
