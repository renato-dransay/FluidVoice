# Live cloud transcription

**Live cloud** is a third voice engine, next to **Local** and **OpenRouter**. It streams your dictation audio to a speech provider of your choice while you speak, using your own API key for that provider. Words appear in the overlay as you talk, the same way they do with a local model, and the final text arrives a few hundred milliseconds after you press the stop key.

OpenRouter works differently: it has no streaming speech endpoint, so the app uploads the whole recording after you stop and waits for one response that carries both the transcript and the styled text. Live cloud returns only the transcript. The transcript then goes through the same steps as local output: filler removal, the Custom Dictionary, spoken punctuation, and finally your Cleanup Styles through the text provider and model chosen in **AI Settings > AI Providers**. Styles have no provider or model of their own.

## Providers

| Provider | Default model | Other models | Language behaviour | Streaming price | Billed on |
|---|---|---|---|---|---|
| Soniox | `stt-rt-v5` | none | Detects automatically and switches languages within a recording. Primary and Secondary are sent as hints; a language picked in the overlay is enforced strictly. | $0.12/h | Connection time |
| Deepgram | `nova-3` | none | Uses `language=multi` (automatic, with code-switching) unless a language is picked in the overlay. Hints are not sent. Lists en, es, fr, de, hi, ru, pt, ja, it and nl; other languages are disabled in the overlay. | $0.0048/min, $0.0058/min with `multi` | Audio, per second |
| AssemblyAI | `universal-3-6-pro` | `universal-streaming-multilingual` | Detects automatically when no language is picked. With Universal-3.6 Pro the picked language, or Primary and Secondary, are sent as its language list, but only when every one of them is among the 32 languages it accepts; otherwise none is sent. Other languages are disabled in the overlay. Universal-Streaming Multilingual takes no language and detects one per turn. | Universal-3.6 Pro $0.45/h, Universal-Streaming $0.15/h | Connection time |
| ElevenLabs | `scribe_v2_realtime` | none | Detects automatically. Only a language picked in the overlay is sent; hints are not. | $0.39/h | Audio duration |
| Mistral | `voxtral-mini-transcribe-realtime-2602` | none | Detects the language on its own and ignores every language choice: neither hints nor an overlay pick are sent, and picking a language during a recording does not reconnect. | $0.006/min | Audio |
| OpenAI | `gpt-live-transcribe` | `gpt-realtime-whisper` | With `gpt-live-transcribe` the picked language, or Primary and Secondary, are sent as hints; it transcribes without them too. `gpt-realtime-whisper` takes a single language, so only a language picked in the overlay is sent. | $0.017/min | Audio duration |
| Speechmatics | `enhanced` | `standard` | Needs one fixed language per session and cannot detect automatically. It uses the language picked in the overlay, otherwise your Primary language. Without a Primary language it cannot be activated or tested. | Standard $0.24/h, Enhanced $0.43/h | Per second |
| Gladia | `solaria-1` | none | Detects automatically. With Primary and Secondary set it switches between them within a recording; a picked language is enforced for the whole session. | About $0.75/h | Not published |

Prices and billing bases were read from each vendor's documentation on 2026-09-30 and change without notice; check the provider's own pricing page before relying on them. Providers that bill connection time (Soniox and AssemblyAI) charge for the whole time the connection is open, so the app closes the connection on every exit: the final text, cancelling with Escape, a recording discarded as silence, and every failure.

## Adding, testing and activating a provider

1. Open **AI Settings > Voice Engine** and choose the **Live cloud** tab. Browsing the tab never changes the voice engine.
2. Choose **Add provider** and pick a provider from the grid. Adding a provider does not change your current dictation setup; its Manage sheet opens straight away.
3. In the Manage sheet, paste the key into the API key field and choose **Save key**. The sheet shows **Key saved in macOS Keychain**, a **Get a <Provider> API key** link, and **Remove key**. Nothing is sent to the provider before a key is saved.
4. Optionally pick another model. The choice applies from your next recording.
5. To try the provider without switching to it, choose **Test with your dictation shortcut**, then press your normal dictation shortcut, speak for a few seconds and stop. The next dictation uses this provider even if another engine is active, shows live words in the overlay, and the sheet shows the **Transcript** and **Final text <n> s after you stopped**. Nothing is typed, saved to history, or sent to Cleanup Styles, and the test does not change the voice engine. A test still uses a few seconds of the provider's paid usage. Closing the sheet, or **Stop testing**, disarms the test. A passing test marks the provider **Tested** in the list until its key is replaced or removed.
6. Choose **Activate** on the provider's row, or **Activate for dictation** in the sheet. The app first checks the key with one authenticated request to the provider's REST API, without audio. If the check passes, the voice engine switches to Live cloud with that provider and the row shows a green **Active** badge. If it fails, the engine does not change and the row names the reason, for example a rejected key.

Each row shows the model and a status: **Not tested**, **Tested**, **API key missing**, **Key rejected**, or **Needs a Primary language** for Speechmatics without one. Only one provider can be active. To leave Live cloud, activate a local model in the **Local** tab or turn on OpenRouter; either clears the active live provider. **Remove provider** in the Manage sheet deletes its key and model choice and, if it was active, returns dictation to the selected local model. Removing only the key leaves Live cloud selected but unusable, and dictation uses the selected local model until a key is saved again; settings then show that the provider's key is required.

## What uses Live cloud

With Live cloud active, these recordings stream to the active provider:

- Dictation.
- Command mode.
- Rewrite mode.

These always stay on the selected local model, even with Live cloud active and even if an OpenRouter key is saved:

- Imported audio and video files.
- The local HTTP API.
- Meetings, including live captions.
- Dictionary training captures, which compare against the local model's pronunciation.

The selected local model must therefore still be downloaded for those features. The Local tab's header reads **Selected local model** while another engine is active, for this reason.

## Languages and the overlay

Live cloud shares the **Dictation language** settings with OpenRouter: an optional **Primary language** and **Secondary language**. By default dictation detects the language automatically, and the two preferences are hints where the provider accepts them (see the table). Once a Primary language is set, the overlay shows the globe language chip, offering Primary, Secondary and **Detect automatically**. Picking a language during a recording reconnects to the same provider with the new language and replays the audio recorded after the last finished segment, so the rest of the recording uses the new language. Languages the active provider does not list are disabled in the chip, and **Detect automatically** is disabled for Speechmatics. The Manage sheet warns when your Primary or Secondary language is not listed by that provider.

Mistral ignores every language choice: its realtime API takes no language, so the app sends none, and a pick in the overlay does not reconnect. Speechmatics is the opposite: it requires a set language, so a Primary language must be configured before it can be activated or tested.

The overlay style menu names the engine as `<PROVIDER> · LIVE` while audio streams to a provider; it never says `ON-DEVICE` then. Live words appear in the preview area only when **Live Preview** is on in the overlay settings.

## Failures and recovery

Partial text is never inserted, and the app never switches to another engine on its own.

- **Dropped connection during a recording.** The app reconnects once to the same provider and replays the audio after the last segment the provider had finalized. There is no separate overlay message; the preview falls back to the finalized text and continues. A rejected key, exhausted quota or unsupported language is not retried, because a new connection would fail the same way.
- **Five-second finish deadline.** After the stop key, the app sends the remaining audio and the provider's finish messages and waits for the final text. The five seconds start at the stop, so a stalled connection cannot hold the stop longer.
- **When a dictation fails** (the reconnect fails, the deadline passes, the key is rejected, the provider ends the session), nothing is inserted. An alert titled **<Provider> transcription failed** names the provider and the reason, and the recording is kept. The **Live cloud** tab then offers **Retry and copy**, which streams the saved recording to the same provider through a new connection, **Transcribe locally and copy**, which uses the selected local model, and **Discard recording**. Retried text is copied to the clipboard, not typed. The recording stays in memory until it is retried, discarded, replaced by another failed recording, or the app quits.
- **Provider tests** keep no recording and show no alert; the Manage sheet shows the reason instead.
- **Cancelling** a recording closes the connection and inserts nothing.

## Privacy

- Audio leaves the Mac only while Live cloud is active (or a provider test is armed), and only to the active provider. It streams during the recording, not after it. The key check at activation sends no audio.
- No network contact with a provider happens until you save its key.
- Only audio and the session settings (model, and language where the provider takes it) are sent. App or window context, preceding text and Custom Dictionary terms are not sent to live providers.
- Deepgram requests carry `mip_opt_out=true`, which opts them out of Deepgram's Model Improvement Program.
- Keys are stored in the personal app's macOS Keychain item under `live-transcription.<provider>`, for example `live-transcription.soniox`. They are separate from AI Providers keys and from the OpenRouter voice engine key, and saving AI Providers keys never erases them.
- The debug log records only metadata: the provider id, the model id, an error kind or provider error code, durations such as `LIVE_FINAL ... stopToFinalMs=<n> streamedMs=<n>`, and HTTP or WebSocket close codes. It never records audio, transcript or partial text, API keys, provider error bodies, or WebSocket close reasons.
- Transcripts from live dictation are stored in local history like any other dictation, attributed to provider `live-<provider>` with its model id.

## Usage

Each provider's Manage sheet shows **Streamed on this Mac: <n> min across <n> recordings**. A recording is counted when it returns its final text, including provider tests; the count is the audio streamed to the provider, plus any short silence the app appends so the provider finalizes the last words. Failed recordings and retries of saved recordings are not counted. None of the providers reports cost during a stream, so the app shows no cost and no estimate; the sheet links to the provider's own usage and billing page, which is the reference for what you are charged.
