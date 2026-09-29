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
cp "$ROOT/Tests/FluidDictationIntegrationTests/CloudTranscriptionClientTests.swift" "$HARNESS/Tests/CloudTranscriptionHarnessTests/"
cp "$ROOT/Tests/FluidDictationIntegrationTests/CloudTranscriptionChunkTests.swift" "$HARNESS/Tests/CloudTranscriptionHarnessTests/"
cat > "$HARNESS/Sources/CloudTranscriptionHarness/AppBoundaryStubs.swift" <<'SWIFT'
import Foundation
struct PronunciationEnrollmentCapture {}
struct DictionaryLearningAlignment {}
enum ForkIdentity {
    static func applicationSupportURL() -> URL? { nil }
}
SWIFT
swift test --package-path "$HARNESS" --scratch-path "$ROOT/.build/cloud-transcription-tests" "$@"
