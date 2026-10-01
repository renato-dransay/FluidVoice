import Combine
import Foundation

/// Streamed time per provider on this Mac. Providers do not report cost in-stream, so the app
/// shows time and recordings, never an estimate (UX §E10).
@MainActor
final class LiveTranscriptionUsageStore: ObservableObject {
    static let shared = LiveTranscriptionUsageStore(defaults: .standard)

    struct Totals: Codable, Equatable {
        var milliseconds = 0
        var recordings = 0

        var seconds: Int { self.milliseconds / 1000 }
    }

    @Published private(set) var totals: [LiveTranscriptionProviderID: Totals] = [:]
    private let defaults: UserDefaults
    private static let key = "LiveTranscriptionUsage"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: Totals].self, from: data)
        {
            self.totals = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                LiveTranscriptionProviderID(rawValue: key).map { ($0, value) }
            })
        }
    }

    func record(provider: LiveTranscriptionProviderID, milliseconds: Int) {
        guard milliseconds > 0 else { return }
        var entry = self.totals[provider] ?? Totals()
        entry.milliseconds += milliseconds
        entry.recordings += 1
        self.totals[provider] = entry
        let encoded = Dictionary(uniqueKeysWithValues: self.totals.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { self.defaults.set(data, forKey: Self.key) }
    }

    func totals(for provider: LiveTranscriptionProviderID) -> Totals { self.totals[provider] ?? Totals() }
}
