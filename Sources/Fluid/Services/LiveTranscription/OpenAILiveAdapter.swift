import Foundation

/// Protocols §6. A transcription session configured with `session.update`; audio is base64 JSON of
/// 24 kHz PCM; text arrives per conversation item as deltas that `completed` replaces. With turn
/// detection off, the finish commit creates the item whose completion ends the stream.
nonisolated struct OpenAILiveAdapter: LiveTranscriptionAdapter {
    private var resampler = LiveResampler16kTo24k()
    private var itemTexts: [String: String] = [:]
    private var completedItems: Set<String> = []
    private var committedItem: String?
    private var finishRequested = false

    var provider: LiveTranscriptionProviderID { .openAI }

    func connectionRequest(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> URLRequest {
        // EVIDENCE: Protocols §6.1 marks `intent=transcription` unverified; the plan keeps it until a
        // manual test shows the connection works without it.
        var request = try LiveHTTPStatus.request("wss://api.openai.com/v1/realtime?intent=transcription", headers: [:])
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // JUDGMENT: the configuration goes out first and audio follows at once instead of waiting for
    // `session.updated`. Messages on one socket are applied in order, and a rejected configuration
    // arrives as an `error` event, which fails the session, so no audio is transcribed unconfigured.
    func openingMessages(apiKey: String, configuration: LiveTranscriptionConfiguration) throws -> [LiveTransportMessage] {
        var transcription: [String: Any] = ["model": configuration.modelID]
        let languages = configuration.languageCode.map { [$0] } ?? configuration.languageHints
        if !languages.isEmpty { transcription["languages"] = languages }
        let input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24_000],
            "noise_reduction": ["type": "near_field"],
            "transcription": transcription,
            // gpt-live-transcribe needs turn detection off; the finish commit ends the one item.
            "turn_detection": NSNull(),
        ]
        return [try LiveJSON.text(["type": "session.update", "session": ["type": "transcription", "audio": ["input": input]]])]
    }

    // JUDGMENT: the session streams 16 kHz PCM16 for every provider and replays it after a drop, so
    // conversion to OpenAI's only accepted rate happens here, per connection, with the resampler's
    // state carried across chunks. A reconnect starts a fresh adapter and so a fresh resampler.
    mutating func audioMessage(_ pcm16: Data) -> LiveTransportMessage {
        let resampled = LivePCM16.encode(self.resampler.process(LivePCM16.decode(pcm16)))
        return .text(#"{"audio":""# + resampled.base64EncodedString() + #"","type":"input_audio_buffer.append"}"#)
    }

    mutating func finishMessages() -> [LiveTransportMessage] {
        self.finishRequested = true
        return [.text(#"{"type":"input_audio_buffer.commit"}"#)]
    }

    mutating func parse(_ message: LiveTransportMessage) -> [LiveTranscriptUpdate] {
        guard let object = LiveJSON.object(message) else { return [] }
        let item = object["item_id"] as? String ?? ""
        switch object["type"] as? String {
        case "conversation.item.input_audio_transcription.delta":
            let text = (self.itemTexts[item] ?? "") + (object["delta"] as? String ?? "")
            self.itemTexts[item] = text
            return [.segment(.init(id: item, text: text, isFinal: false, audioEndMilliseconds: nil))]
        case "conversation.item.input_audio_transcription.completed":
            let text = object["transcript"] as? String ?? self.itemTexts[item] ?? ""
            self.itemTexts[item] = text
            self.completedItems.insert(item)
            // No timings: a reconnect replays this connection whole, which the assembler handles.
            let segment = LiveTranscriptUpdate.segment(.init(id: item, text: text, isFinal: true, audioEndMilliseconds: nil))
            return [segment] + (self.committedItem == item ? [.finished] : [])
        case "conversation.item.input_audio_transcription.failed":
            return [.failure(.sessionClosed(Self.errorCode(object) ?? "transcription_failed"))]
        case "input_audio_buffer.committed":
            // Turn detection is off, so the only commit is the finish commit.
            guard self.finishRequested else { return [] }
            self.committedItem = item
            return self.completedItems.contains(item) ? [.finished] : []
        case "error":
            let code = Self.errorCode(object)
            // EVIDENCE: Protocols §6.6, a commit on an empty buffer is an error that means nothing to transcribe.
            if code == "input_audio_buffer_commit_empty" { return [.finished] }
            // JUDGMENT: most errors leave the socket open (Protocols §6.7), but a refused append or
            // configuration means text may be missing, and partial text is never inserted.
            return [.failure(Self.failure(code: code))]
        default:
            return []
        }
    }

    func keyCheckRequest(apiKey: String) throws -> URLRequest {
        try LiveHTTPStatus.request("https://api.openai.com/v1/models", headers: ["Authorization": "Bearer \(apiKey)"])
    }

    private static func errorCode(_ object: [String: Any]) -> String? {
        (object["error"] as? [String: Any])?["code"] as? String
    }

    private static func failure(code: String?) -> LiveTranscriptionError {
        switch code {
        case "invalid_api_key": .authentication
        case "insufficient_quota": .quotaExhausted
        case "rate_limit_exceeded": .rateLimited
        default: .sessionClosed(code ?? "error")
        }
    }
}
