import Foundation
import XCTest

/// Covers the guard that keeps test runs from changing the installed app's real settings.
/// The logic cases use a throwaway preferences domain, never the app's own.
final class TestDefaultsGuardTests: XCTestCase {
    /// Left in the app's real domain on purpose. The run-level guard must remove it when the bundle
    /// finishes: `defaults read <host bundle id> FluidVoiceTestDefaultsGuardSentinel` must then fail.
    static let sentinelKey = "FluidVoiceTestDefaultsGuardSentinel"

    private var domainName = ""
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.domainName = "com.renatobeltrao.fluidvoice.tests.defaults-guard.\(UUID().uuidString)"
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestDefaultsGuardTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: self.domainName)
        try? FileManager.default.removeItem(at: self.directory)
        try super.tearDownWithError()
    }

    func testRunGuardIsActiveForTheHostDomainAndLeavesNoSentinelBehind() throws {
        let domainGuard = try XCTUnwrap(
            FluidDictationIntegrationTestsPrincipal.activeGuard,
            "The bundle's principal class must start the guard before the first test"
        )
        XCTAssertEqual(domainGuard.domainName, AppPreferencesSnapshot.hostDomainName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: domainGuard.stateURL.path))

        UserDefaults.standard.set("written by TestDefaultsGuardTests", forKey: Self.sentinelKey)
        XCTAssertNotNil(UserDefaults.standard.persistentDomain(forName: domainGuard.domainName)?[Self.sentinelKey])
    }

    func testEndReplacesTheDomainWholesale() throws {
        self.setDomain(["kept": "original", "changed": 1, "removed": true])
        let domainGuard = self.makeGuard(pid: 10)

        XCTAssertEqual(try domainGuard.begin(), .recordedCurrentDomain)
        self.setDomain(["kept": "original", "changed": 2, "added": "fixture"])

        XCTAssertEqual(try domainGuard.end(), .restored)
        XCTAssertEqual(self.domain(), ["kept": "original", "changed": 1, "removed": true] as NSDictionary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: domainGuard.stateURL.path))
    }

    func testEndRemovesADomainThatDidNotExistBeforeTheRun() throws {
        let domainGuard = self.makeGuard(pid: 10)

        XCTAssertEqual(try domainGuard.begin(), .recordedCurrentDomain)
        self.setDomain(["added": "fixture"])

        XCTAssertEqual(try domainGuard.end(), .restored)
        XCTAssertEqual(self.domain().count, 0)
    }

    func testBeginRestoresTheRecordLeftByACrashedRun() throws {
        self.setDomain(["setting": "real"])
        let crashed = self.makeGuard(pid: 10, alive: [10])
        XCTAssertEqual(try crashed.begin(), .recordedCurrentDomain)
        self.setDomain(["setting": "fixture", "leaked": true])

        // Process 10 never reached `end()` and is gone now.
        let next = self.makeGuard(pid: 20, alive: [20])
        XCTAssertEqual(try next.begin(), .restoredAbandonedRecord)
        XCTAssertEqual(self.domain(), ["setting": "real"] as NSDictionary)

        self.setDomain(["setting": "fixture of the next run"])
        XCTAssertEqual(try next.end(), .restored)
        XCTAssertEqual(self.domain(), ["setting": "real"] as NSDictionary)
    }

    func testConcurrentRunsKeepTheFirstRecordUntilTheLastRunEnds() throws {
        self.setDomain(["setting": "real"])
        var alive: Set<Int32> = [10, 20]
        let first = self.makeGuard(pid: 10) { alive.contains($0.pid) }
        let second = self.makeGuard(pid: 20) { alive.contains($0.pid) }

        XCTAssertEqual(try first.begin(), .recordedCurrentDomain)
        self.setDomain(["setting": "fixture of the first run"])
        XCTAssertEqual(try second.begin(), .joinedActiveRun)
        XCTAssertEqual(self.domain(), ["setting": "fixture of the first run"] as NSDictionary)

        XCTAssertEqual(try first.end(), .leftForActiveRun)
        alive.remove(10)
        XCTAssertEqual(self.domain(), ["setting": "fixture of the first run"] as NSDictionary)

        XCTAssertEqual(try second.end(), .restored)
        XCTAssertEqual(self.domain(), ["setting": "real"] as NSDictionary)
    }

    func testEndWithoutARecordLeavesTheDomainAlone() throws {
        self.setDomain(["setting": "current"])
        XCTAssertEqual(try self.makeGuard(pid: 10).end(), .noRecord)
        XCTAssertEqual(self.domain(), ["setting": "current"] as NSDictionary)
    }

    func testRunningProcessCheckRejectsAReusedProcessID() {
        let current = PersistentDomainGuard.currentProcess
        XCTAssertTrue(PersistentDomainGuard.isRunning(current))
        XCTAssertFalse(PersistentDomainGuard.isRunning(.init(pid: current.pid, startTime: current.startTime - 60)))
    }

    func testSnapshotRestoresTheDomainExactly() {
        self.setDomain(["setting": "real", "other": 3])
        let snapshot = AppPreferencesSnapshot(domainName: self.domainName)
        self.setDomain(["setting": "fixture", "added": true])

        snapshot.restore()

        XCTAssertEqual(self.domain(), ["setting": "real", "other": 3] as NSDictionary)
    }

    // MARK: - Helpers

    private func makeGuard(pid: Int32, alive: Set<Int32>) -> PersistentDomainGuard {
        self.makeGuard(pid: pid) { alive.contains($0.pid) }
    }

    private func makeGuard(
        pid: Int32,
        isAlive: @escaping (PersistentDomainGuard.Participant) -> Bool = { _ in false }
    ) -> PersistentDomainGuard {
        PersistentDomainGuard(
            domainName: self.domainName,
            directory: self.directory,
            participant: .init(pid: pid, startTime: 1),
            isAlive: isAlive
        )
    }

    private func setDomain(_ domain: [String: Any]) {
        UserDefaults.standard.setPersistentDomain(domain, forName: self.domainName)
    }

    private func domain() -> NSDictionary {
        (UserDefaults.standard.persistentDomain(forName: self.domainName) ?? [:]) as NSDictionary
    }
}
