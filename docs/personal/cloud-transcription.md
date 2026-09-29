# OpenRouter transcription

The personal app starts with local speech recognition and AI enhancement off. In **AI Settings > Voice Engine**, select **OpenRouter**, save a key, choose the dictation mode, and validate it. The key is stored in the personal app's macOS Keychain service. Existing settings retain **Transcription only** until you explicitly select **Transcribe + style**.

Key validation checks authentication and supported models for the selected dictation mode. Audio dictation models must support audio input, text output, and structured output. Validation cannot guarantee that your account permits a provider serving every listed model. For example, an account allowing only OpenAI, Anthropic, and Google cannot currently use the Whisper models served by Groq or DeepInfra. Review your own [OpenRouter provider permissions](https://openrouter.ai/settings/privacy) when the app reports that no provider is available. The app never changes these account restrictions, pins an underlying host, or silently switches providers.

## Dictation

Dictation uploads audio after recording stops; it does not send cloud preview requests. Each operation keeps its model, language, instructions, and credentials together so changing settings does not alter an in-progress request.

### Transcribe + style

Select **Transcribe + style**, choose an audio-capable **Dictation voice model**, then choose the instructions in **Cleanup Styles**. The default voice model is `google/gemini-2.5-flash`; Gemini 2.5 Flash Lite and Gemini 2.5 Pro are also supported. These models use OpenRouter's chat endpoint with audio input, rather than its transcription endpoint.

Audio and the resolved style are sent in one request. The response contains both a transcript and styled text; the app inserts the styled text and stores both separately in history. The same model generates both fields, so the transcript is not an independent speech recognizer's reference or a guarantee of literal wording. Cleanup Styles **Off** requests transcription without styling. App-specific rules, routing scope, and shortcut styles still determine the instructions sent.

The model and API key come from **Voice Engine**. Per-style text provider and model assignments are ignored for combined dictation and retained for use when switching back. A previously selected Fluid Intelligence style uses the default cleanup instructions in this mode; its saved local preference is retained. No separate verified text AI provider is required to select, edit, or test a style. The Prompt Test editor sends its unsaved instructions with audio using the same one-request path and displays both returned fields without inserting text. Separate **AI Providers** remain available for text editing and other text AI actions.

Combined dictation is limited to **120 seconds per recording**. A longer recording, unsupported model, malformed response, or provider failure reports an error; the app does not split the recording or automatically launch an extra cleanup, transcription, or local fallback request. Explicit retry starts another request. **Off** still uses the selected audio model and one request.

### Transcription only

The transcription provider and optional text enhancement provider are independent in this mode. The default model is `openai/whisper-large-v3-turbo`. GPT-4o Transcribe and GPT-4o Mini Transcribe are available for plain-text output. Automatic language detection omits the language hint; a manual selection supplies a two-letter hint. Cleanup Styles can apply a second text AI request after transcription; **Off** skips that request.

On a dictation failure, Voice Engine offers explicit **Retry and copy**, **Transcribe locally and copy**, and **Discard recording** actions. Retry uses the captured dictation settings with the current saved key. The failed recording stays in memory until retried, discarded, replaced by another failed recording, or the app exits. Local retry may need the selected local model to be downloaded. It never activates automatically. Cancellation stops requests and prevents delayed text insertion.

## Imported files

Imported audio and video use the **File transcription model** setting in combined mode, or **Dictation and file model** in transcription-only mode. File transcription remains a speech recognition operation and does not send Cleanup Styles. Audio is converted to mono 16 kHz WAV and uploaded in chunks of at most 120 seconds. Requests requiring word timestamps use a one-second overlap and timestamp ownership to avoid duplicate words. Plain-text requests use non-overlapping chunks. Full decoded audio is currently held in memory, so very long imports can use substantial RAM even though each upload is bounded.

Completed file chunks are saved locally using an audio fingerprint and the complete transcription configuration. Retrying the same file and settings reuses completed chunks. Changing the model or language starts a distinct transcription. The cache contains transcript text and follows the personal app's local data backups. Short dictation does not persist this chunk cache.

## Completed meetings

Meeting settings have a separate OpenRouter model selection, defaulting to `openai/whisper-large-v3`. Only the two supported Whisper models are selectable because the meeting pipeline needs validated word timestamps. Local Nemotron still identifies speakers. Track separation, echo handling, speaker matching, and transcript assembly use the existing shared meeting pipeline.

Automatic and supported manual language selection apply to the completed cloud transcript. Live captions remain local and retain the selected local model's language limits. Missing or invalid word timestamps produce an incomplete result with an actionable error; the app never invents timestamps. Retrying a meeting can reuse successful recognition chunks with the same audio and frozen configuration.

Optional speaker labels for imported audio use local diarization aligned against one timed cloud transcript. Words with no confident speaker remain unassigned. Speaker labels for imported video are not supported in this release; disable that option to transcribe video as plain text.

## Text fidelity, costs, and privacy

Cloud recognition preserves the returned transcript. Dictation history stores optional styled text separately; styling remains off until explicitly configured. In combined mode both fields come from the same generative model response. Recognition itself can still normalize numbers or punctuation. A literal transcript is not guaranteed by any model.

Voice Engine shows recorded request costs and processing times, including combined dictation. Combined requests can charge for audio input and text output; a single request does not guarantee a lower price than transcription plus cleanup. Missing costs appear as **unknown**, and totals identify requests with unavailable costs. These are provider-reported amounts, not a billing guarantee. Cached chunks do not create new usage entries. Request diagnostics include metadata only, never API keys, audio bodies, or transcript content.

Audio leaves the Mac only when a cloud operation is selected. Combined dictation also sends your selected instructions and any context included in them. OpenRouter routes requests according to account eligibility and available providers. Its transcription endpoint does not currently honor per-request provider-pinning controls. Transcripts, styled text, resumable chunks, usage metadata, and recordings stay under the personal app's isolated local storage. See [maintenance and rollback](maintenance.md) for backup locations.

The public source build excludes the private Fluid Intelligence runtime. Existing optional external enhancement remains available. Direct OpenAI/Groq clients, custom speech endpoints, cloud live captions, iPhone support, and public binary distribution are outside this release.
