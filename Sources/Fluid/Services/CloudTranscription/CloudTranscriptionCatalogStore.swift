import Foundation

nonisolated struct CloudTranscriptionCatalogEntry: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

/// OpenRouter's transcription and audio-chat catalogs as last fetched, plus the word-timing checks
/// run on this Mac. Reads are synchronous and lock-protected because configuration validation runs
/// off the main actor.
nonisolated final class CloudTranscriptionCatalogStore: @unchecked Sendable {
    static let shared = CloudTranscriptionCatalogStore(defaults: .standard)
    /// The catalog changes rarely, so one fetch per interval keeps settings from calling out on every visit.
    static let refreshInterval: TimeInterval = 6 * 60 * 60

    private static let entriesKey = "CloudTranscriptionCatalogEntries"
    private static let audioEntriesKey = "CloudAudioDictationCatalogEntries"
    private static let refreshedAtKey = "CloudTranscriptionCatalogRefreshedAt"
    private static let checksKey = "CloudTranscriptionWordTimingChecks"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var listed: [CloudTranscriptionCatalogEntry]
    private var audioListed: [CloudTranscriptionCatalogEntry]
    private var checks: [String: Bool]
    private var refreshedAt: Date?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.listed = defaults.data(forKey: Self.entriesKey)
            .flatMap { try? JSONDecoder().decode([CloudTranscriptionCatalogEntry].self, from: $0) } ?? []
        self.audioListed = defaults.data(forKey: Self.audioEntriesKey)
            .flatMap { try? JSONDecoder().decode([CloudTranscriptionCatalogEntry].self, from: $0) } ?? []
        self.checks = defaults.dictionary(forKey: Self.checksKey) as? [String: Bool] ?? [:]
        let stamp = defaults.double(forKey: Self.refreshedAtKey)
        self.refreshedAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    var models: [CloudTranscriptionModel] {
        let (listed, checks) = self.lock.withLock { (self.listed, self.checks) }
        let builtIn = CloudTranscriptionModel.builtIn.map { model in
            // Documented timings are never downgraded. A documented absence yields to a passing check,
            // so a provider that adds timings later needs no app update.
            guard !model.supportsWordTimings, checks[model.id] == true else { return model }
            return CloudTranscriptionModel(id: model.id, name: model.name, wordTimingSupport: .supported, languageHintProviderTags: model.languageHintProviderTags)
        }
        let builtInIDs = Set(builtIn.map(\.id))
        let discovered = listed.filter { !builtInIDs.contains($0.id) }.map { entry in
            let support: CloudWordTimingSupport = checks[entry.id].map { $0 ? .supported : .unsupported } ?? .unverified
            return CloudTranscriptionModel(id: entry.id, name: entry.name, wordTimingSupport: support, languageHintProviderTags: [])
        }
        return builtIn + discovered
    }

    var audioDictationModels: [CloudAudioDictationModel] {
        let listed = self.lock.withLock { self.audioListed }
        let builtInIDs = Set(CloudAudioDictationModel.builtIn.map(\.id))
        return CloudAudioDictationModel.builtIn + listed.filter { !builtInIDs.contains($0.id) }.map {
            CloudAudioDictationModel(id: $0.id, name: $0.name)
        }
    }

    func isRefreshDue(now: Date = Date()) -> Bool {
        guard let refreshedAt = self.lock.withLock({ self.refreshedAt }) else { return true }
        // A clock moved backwards must not postpone the refresh indefinitely.
        return now < refreshedAt || now.timeIntervalSince(refreshedAt) >= Self.refreshInterval
    }

    /// Replaces the listed transcription models, so a model OpenRouter withdrew stops being offered.
    /// An empty list is ignored: it means a bad response, never an empty catalog.
    func replaceListedModels(_ entries: [CloudTranscriptionCatalogEntry], now: Date = Date()) {
        guard let (normalized, data) = Self.normalize(entries) else { return }
        self.lock.withLock {
            self.listed = normalized
            self.refreshedAt = now
            self.defaults.set(data, forKey: Self.entriesKey)
            self.defaults.set(now.timeIntervalSince1970, forKey: Self.refreshedAtKey)
        }
    }

    /// Replaces the listed audio-chat models used by combined dictation. Same empty-list rule.
    func replaceListedAudioDictationModels(_ entries: [CloudTranscriptionCatalogEntry]) {
        guard let (normalized, data) = Self.normalize(entries) else { return }
        self.lock.withLock {
            self.audioListed = normalized
            self.defaults.set(data, forKey: Self.audioEntriesKey)
        }
    }

    private static func normalize(_ entries: [CloudTranscriptionCatalogEntry]) -> (entries: [CloudTranscriptionCatalogEntry], data: Data)? {
        var seen = Set<String>()
        let normalized = entries.compactMap { entry -> CloudTranscriptionCatalogEntry? in
            let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return CloudTranscriptionCatalogEntry(id: id, name: name.isEmpty ? id : name)
        }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        guard !normalized.isEmpty, let data = try? JSONEncoder().encode(normalized) else { return nil }
        return (normalized, data)
    }

    func recordWordTimingCheck(modelID: String, supported: Bool) {
        self.lock.withLock {
            self.checks[modelID] = supported
            self.defaults.set(self.checks, forKey: Self.checksKey)
        }
    }

    /// Fetches both public catalogs when the cached copy is stale, or always when forced.
    /// A failed fetch throws and leaves the cached lists in place. Returns whether a fetch ran.
    @discardableResult
    func refresh(using client: OpenRouterTranscriptionClient, force: Bool = false, now: Date = Date()) async throws -> Bool {
        guard force || self.isRefreshDue(now: now) else { return false }
        // Each list is saved as soon as it arrives, so a failure in the second fetch keeps the first.
        self.replaceListedModels(try await client.transcriptionCatalog(), now: now)
        self.replaceListedAudioDictationModels(try await client.audioDictationCatalog())
        return true
    }
}
