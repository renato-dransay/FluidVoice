# OpenRouter transcription

The personal app starts with local speech recognition and AI enhancement off. In **AI Settings > Voice Engine**, select **OpenRouter**, save a key, and validate it. The key is stored in the personal app's macOS Keychain service. The transcription provider and optional text enhancement provider are independent.

Key validation checks authentication and the transcription catalog. It cannot guarantee that your account permits a provider serving every listed model. For example, an account allowing only OpenAI, Anthropic, and Google cannot currently use the Whisper models served by Groq or DeepInfra. Review your own [OpenRouter provider permissions](https://openrouter.ai/settings/privacy) when the app reports that no provider is available. The app never changes these account restrictions, pins an underlying host, or silently switches providers.

## Dictation and files

Dictation uploads audio after recording stops; it does not send cloud preview requests. The default model is `openai/whisper-large-v3-turbo`. GPT-4o Transcribe and GPT-4o Mini Transcribe are available for plain-text output. Automatic language detection omits the language hint; a manual selection supplies a two-letter hint. Each operation keeps the provider, model, language, and credentials captured when it starts.

Imported audio and video use the same model setting as dictation. Audio is converted to mono 16 kHz WAV and uploaded in chunks of at most 120 seconds. Requests requiring word timestamps use a one-second overlap and timestamp ownership to avoid duplicate words. Plain-text requests use non-overlapping chunks. Full decoded audio is currently held in memory, so very long imports can use substantial RAM even though each upload is bounded.

Completed file chunks are saved locally using an audio fingerprint and the complete transcription configuration. Retrying the same file and settings reuses completed chunks. Changing the model or language starts a distinct transcription. The cache contains transcript text and follows the personal app's local data backups. Short dictation does not persist this chunk cache.

On a dictation failure, Voice Engine offers explicit **Retry and copy**, **Transcribe locally and copy**, and **Discard recording** actions. Retry uses the original model and language with the current saved key. The failed recording stays in memory until retried, discarded, replaced by another failed recording, or the app exits. Local retry may need the selected local model to be downloaded. It never activates automatically. Cancellation stops requests and prevents delayed text insertion.

## Completed meetings

Meeting settings have a separate OpenRouter model selection, defaulting to `openai/whisper-large-v3`. Only the two supported Whisper models are selectable because the meeting pipeline needs validated word timestamps. Local Nemotron still identifies speakers. Track separation, echo handling, speaker matching, and transcript assembly use the existing shared meeting pipeline.

Automatic and supported manual language selection apply to the completed cloud transcript. Live captions remain local and retain the selected local model's language limits. Missing or invalid word timestamps produce an incomplete result with an actionable error; the app never invents timestamps. Retrying a meeting can reuse successful recognition chunks with the same audio and frozen configuration.

Optional speaker labels for imported audio use local diarization aligned against one timed cloud transcript. Words with no confident speaker remain unassigned. Speaker labels for imported video are not supported in this release; disable that option to transcribe video as plain text.

## Text fidelity, costs, and privacy

Cloud recognition preserves the returned raw transcript. Dictation history stores optional enhanced text separately; enhancement remains off until explicitly configured. Recognition itself can still normalize numbers or punctuation. A literal transcript is not guaranteed by any model.

Voice Engine shows recorded request costs and processing times. Missing costs appear as **unknown**, and totals identify requests with unavailable costs. These are provider-reported amounts, not a billing guarantee. Cached chunks do not create new usage entries. Request diagnostics include metadata only, never API keys, audio bodies, or transcript content.

Audio leaves the Mac only when a cloud operation is selected. OpenRouter routes it according to account eligibility and available providers. Its transcription endpoint does not currently honor per-request provider-pinning controls. Raw transcripts, resumable chunks, usage metadata, and recordings stay under the personal app's isolated local storage. See [maintenance and rollback](maintenance.md) for backup locations.

The public source build excludes the private Fluid Intelligence runtime. Existing optional external enhancement remains available. Direct OpenAI/Groq clients, custom speech endpoints, cloud live captions, iPhone support, and public binary distribution are outside this release.
