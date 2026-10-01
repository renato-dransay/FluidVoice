import Foundation

nonisolated enum LiveTranscriptionCatalog {
    // EVIDENCE for every entry: docs/superpowers/plans/2026-09-30-live-cloud-provider-protocols.md,
    // read against each vendor's documentation on 2026-09-30.
    static let all: [LiveTranscriptionProviderInfo] = [
        LiveTranscriptionProviderInfo(
            id: .soniox,
            name: "Soniox",
            // stt-rt-v5 released 2026-06-16; stt-rt-v4 became an alias of it.
            models: [.init(id: "stt-rt-v5", name: "Soniox v5 Realtime")],
            detectsLanguageAutomatically: true,
            languageCodes: nil,
            keyURL: URL(string: "https://console.soniox.com"),
            usageURL: URL(string: "https://console.soniox.com")
        ),
        LiveTranscriptionProviderInfo(
            id: .deepgram,
            name: "Deepgram",
            models: [.init(id: "nova-3", name: "Nova-3")],
            detectsLanguageAutomatically: true,
            // Nova-3 streaming code-switching covers these with language=multi.
            languageCodes: ["en", "es", "fr", "de", "hi", "ru", "pt", "ja", "it", "nl"],
            keyURL: URL(string: "https://console.deepgram.com"),
            usageURL: URL(string: "https://console.deepgram.com")
        ),
        LiveTranscriptionProviderInfo(
            id: .assemblyAI,
            name: "AssemblyAI",
            models: [
                .init(id: "universal-3-6-pro", name: "Universal-3.6 Pro"),
                .init(id: "universal-streaming-multilingual", name: "Universal-Streaming Multilingual"),
            ],
            detectsLanguageAutomatically: true,
            languageCodes: nil,
            keyURL: URL(string: "https://www.assemblyai.com/dashboard"),
            usageURL: URL(string: "https://www.assemblyai.com/dashboard")
        ),
        LiveTranscriptionProviderInfo(
            id: .elevenLabs,
            name: "ElevenLabs",
            models: [.init(id: "scribe_v2_realtime", name: "Scribe v2 Realtime")],
            // 90+ languages; omitting language_code detects automatically.
            detectsLanguageAutomatically: true,
            languageCodes: nil,
            keyURL: URL(string: "https://elevenlabs.io/app/settings/api-keys"),
            usageURL: URL(string: "https://elevenlabs.io/app/usage")
        ),
        LiveTranscriptionProviderInfo(
            id: .mistral,
            name: "Mistral",
            models: [.init(id: "voxtral-mini-transcribe-realtime-2602", name: "Voxtral Mini Transcribe Realtime")],
            // Detects the language on its own; the realtime session takes no language or hints.
            detectsLanguageAutomatically: true,
            languageCodes: ["en", "zh", "hi", "es", "ar", "fr", "pt", "ru", "de", "ja", "ko", "it", "nl"],
            keyURL: URL(string: "https://console.mistral.ai/api-keys"),
            usageURL: URL(string: "https://console.mistral.ai/usage"),
            sendsLanguageChoice: false
        ),
    ]

    static func info(for id: LiveTranscriptionProviderID) -> LiveTranscriptionProviderInfo {
        // Every enum case has an entry; the catalog test guards it.
        self.all.first { $0.id == id } ?? self.all[0]
    }
}
