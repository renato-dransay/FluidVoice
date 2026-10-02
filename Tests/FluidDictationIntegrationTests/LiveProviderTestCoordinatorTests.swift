#if canImport(LiveTranscriptionHarness)
@testable import LiveTranscriptionHarness
#else
@testable import FluidVoice_Debug
#endif
import XCTest

@MainActor
final class LiveProviderTestCoordinatorTests: XCTestCase {
    func testArmingOverridesTheProviderUntilDisarmed() throws {
        let coordinator = LiveProviderTestCoordinator(defaults: try self.defaults())
        XCTAssertNil(coordinator.overrideConfiguration)
        coordinator.arm(.deepgram)
        XCTAssertEqual(coordinator.overrideConfiguration?.provider, .deepgram)
        coordinator.disarm()
        XCTAssertNil(coordinator.overrideConfiguration)
    }

    func testASuccessfulTranscriptMarksTheProviderTestedButAnEmptyOneDoesNot() throws {
        let coordinator = LiveProviderTestCoordinator(defaults: try self.defaults())
        coordinator.arm(.soniox)
        coordinator.record(transcript: "", latencyMilliseconds: 300, error: nil)
        XCTAssertFalse(coordinator.hasPassed(.soniox))
        XCTAssertEqual(coordinator.lastError, "No speech heard. Check your microphone and try again.")
        coordinator.record(transcript: "hello", latencyMilliseconds: 310, error: nil)
        XCTAssertTrue(coordinator.hasPassed(.soniox))
        XCTAssertEqual(coordinator.lastLatencyMilliseconds, 310)
    }

    func testAFailedTestNamesTheReasonAndDoesNotPass() throws {
        let coordinator = LiveProviderTestCoordinator(defaults: try self.defaults())
        coordinator.arm(.assemblyAI)
        coordinator.record(transcript: "", latencyMilliseconds: nil, error: "The key was rejected.")
        XCTAssertFalse(coordinator.hasPassed(.assemblyAI))
        XCTAssertEqual(coordinator.lastError, "Test failed: The key was rejected.")
        XCTAssertNil(coordinator.lastLatencyMilliseconds)
    }

    func testAResultArrivingAfterDisarmingIsIgnored() throws {
        let coordinator = LiveProviderTestCoordinator(defaults: try self.defaults())
        coordinator.arm(.soniox)
        coordinator.disarm()
        coordinator.record(transcript: "hello", latencyMilliseconds: 310, error: nil)
        XCTAssertFalse(coordinator.hasPassed(.soniox))
        XCTAssertEqual(coordinator.lastTranscript, "")
    }

    func testForgettingAPassedTestLeavesOtherProvidersTested() throws {
        let coordinator = LiveProviderTestCoordinator(defaults: try self.defaults())
        for provider in [LiveTranscriptionProviderID.soniox, .deepgram] {
            coordinator.arm(provider)
            coordinator.record(transcript: "hello", latencyMilliseconds: 300, error: nil)
        }
        coordinator.forgetPassedTest(for: .soniox)
        XCTAssertFalse(coordinator.hasPassed(.soniox))
        XCTAssertTrue(coordinator.hasPassed(.deepgram))
    }

    func testAKeyChangeForgetsThePassAndDisarmsTheProvidersTest() throws {
        let center = NotificationCenter()
        let coordinator = LiveProviderTestCoordinator(defaults: try self.defaults(), notificationCenter: center)
        for provider in [LiveTranscriptionProviderID.soniox, .deepgram] {
            coordinator.arm(provider)
            coordinator.record(transcript: "hello", latencyMilliseconds: 300, error: nil)
        }
        func post(_ providerID: String, removed: Bool) {
            let change = ProviderAPIKeyChange(providerID: providerID, removed: removed, affectedActiveEngine: false)
            center.post(name: .providerAPIKeyChanged, object: nil, userInfo: change.userInfo)
        }

        post("soniox", removed: false)
        XCTAssertFalse(coordinator.hasPassed(.soniox), "A replaced key is untested again")
        XCTAssertTrue(coordinator.hasPassed(.deepgram))
        XCTAssertEqual(coordinator.armedProvider, .deepgram, "Another provider's key change keeps the test armed")

        post("groq", removed: true)
        XCTAssertEqual(coordinator.armedProvider, .deepgram, "A provider without Live changes nothing")

        post("deepgram", removed: false)
        XCTAssertFalse(coordinator.hasPassed(.deepgram))
        XCTAssertNil(coordinator.armedProvider, "A replaced key disarms the test that was armed for the old key")

        coordinator.arm(.deepgram)
        post("deepgram", removed: true)
        XCTAssertNil(coordinator.armedProvider, "A test without a key could only fail")
    }

    private func defaults() throws -> UserDefaults {
        let suite = "LiveProviderTestCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
