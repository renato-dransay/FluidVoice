#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$(mktemp -d "${TMPDIR:-/tmp}/fluid-cloud-tests.XXXXXX")"
trap 'rm -rf "$HARNESS"' EXIT
mkdir -p "$HARNESS/Sources/CloudTranscriptionHarness" "$HARNESS/Tests/CloudTranscriptionHarnessTests"
cat > "$HARNESS/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "CloudTranscriptionHarness", platforms: [.macOS(.v15)], targets: [
    .target(name: "CloudTranscriptionHarness", swiftSettings: [.defaultIsolation(MainActor.self)]),
    .testTarget(name: "CloudTranscriptionHarnessTests", dependencies: ["CloudTranscriptionHarness"]),
])
SWIFT
cp "$ROOT"/Sources/Fluid/Services/CloudTranscription/*.swift "$HARNESS/Sources/CloudTranscriptionHarness/"
cp "$ROOT/Sources/Fluid/Services/TranscriptionProvider.swift" "$HARNESS/Sources/CloudTranscriptionHarness/"
cp "$ROOT/Sources/Fluid/Persistence/SettingsStore+CloudTranscription.swift" "$HARNESS/Sources/CloudTranscriptionHarness/"
cp "$ROOT/Sources/Fluid/Services/LiveTranscription/LiveTranscriptionTypes.swift" "$HARNESS/Sources/CloudTranscriptionHarness/"
cp "$ROOT/Tests/FluidDictationIntegrationTests/CloudTranscriptionClientTests.swift" "$HARNESS/Tests/CloudTranscriptionHarnessTests/"
cp "$ROOT/Tests/FluidDictationIntegrationTests/CloudTranscriptionChunkTests.swift" "$HARNESS/Tests/CloudTranscriptionHarnessTests/"
cp "$ROOT/Tests/FluidDictationIntegrationTests/CloudTranscriptionAudioDictationTests.swift" "$HARNESS/Tests/CloudTranscriptionHarnessTests/"
cp "$ROOT/Tests/FluidDictationIntegrationTests/CloudTranscriptionSettingsTests.swift" "$HARNESS/Tests/CloudTranscriptionHarnessTests/"
cat > "$HARNESS/Sources/CloudTranscriptionHarness/AppBoundaryStubs.swift" <<'SWIFT'
import Foundation
import Combine
struct PronunciationEnrollmentCapture {}
struct DictionaryLearningAlignment {}
enum ForkIdentity {
    static func applicationSupportURL() -> URL? { nil }
}
final class SettingsStore: ObservableObject {
    /// Live cloud lives outside this harness, so the source getter sees no usable live provider.
    var activeLiveProvider: LiveTranscriptionProviderID? { nil }
    var openRouterAIProviderModel: String? { nil }
    static func whisperLanguageCode(fromStoredValue value: String?) -> String? {
        guard let value, CloudTranscriptionConfiguration.supportedLanguageCodes.contains(value) else { return nil }
        return value
    }
}
nonisolated final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()
    func debug(_ message: @autoclosure () -> String, source: String = "App") {}
    func info(_ message: String, source: String = "App") {}
    func warning(_ message: String, source: String = "App") {}
}
final class KeychainService {
    static let shared = KeychainService()
    func fetchKey(for id: String) throws -> String? { nil }
    func deleteKey(for id: String) throws {}
    func storeKey(_ key: String, for id: String) throws {}
}
SWIFT
swift test --package-path "$HARNESS" --scratch-path "$ROOT/.build/cloud-transcription-tests" "$@"
