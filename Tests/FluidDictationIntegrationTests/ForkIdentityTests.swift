@testable import FluidVoice_Debug
import XCTest

@MainActor
final class ForkIdentityTests: XCTestCase {
    func testPersonalHostUsesIsolatedDataAndKeychain() {
        XCTAssertTrue(ForkIdentity.isPersonalBuild)
        XCTAssertEqual(ForkIdentity.appSupportFolderName(legacyName: "FluidVoice"), "FluidVoice Personal")
        XCTAssertEqual(ForkIdentity.appSupportFolderName(legacyName: "Fluid"), "FluidVoice Personal")
        XCTAssertEqual(ForkIdentity.logFolderName, "FluidVoice Personal")
        XCTAssertEqual(ForkIdentity.keychainServiceName, "com.renatobeltrao.fluidvoice.personal.provider-api-keys")
        XCTAssertEqual(ForkIdentity.applicationSupportURL()?.lastPathComponent, "FluidVoice Personal")
    }

    func testPersonalUpdaterNeverAdvertisesOfficialBinaryUpdate() async throws {
        XCTAssertTrue(ForkIdentity.isPersonalBuild)
        let result = try await SimpleUpdater.shared.checkForUpdate(owner: "unused", repo: "unused")
        XCTAssertFalse(result.hasUpdate)
        XCTAssertFalse(SimpleUpdater.shared.hasRollbackBackup())
    }

    func testPersonalUpdaterRefusesManualInstall() async {
        do {
            try await SimpleUpdater.shared.checkAndUpdate(owner: "unused", repo: "unused")
            XCTFail("Personal builds must refuse official binary installation")
        } catch SimpleUpdateError.personalBuildManagedLocally {
            XCTAssertFalse(SimpleUpdater.shared.isUpdateInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPersonalUpdaterRefusesOfficialRollback() async {
        do {
            try await SimpleUpdater.shared.rollbackToLatestBackup()
            XCTFail("Personal builds must use their local rollback tool")
        } catch SimpleUpdateError.personalBuildManagedLocally {
            XCTAssertFalse(SimpleUpdater.shared.isUpdateInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
