import Foundation

/// Protocols §4. Configuration in the query, audio as base64 in JSON chunks, manual commits. Each
/// committed transcript is final for its stretch of audio; partials replace the pending text.
/// ElevenLabs sends no end event, so the reply to the final commit ends the stream.
nonisolated struct ElevenLabsLiveAdapter: LiveTranscriptionAdapter {
    private enum CommitKind: Equatable {
        case plain
        case timed
    }

    // EVIDENCE: https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies (checked 2026-10-01)
    /// Manual mode still commits on its own after about 36 s of uncommitted audio, and the docs call a
    /// commit every 20-30 s good practice.
    private static let commitIntervalMilliseconds = 30_000

    /// Commit replies received, a reply sent in both variants counting once.
    private var commitCount = 0
    /// Commits this client sent: one per 30 s of audio, and the final one.
    private var commitsSent = 0
    private var uncommittedMilliseconds = 0
    private var lastCommit: (segment: LiveTranscriptSegment, kind: CommitKind, isPaired: Bool)?
    private var finishRequested = false

    var provider: LiveTranscriptionProviderID { .elevenLabs }
    var waitsForReady: Bool { true }

    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        var items = [
            URLQueryItem(name: "model_id", value: configuration.modelID),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            // Word timings let a reconnect resume after the last commit instead of replaying everything.
            URLQueryItem(name: "include_timestamps", value: "true"),
        ]
        if let language = configuration.languageCode { items.append(URLQueryItem(name: "language_code", value: language)) }
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")
        components?.queryItems = items
        guard let url = components?.url else { throw LiveTranscriptionError.connectionFailed }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    // JUDGMENT: a server auto-commit can answer while the final commit is on its way, and nothing in either
    // reply tells them apart, so the first commit after the stop could end the stream with text missing.
    // Committing every 30 s keeps the uncommitted audio under the server's ~36 s, so every commit is this
    // client's and the final one is the reply that brings the count level.
    mutating func audioMessage(_ pcm16: Data) -> LiveTransportMessage {
        self.uncommittedMilliseconds += pcm16.count / LivePCM16.bytesPerMillisecond
        let commit = self.uncommittedMilliseconds >= Self.commitIntervalMilliseconds
        if commit {
            self.uncommittedMilliseconds = 0
            self.commitsSent += 1
        }
        // Base64 text needs no JSON escaping, so the chunk is written directly instead of serialized.
        return .text(#"{"audio_base_64":""# + pcm16.base64EncodedString() + #"","commit":\#(commit),"message_type":"input_audio_chunk","sample_rate":16000}"#)
    }

    // JUDGMENT: when the last chunk already carried an interval commit, no audio is left uncommitted, and a
    // second commit right behind it would be an empty one in a short burst. That commit's reply ends the
    // stream instead.
    // EVIDENCE: https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/event-reference (checked 2026-10-01):
    // `commit_throttled` is an error for "too many commit requests made in a short period of time", and an
    // error is returned "before the WebSocket connection is closed". The docs give no minimum interval.
    mutating func finishMessages() -> [LiveTransportMessage] {
        self.finishRequested = true
        if self.commitsSent > 0, self.uncommittedMilliseconds == 0 { return [] }
        self.commitsSent += 1
        return [.text(#"{"audio_base_64":"","commit":true,"message_type":"input_audio_chunk","sample_rate":16000}"#)]
    }

    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        guard let object = LiveJSON.object(message), let type = object["message_type"] as? String else { return [] }
        switch type {
        case "session_started":
            return [.ready]
        case "partial_transcript":
            return [.pending(object["text"] as? String ?? "")]
        case "committed_transcript":
            return self.commit(text: object["text"] as? String ?? "", end: nil, kind: .plain)
        case "committed_transcript_with_timestamps":
            let end = (object["words"] as? [[String: Any]])?.last.flatMap { ($0["end"] as? Double).map { Int(($0 * 1000).rounded()) } }
            return self.commit(text: object["text"] as? String ?? "", end: end, kind: .timed)
        default:
            // Error frames carry an `error` field and name their kind in `message_type`; warnings do not end the session.
            guard object["error"] != nil else { return [] }
            return [.failure(Self.failure(type: type))]
        }
    }

    func keyCheckRequest(apiKey: String) throws -> URLRequest {
        try LiveHTTPStatus.request("https://api.elevenlabs.io/v1/models", headers: ["xi-api-key": apiKey])
    }

    // EVIDENCE: https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/event-reference (checked 2026-10-01):
    // with include_timestamps one commit sends both messages, `committed_transcript_with_timestamps` "after the
    // committed transcript". A commit of the other kind with the same text right after the previous one is
    // read as the same commit, so the text never doubles; the timed variant's end is kept.
    private mutating func commit(text: String, end: Int?, kind: CommitKind) -> [LiveTranscriptUpdate] {
        let segment: LiveTranscriptSegment
        if let last = self.lastCommit, !last.isPaired, last.kind != kind, last.segment.text == text {
            segment = .init(id: last.segment.id, text: text, isFinal: true, audioEndMilliseconds: end ?? last.segment.audioEndMilliseconds)
            self.lastCommit = (segment, kind, true)
            return [.segment(segment), .pending("")]
        }
        self.commitCount += 1
        segment = .init(id: "c\(self.commitCount)", text: text, isFinal: true, audioEndMilliseconds: end)
        self.lastCommit = (segment, kind, false)
        // Commits answer in order, so the reply that matches the final commit's count answers it.
        let isFinal = self.finishRequested && self.commitCount >= self.commitsSent
        return [.segment(segment), .pending("")] + (isFinal ? [.finished] : [])
    }

    private static func failure(type: String) -> LiveTranscriptionError {
        switch type {
        case "auth_error": .authentication
        case "quota_exceeded": .quotaExhausted
        // `queue_overflow` asks the client to send fewer requests, like a rate limit.
        case "rate_limited", "resource_exhausted", "queue_overflow": .rateLimited
        default: .sessionClosed(type)
        }
    }
}
