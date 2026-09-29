import Combine
import Foundation

@MainActor
final class CloudTranscriptionUsageStore: ObservableObject {
    static let shared = CloudTranscriptionUsageStore(directory: ForkIdentity.applicationSupportURL()?.appendingPathComponent("CloudTranscriptionMetadata", isDirectory: true))

    @Published private(set) var lastRecord: CloudTranscriptionUsageRecord?
    @Published private(set) var knownCostUSD = 0.0
    @Published private(set) var unknownCostCount = 0
    @Published private(set) var requestCount = 0
    @Published private(set) var persistenceError: String?
    private let fileURL: URL?
    private var recentRecords: [CloudTranscriptionUsageRecord] = []

    private struct Snapshot: Codable {
        let records: [CloudTranscriptionUsageRecord]
        let knownCostUSD: Double
        let unknownCostCount: Int
        let requestCount: Int
    }

    init(directory: URL?) {
        self.fileURL = directory?.appendingPathComponent("usage.json")
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
            self.recentRecords = Array(snapshot.records.suffix(1000))
            self.lastRecord = self.recentRecords.last
            self.knownCostUSD = snapshot.knownCostUSD
            self.unknownCostCount = snapshot.unknownCostCount
            self.requestCount = snapshot.requestCount
        } catch {
            self.persistenceError = "Previous cloud usage could not be loaded. Totals only include this session."
        }
    }

    func record(_ record: CloudTranscriptionUsageRecord) {
        self.lastRecord = record
        self.requestCount += 1
        if let cost = record.costUSD, cost.isFinite, cost >= 0 {
            self.knownCostUSD += cost
        } else {
            self.unknownCostCount += 1
        }
        self.recentRecords.append(record)
        if self.recentRecords.count > 1000 { self.recentRecords.removeFirst(self.recentRecords.count - 1000) }
        guard let fileURL else { return }
        do {
            let snapshot = Snapshot(records: self.recentRecords, knownCostUSD: self.knownCostUSD, unknownCostCount: self.unknownCostCount, requestCount: self.requestCount)
            let data = try JSONEncoder().encode(snapshot)
            let manager = FileManager.default
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: fileURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            self.persistenceError = nil
        } catch {
            self.persistenceError = "Cloud usage could not be saved. Totals remain available until the app closes."
        }
    }
}
