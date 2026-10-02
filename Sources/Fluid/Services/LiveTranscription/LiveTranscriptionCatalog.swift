import Foundation

nonisolated enum LiveTranscriptionCatalog {
    // EVIDENCE for every entry: docs/superpowers/plans/2026-09-30-live-cloud-provider-protocols.md,
    // read against each vendor's documentation on 2026-09-30. Model lists re-read on 2026-10-02; each
    // entry names what it checked, and models left out are named with the reason.
    static let all: [LiveTranscriptionProviderInfo] = [
        LiveTranscriptionProviderInfo(
            id: .soniox,
            name: "Soniox",
            // stt-rt-v5 released 2026-06-16; stt-rt-v4 became an alias of it.
            // EVIDENCE: https://soniox.com/docs/stt/models (checked 2026-10-02): stt-rt-v5 is the only active real-time
            // model; the v4 and v3 IDs are aliases or retired.
            models: [.init(id: "stt-rt-v5", name: "Soniox v5 Realtime")],
            detectsLanguageAutomatically: true,
            languageCodes: nil,
            keyURL: URL(string: "https://console.soniox.com"),
            usageURL: URL(string: "https://console.soniox.com")
        ),
        LiveTranscriptionProviderInfo(
            id: .deepgram,
            name: "Deepgram",
            // EVIDENCE: https://developers.deepgram.com/docs/models-languages-overview and
            // https://developers.deepgram.com/docs/model (checked 2026-10-02): Nova-3 and Nova-2 stream on the same
            // endpoint; Nova-3 Medical takes the same request for English only. Left out: Flux (another endpoint
            // and protocol, `/v2/listen`), Nova-3 Pharma and the Nova-2 domain variants (niche, English only), and
            // the legacy models. `DeepgramLiveAdapter.language(for:)` sends each its language.
            models: [
                .init(id: "nova-3", name: "Nova-3"),
                // EVIDENCE: https://developers.deepgram.com/docs/models-languages-overview (checked 2026-10-02): Nova-2
                // streams these 33 languages, so its warnings use this list rather than Nova-3's `multi` set.
                .init(id: "nova-2", name: "Nova-2", note: "Older · Uses your Primary language", languageCodes: DeepgramLiveAdapter.olderModelLanguageCodes),
                .init(id: "nova-3-medical", name: "Nova-3 Medical", note: "English only · Medical terms", languageCodes: ["en"]),
            ],
            detectsLanguageAutomatically: true,
            // Nova-3 streaming code-switching covers these with language=multi.
            languageCodes: ["en", "es", "fr", "de", "hi", "ru", "pt", "ja", "it", "nl"],
            keyURL: URL(string: "https://console.deepgram.com"),
            usageURL: URL(string: "https://console.deepgram.com")
        ),
        LiveTranscriptionProviderInfo(
            id: .assemblyAI,
            name: "AssemblyAI",
            // EVIDENCE: https://www.assemblyai.com/docs/streaming/select-the-speech-model (checked 2026-10-02); the
            // request differences are in `AssemblyAILiveAdapter`. Left out: the deprecated `u3-*` and
            // `universal-3-pro` streaming IDs.
            models: [
                .init(id: "universal-3-6-pro", name: "Universal-3.6 Pro"),
                .init(id: "universal-3-5-pro", name: "Universal-3.5 Pro", note: "Previous version", languageCodes: AssemblyAILiveAdapter.previousProSteerableLanguageCodes),
                .init(
                    id: "universal-streaming-multilingual",
                    name: "Universal-Streaming Multilingual",
                    note: "English, Spanish, German, French, Portuguese, Italian",
                    languageCodes: AssemblyAILiveAdapter.multilingualLanguageCodes
                ),
                .init(id: AssemblyAILiveAdapter.englishModelID, name: "Universal-Streaming English", note: "English only", languageCodes: ["en"]),
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
            // EVIDENCE: https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime (checked
            // 2026-10-02): `scribe_v2_realtime` is the only realtime `model_id`.
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
            // EVIDENCE: https://docs.mistral.ai/studio/audio/speech_to_text/realtime_transcription (checked 2026-10-02):
            // the only realtime model the guide uses. The model card's `voxtral-mini-realtime-latest` alias is left
            // out until the realtime endpoint is confirmed to take it.
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
            // EVIDENCE: https://developers.openai.com/api/docs/guides/realtime-transcription and
            // https://developers.openai.com/api/docs/deprecations (checked 2026-10-02): gpt-live-transcribe is
            // recommended and gpt-realtime-whisper stays supported. Left out: gpt-transcribe, which transcribes only
            // after a commit, so one commit at the end of a long dictation outlasts the finish deadline; and
            // gpt-4o-transcribe, gpt-4o-mini-transcribe and whisper-1, deprecated on 2026-08-26.
            models: [
                .init(id: "gpt-live-transcribe", name: "GPT Live Transcribe"),
                .init(id: "gpt-realtime-whisper", name: "GPT Realtime Whisper", note: "Takes one language"),
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
            // EVIDENCE: https://docs.speechmatics.com/speech-to-text/models (checked 2026-10-02): realtime takes
            // `enhanced` and `standard`. Melia 1 realtime is a preview on another endpoint and is left out.
            models: [
                .init(id: "enhanced", name: "Enhanced"),
                .init(id: "standard", name: "Standard", note: "Faster, less accurate"),
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
            // EVIDENCE: https://docs.gladia.io/api-reference/v2/live/init (checked 2026-10-02): `solaria-1` is the only
            // streaming model; Solaria-3 is pre-recorded only.
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
