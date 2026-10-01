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
            // The languages Universal-3.6 Pro can be steered toward; Universal-Streaming Multilingual takes no
            // language and detects one per turn.
            languageCodes: AssemblyAILiveAdapter.steerableLanguageCodes,
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
            // EVIDENCE: https://docs.mistral.ai/admin/identity-access/api-keys and
            // https://docs.mistral.ai/admin/billing-usage/usage-limits (checked 2026-10-01): own keys live in
            // Studio's profile dialog, usage in the Admin Panel.
            keyURL: URL(string: "https://console.mistral.ai/home?profile_dialog=api-keys"),
            usageURL: URL(string: "https://admin.mistral.ai/organization/usage"),
            sendsLanguageChoice: false
        ),
        LiveTranscriptionProviderInfo(
            id: .openAI,
            name: "OpenAI",
            models: [
                .init(id: "gpt-live-transcribe", name: "GPT Live Transcribe"),
                .init(id: "gpt-realtime-whisper", name: "GPT Realtime Whisper"),
            ],
            // Takes `languages` as hints; transcribes without them too.
            detectsLanguageAutomatically: true,
            languageCodes: nil,
            keyURL: URL(string: "https://platform.openai.com/api-keys"),
            usageURL: URL(string: "https://platform.openai.com/usage")
        ),
        LiveTranscriptionProviderInfo(
            id: .speechmatics,
            name: "Speechmatics",
            models: [
                .init(id: "enhanced", name: "Enhanced"),
                .init(id: "standard", name: "Standard"),
            ],
            // Realtime needs one fixed language per session; `auto` is batch only.
            detectsLanguageAutomatically: false,
            // JUDGMENT: the protocols research verified only en and pt; an unlisted language comes back as
            // `invalid_language`, which names itself, so the picker is not narrowed on a guess.
            languageCodes: nil,
            // EVIDENCE: https://docs.speechmatics.com/get-started/authentication (checked 2026-10-01) links keys here.
            keyURL: URL(string: "https://portal.speechmatics.com/settings/api-keys"),
            usageURL: URL(string: "https://portal.speechmatics.com")
        ),
        LiveTranscriptionProviderInfo(
            id: .gladia,
            name: "Gladia",
            models: [.init(id: "solaria-1", name: "Solaria-1")],
            // 100+ languages with automatic detection and code-switching.
            detectsLanguageAutomatically: true,
            languageCodes: nil,
            // EVIDENCE: https://docs.gladia.io/llms-full.txt (checked 2026-10-01) links keys at app.gladia.io/apikeys.
            keyURL: URL(string: "https://app.gladia.io/apikeys"),
            usageURL: URL(string: "https://app.gladia.io")
        ),
    ]

    static func info(for id: LiveTranscriptionProviderID) -> LiveTranscriptionProviderInfo {
        // Every enum case has an entry; the catalog test guards it.
        self.all.first { $0.id == id } ?? self.all[0]
    }
}
