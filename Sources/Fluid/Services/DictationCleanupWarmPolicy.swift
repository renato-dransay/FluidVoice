import Foundation

/// Whether a dictation should open the connection to its Cleanup Style's text provider while the user is
/// still speaking. Only a provider that will receive a request is contacted, and never a local server.
nonisolated enum DictationCleanupWarmPolicy {
    enum Moment: String, Sendable {
        case start
        case stop
    }

    /// What decides whether a cleanup request to a remote provider can follow this recording.
    struct Conditions: Sendable {
        let isRecordingDictation: Bool
        let isPromptTest: Bool
        let cleanupConfigured: Bool
        let usesFluidIntelligence: Bool
        let combinedCloudDictation: Bool
        let baseURL: String
        let isLocalEndpoint: Bool
        let warmUpEnabled: Bool
    }

    /// The origin to warm, or nil when no cleanup request to a remote provider can follow this recording.
    static func origin(_ conditions: Conditions) -> URL? {
        guard conditions.isRecordingDictation, !conditions.isPromptTest, conditions.cleanupConfigured,
              !conditions.usesFluidIntelligence, !conditions.combinedCloudDictation, !conditions.isLocalEndpoint,
              conditions.warmUpEnabled,
              let url = URL(string: conditions.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return ConnectionWarmer.origin(of: url)
    }

    /// Writes the warm-up's benchmark line; `subject` names the host or provider it went to.
    static func log(target: String, subject: String, moment: Moment, outcome: ConnectionWarmer.Outcome, startedAt: TimeInterval) {
        let elapsed = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
        DebugLogger.shared.benchmark(
            "APP_BENCH",
            message: "warm target=\(target) \(subject) at=\(moment.rawValue) result=\(outcome.rawValue) elapsedMs=\(elapsed)",
            source: "AppBenchmark"
        )
    }
}
