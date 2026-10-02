# OpenRouter audio dictation with styles

## Contract

The optional Transcribe + style dictation mode sends the complete recording and the resolved Cleanup Style to an audio-capable OpenRouter chat model in one inference request. It returns a generated transcript and styled text in a structured response. The transcript is produced by the same model, not by an independent recognizer.

The selected voice model, language, credentials and mode are captured for the recording. The style, app rule, shortcut override and delivery context are resolved before upload. A recording whose style resolves to Off does not reach the audio chat model: it goes to the speech model on the transcription endpoint, which returns a recognizer's transcript and has no length cap. This hybrid routing replaced the earlier rule that Off asked the chat model for a plain transcript (decision of 2 October 2026: no transcription model on OpenRouter follows a free-form style instruction, so styles keep the chat model and plain dictation does not need it). Prompt tests use this same request and do not send a second request for cleanup.

Combined results carry explicit processing metadata. The delivery pipeline uses the generated transcript for spoken-send detection and history, and the final text for insertion. It never calls the separate cleanup provider for a combined result. Failed or cancelled requests cannot trigger automatic inference fallback or late insertion. Explicit retry retains the original instructions.

Combined dictation is limited to 8 minutes. The app rejects a longer recording before an inference request instead of separately styling chunks. Files and completed meetings continue to use the dedicated transcription configuration and timestamps.

## Decisions and sources

- Audio plus instructions uses `/api/v1/chat/completions` with `input_audio`: https://openrouter.ai/docs/guides/overview/multimodal/audio.
- Compatible models use JSON Schema output: https://openrouter.ai/docs/guides/features/structured-outputs.
- Existing multipart transcription accepts but ignores the standard prompt field: https://openrouter.ai/docs/guides/overview/multimodal/stt.
- Existing preferences retain transcription-only mode. The user selects combined mode and its audio model explicitly.
- Style selection and prompt testing in combined mode require the voice engine credentials, not a second verified AI provider.

## Implementation and acceptance

1. Backend: add settings, model capability validation, audio request construction and structured output; first add failing request tests, then implement and run the cloud harness.
2. Routing: freeze recording configuration, prepare instructions after capture stops and before upload, preserve raw/final output, and bypass separate cleanup. Verify Off, app rules, shortcut overrides, prompt tests and failure/cancellation.
3. UI: expose mode and model, explain styles, update prompt editor availability and document limits.
4. Review: inspect spec compliance and code quality, resolve findings, run standalone regressions and Xcode integration checks.
5. Delivery: commit the isolated worktree, merge into personal, and build the signed personal application. Verify the final product identity and signing.
