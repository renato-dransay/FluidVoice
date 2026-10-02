import Darwin
import Foundation
import XCTest

// The test host is the installed app itself ("FluidVoice Personal"), so `UserDefaults.standard`
// and `SettingsStore.shared` read and write the owner's real settings. Two layers keep a test run
// from changing them:
//
// 1. `FluidDictationIntegrationTestsPrincipal`, the bundle's principal class, copies the whole
//    preferences domain before the first test and puts it back, wholesale, when the bundle finishes.
//    The copy is kept in a file until then, so a run that crashed or was killed is repaired by the
//    next run, and concurrent runs share the oldest copy instead of saving each other's fixtures.
// 2. `AppPreferencesSnapshot` and `preserveAppPreferences()` let an individual test put the domain
//    back as soon as it ends, so a later test in the same run sees the real settings again.

/// A copy of one preferences domain that can replace the live domain exactly: keys added after the
/// copy are removed, changed keys get their old values back and removed keys return.
struct AppPreferencesSnapshot: @unchecked Sendable {
    /// The test host's own domain, which is the installed app's real settings.
    static var hostDomainName: String {
        Bundle.main.bundleIdentifier ?? ""
    }

    let domainName: String
    /// Empty when the domain did not exist, which restores as no domain.
    let domain: [String: Any]

    init(domainName: String = AppPreferencesSnapshot.hostDomainName) {
        self.domainName = domainName
        self.domain = UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]
    }

    init(domainName: String, domain: [String: Any]) {
        self.domainName = domainName
        self.domain = domain
    }

    func restore() {
        Self.replaceDomain(self.domainName, with: self.domain)
    }

    static func replaceDomain(_ domainName: String, with domain: [String: Any]) {
        guard !domainName.isEmpty else { return }
        let defaults = UserDefaults.standard
        if !domain.isEmpty {
            defaults.setPersistentDomain(domain, forName: domainName)
        } else {
            defaults.removePersistentDomain(forName: domainName)
        }
        defaults.synchronize()
    }
}

extension XCTestCase {
    /// Puts the app's whole preferences domain back when the current test ends, including after a
    /// failure or a thrown error. Use it for tests that write settings through `SettingsStore.shared`
    /// or `UserDefaults.standard`, especially ones that restore a settings backup, which writes
    /// almost every key.
    func preserveAppPreferences() {
        let snapshot = AppPreferencesSnapshot()
        self.addTeardownBlock { snapshot.restore() }
    }
}

/// Keeps a test run from changing a preferences domain. `begin()` records the domain in a state file
/// before the first test; `end()` replaces the domain with that record after the last one.
///
/// The state file also lists the processes using it. A file whose processes are all gone was left by
/// a run that crashed or was killed, so its record is the real pre-test state: `begin()` restores it
/// before anything else. A file with a live process belongs to a concurrent run; this run joins it
/// and keeps that older record, and only the last run to finish restores the domain.
final class PersistentDomainGuard {
    struct Participant: Equatable {
        let pid: Int32
        let startTime: Double
    }

    enum BeginOutcome: Equatable {
        /// No earlier record existed; the current domain was recorded.
        case recordedCurrentDomain
        /// An earlier run crashed or was killed; its record was restored and kept.
        case restoredAbandonedRecord
        /// A concurrent run is still active; its record is kept.
        case joinedActiveRun
    }

    enum EndOutcome: Equatable {
        case restored
        /// Another run is still active and will restore the domain when it ends.
        case leftForActiveRun
        case noRecord
    }

    let domainName: String
    let stateURL: URL
    private let lockURL: URL
    private let participant: Participant
    private let isAlive: (Participant) -> Bool

    init(
        domainName: String,
        directory: URL,
        participant: Participant = PersistentDomainGuard.currentProcess,
        isAlive: @escaping (Participant) -> Bool = PersistentDomainGuard.isRunning
    ) {
        self.domainName = domainName
        self.stateURL = directory.appendingPathComponent("\(domainName).plist")
        self.lockURL = directory.appendingPathComponent("\(domainName).lock")
        self.participant = participant
        self.isAlive = isAlive
    }

    /// `~/Library/Caches/FluidVoiceTestDefaultsGuard`, outside every build folder, so all
    /// checkouts and worktrees that test the same app share one record.
    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("FluidVoiceTestDefaultsGuard", isDirectory: true)
    }

    static var currentProcess: Participant {
        let pid = ProcessInfo.processInfo.processIdentifier
        return Participant(pid: pid, startTime: Self.startTime(of: pid) ?? 0)
    }

    /// True while the recorded process is running. The start time tells a reused process ID apart.
    static func isRunning(_ participant: Participant) -> Bool {
        guard let startTime = Self.startTime(of: participant.pid) else { return false }
        return abs(startTime - participant.startTime) < 0.001
    }

    private static func startTime(of pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    @discardableResult
    func begin() throws -> BeginOutcome {
        try self.withLock {
            if let state = self.readState() {
                let active = state.participants.filter { $0 != self.participant && self.isAlive($0) }
                let outcome: BeginOutcome
                if active.isEmpty {
                    AppPreferencesSnapshot.replaceDomain(self.domainName, with: state.domain)
                    outcome = .restoredAbandonedRecord
                } else {
                    outcome = .joinedActiveRun
                }
                try self.writeState(domain: state.domain, participants: active + [self.participant])
                return outcome
            }
            let domain = UserDefaults.standard.persistentDomain(forName: self.domainName) ?? [:]
            try self.writeState(domain: domain, participants: [self.participant])
            return .recordedCurrentDomain
        }
    }

    @discardableResult
    func end() throws -> EndOutcome {
        try self.withLock {
            guard let state = self.readState() else { return .noRecord }
            let active = state.participants.filter { $0 != self.participant && self.isAlive($0) }
            guard active.isEmpty else {
                try self.writeState(domain: state.domain, participants: active)
                return .leftForActiveRun
            }
            AppPreferencesSnapshot.replaceDomain(self.domainName, with: state.domain)
            try FileManager.default.removeItem(at: self.stateURL)
            return .restored
        }
    }

    // MARK: - State file

    private struct State {
        let domain: [String: Any]
        let participants: [Participant]
    }

    private func readState() -> State? {
        guard let data = try? Data(contentsOf: self.stateURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let participants = (root["participants"] as? [[String: Any]] ?? []).compactMap { entry -> Participant? in
            guard let pid = entry["pid"] as? Int, let startTime = entry["startTime"] as? Double else { return nil }
            return Participant(pid: Int32(pid), startTime: startTime)
        }
        return State(domain: root["domain"] as? [String: Any] ?? [:], participants: participants)
    }

    private func writeState(domain: [String: Any], participants: [Participant]) throws {
        let root: [String: Any] = [
            "domain": domain,
            "participants": participants.map { ["pid": Int($0.pid), "startTime": $0.startTime] },
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: self.stateURL, options: .atomic)
        // The record holds the owner's settings; keep it readable by the owner only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.stateURL.path)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: self.stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(self.lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

/// The principal class of the FluidDictationIntegrationTests bundle (`NSPrincipalClass` in its
/// Info.plist). XCTest creates it when it loads the bundle, before any test runs.
@objc(FluidDictationIntegrationTestsPrincipal)
final class FluidDictationIntegrationTestsPrincipal: NSObject, XCTestObservation {
    /// The guard protecting this run, or nil when the host has no bundle identifier or the record
    /// could not be written.
    private(set) static var activeGuard: PersistentDomainGuard?

    override init() {
        super.init()
        // Recorded here rather than in `testBundleWillStart` so writes made while the host app
        // launches are reverted too.
        Self.beginGuard()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_: Bundle) {
        Self.beginGuard()
    }

    func testBundleDidFinish(_: Bundle) {
        guard let domainGuard = Self.activeGuard else { return }
        Self.activeGuard = nil
        do {
            let outcome = try domainGuard.end()
            Self.log("ended (\(outcome)) for \(domainGuard.domainName)")
        } catch {
            Self.log("could not restore \(domainGuard.domainName): \(error)")
        }
    }

    private static func beginGuard() {
        guard self.activeGuard == nil else { return }
        let domainName = AppPreferencesSnapshot.hostDomainName
        guard !domainName.isEmpty else {
            self.log("inactive: the test host has no bundle identifier")
            return
        }
        let domainGuard = PersistentDomainGuard(domainName: domainName, directory: PersistentDomainGuard.defaultDirectory)
        do {
            let outcome = try domainGuard.begin()
            self.activeGuard = domainGuard
            self.log("began (\(outcome)) for \(domainName)")
        } catch {
            self.log("could not record \(domainName): \(error)")
        }
    }

    private static func log(_ message: String) {
        print("[TestDefaultsGuard] \(message)")
    }
}
