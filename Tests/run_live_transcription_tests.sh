#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$(mktemp -d "${TMPDIR:-/tmp}/fluid-live-tests.XXXXXX")"
trap 'rm -rf "$HARNESS"' EXIT
mkdir -p "$HARNESS/Sources/LiveTranscriptionHarness" "$HARNESS/Tests/LiveTranscriptionHarnessTests"
cat > "$HARNESS/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "LiveTranscriptionHarness", platforms: [.macOS(.v15)], targets: [
    .target(name: "LiveTranscriptionHarness", swiftSettings: [.defaultIsolation(MainActor.self)]),
    .testTarget(name: "LiveTranscriptionHarnessTests", dependencies: ["LiveTranscriptionHarness"]),
])
SWIFT
cp "$ROOT"/Sources/Fluid/Services/LiveTranscription/*.swift "$HARNESS/Sources/LiveTranscriptionHarness/"
cp "$ROOT/Sources/Fluid/Services/TranscriptionProvider.swift" "$HARNESS/Sources/LiveTranscriptionHarness/"
cp "$ROOT"/Tests/FluidDictationIntegrationTests/LiveTranscript*Tests.swift "$HARNESS/Tests/LiveTranscriptionHarnessTests/"
cat > "$HARNESS/Sources/LiveTranscriptionHarness/AppBoundaryStubs.swift" <<'SWIFT'
import Foundation
struct PronunciationEnrollmentCapture {}
struct DictionaryLearningAlignment {}
struct CloudAudioDictationOutput {}
nonisolated final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()
    func debug(_ message: @autoclosure () -> String, source: String = "App") {}
    func info(_ message: String, source: String = "App") {}
    func warning(_ message: String, source: String = "App") {}
    func error(_ message: String, source: String = "App") {}
}
SWIFT
swift test --package-path "$HARNESS" --scratch-path "$ROOT/.build/live-transcription-tests" "$@"
