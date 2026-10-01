import Foundation

/// What a Live cloud provider transcribed during one recording. It is written to the session
/// directory when the recording stops, and the Live cloud backend builds the completed transcript
/// from it, so nothing is uploaded or transcribed again afterwards.
nonisolated struct MeetingLiveCloudTranscript: Codable, Equatable, Sendable {
    static let fileName = "live-cloud-transcript.json"
    static let currentSchemaVersion = 1

    nonisolated struct Turn: Codable, Equatable, Sendable {
        let trackKind: MeetingAudioTrackKind
        let text: String
        /// Capture presentation time in seconds, on the clock of the recorded chunks.
        let presentationStart: Double
        let presentationEnd: Double
    }

    var schemaVersion = Self.currentSchemaVersion
    let provider: LiveTranscriptionProviderID
    let modelID: String
    var turns: [Turn]

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: directory), options: [.atomic])
    }

    /// Nil when the recording has no Live cloud transcript.
    static func load(from directory: URL) throws -> Self? {
        let url = Self.url(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let transcript = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard transcript.schemaVersion == Self.currentSchemaVersion else { throw MeetingLiveCloudTranscriptError.unreadable }
        return transcript
    }
}

nonisolated enum MeetingLiveCloudTranscriptError: LocalizedError, Equatable {
    /// The recording streamed nothing to a provider: it used another transcription option, or the
    /// app quit before the transcript was saved.
    case missing
    case unreadable

    var errorDescription: String? {
        switch self {
        case .missing:
            "This meeting has no Live cloud transcript. It was recorded with another transcription option, or the app quit before the transcript was saved. Choose Local or OpenRouter in FluidMeet settings and retry."
        case .unreadable:
            "The Live cloud transcript of this meeting could not be read. Choose Local or OpenRouter in FluidMeet settings and retry."
        }
    }
}
