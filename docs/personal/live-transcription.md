# Live cloud transcription

**Live cloud** is a third voice engine, next to **Local** and **Cloud**. It streams your dictation audio to a speech provider of your choice while you speak, using your own API key for that provider. Words appear in the overlay as you talk, the same way they do with a local model, and the final text arrives a few hundred milliseconds after you press the stop key.

**Cloud** works differently: the app uploads the whole recording after you stop and waits for the provider's answer (see [Cloud transcription](cloud-transcription.md)); with OpenRouter one response carries both the transcript and the styled text. Live cloud returns only the transcript. The transcript then goes through the same steps as local output: filler removal, the Custom Dictionary, spoken punctuation, and finally your Cleanup Styles through the default text provider and model chosen in **AI Providers**. Styles have no provider or model of their own.

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

## Connecting, testing and activating a provider

Keys are entered in **AI Providers**, the one place where every provider is connected; Voice Engine never asks for a key.

1. Open **Voice Engine** and choose the **Live cloud** tab. Browsing the tab never changes the voice engine. The tab lists the connected live providers first. Every other one is under **Not set up**, shown when nothing is connected and otherwise behind **Show <n> more providers**, with **Set up in AI Providers**.
2. **Set up in AI Providers** opens that provider's connection form in AI Providers (or choose **Add provider** there and pick it from the grid). Paste the key and choose **Add provider**. Adding a provider does not change your current dictation setup, and nothing is sent to the provider when the key is saved. The confirmation offers **Back to Voice Engine**, which returns to the Live cloud tab.
3. Back in the Live cloud tab, the provider is under the connected providers. **Manage** opens its sheet: a connection line with **Manage in AI Providers**, the model, the test and the usage. The key itself is replaced or removed in AI Providers.
4. Optionally pick another model. The choice applies from your next recording.
5. To try the provider without switching to it, choose **Test with your dictation shortcut**, then press your normal dictation shortcut, speak for a few seconds and stop. The next dictation uses this provider even if another engine is active, shows live words in the overlay, and the sheet shows the **Transcript** and **Final text <n> s after you stopped**. Nothing is typed, saved to history, or sent to Cleanup Styles, and the test does not change the voice engine. A test still uses a few seconds of the provider's paid usage. Closing the sheet, or **Stop testing**, disarms the test. A passing test marks the provider **Tested** in the list until its key is replaced or removed.
6. Choose **Activate** on the provider's row or in the sheet's footer. The app first checks the key with one authenticated request to the provider's REST API, without audio. If the check passes, the voice engine switches to Live cloud with that provider and the button turns into a green **Active**. If it fails, the engine does not change and the row names the reason, for example a rejected key.

Each connected row shows the model, followed by **Tested** once a test passed with the current key. Instead of the model, a row can show **API key missing** or **Needs a Primary language** for Speechmatics without one, and after a failed activation check the model is followed by **Key rejected**. Only one provider can be active. To leave Live cloud, activate a local model in the **Local** tab or a provider in the **Cloud** tab; either clears the active live provider.

A provider is removed in AI Providers, with **Remove key** or **Remove provider** in its Manage sheet; both are disabled while a recording is in progress. When dictation or FluidMeet uses the provider, the app asks first ("Remove <Provider>? Dictation switches to your selected local model.", plus "FluidMeet transcription switches to Local." when it applies). Removing it deletes its key and, if it was active, returns dictation to the selected local model. If the active provider's key goes missing in another way, Live cloud stays selected but dictation uses the selected local model until a key is saved again; the Voice Engine header and the Dashboard then say that the provider's key is required, and the row offers **Set up in AI Providers**.

## What uses Live cloud

With Live cloud active, these recordings stream to the active provider:

- Dictation.
- Command mode.
- Rewrite mode.

These always stay on the selected local model, even with Live cloud active and even if a Cloud provider is connected:

- Imported audio and video files.
- The local HTTP API.
- Meetings, which have their own **Meeting transcription** setting with the same three choices (see [Meetings](#meetings-fluidmeet)).
- Dictionary training captures, which compare against the local model's pronunciation.

The selected local model must therefore still be downloaded for those features. The Local tab's header reads **Selected local model** while another engine is active, for this reason, and File Transcription says that files use the local model.

## Meetings (FluidMeet)

FluidMeet's **Meeting transcription** setting offers the same three choices as the voice engine: **Local**, **Cloud** (OpenRouter, for meetings) and **Live cloud**. It is separate from dictation: Live cloud does not need to be the active voice engine, and activating a provider for dictation does not change meetings.

1. Connect the provider in **AI Providers**, as for dictation. With no live provider connected, FluidMeet's settings offer **Set up a live provider in AI Providers**.
2. In FluidMeet's recording settings, choose **Live cloud** under **Meeting transcription**, then the provider under **Live provider**. The picker lists every live provider with a saved key; choosing Live cloud first selects the dictation's live provider, or else the first connected one. The model is the one chosen in the provider's Manage sheet in Voice Engine, which **Manage live providers in Voice Engine** opens.
3. The choice applies from the next recording.

With Live cloud, the meeting streams to the provider while it records, and the provider makes both the live captions and the completed transcript, so nothing is uploaded or transcribed after you stop. Speaker detection still runs on this Mac with Nemotron, which must be installed, as for the other choices. With Local or Cloud, live captions run on this Mac in English.

During a recording, the microphone streams on one connection and, in an online call, the call audio on a second one. Each connection is billed separately for the whole recording, including silence: a track that delivers no audio streams silence so providers that close idle connections keep it open. The **Transcript language** setting applies, with the dictation Primary and Secondary languages as hints. A language the provider does not list is detected automatically instead; Speechmatics, which cannot detect, uses the Primary language when the transcript language is automatic.

Turns are cut on the Mac: a caption bubble closes after a short pause once the provider's text is final, after a longer pause if the provider still holds provisional text, and at the provider's last final text after 20 seconds of continuous speech. When the recording stops, the provider receives the remaining audio and finishes its last words (up to five seconds), then every turn is saved with the session as `live-cloud-transcript.json`. Processing places each turn on the recording's timeline and labels it with the speaker Nemotron found active during it, so speaker labels follow caption turns rather than individual words. Text from the microphone and the call audio goes through the same echo checks as with the other choices.

The connection is replaced at the first pause after 10 minutes (and after 30 minutes regardless); the old connection finishes its text first, and audio captured meanwhile waits for the new one. When a connection drops, the session reconnects once on its own and replays the audio after the last final text; if that fails, the captions card shows that captions are reconnecting, a new connection opens after a short backoff (1, 2, 5, 10, then every 30 seconds), and audio in between has no text in the transcript either. A rejected key, exhausted credits or an unsupported language stops the stream for the rest of the recording with a message that names the provider; the recording itself continues.

A meeting without a saved Live cloud transcript (recorded with another choice, or interrupted by the app quitting) cannot be processed with Live cloud; choose Local or Cloud and retry, which transcribes the recorded audio. Removing the provider in AI Providers returns meetings that used it to **Local**. If its key goes missing in another way, the next recording streams nothing and says that the key is required; the app does not switch to another choice on its own.

The recording screen's privacy line names the provider whenever audio leaves the Mac. Each recording's streams count towards the provider's **Streamed on this Mac** usage, one recording per stream.

## Languages and the overlay

Live cloud shares the **Dictation language** settings with Cloud: an optional **Primary language** and **Secondary language**. By default dictation detects the language automatically, and the two preferences are hints where the provider accepts them (see the table). Once a Primary language is set, the overlay shows the globe language chip, offering Primary, Secondary and **Detect automatically**. Picking a language during a recording reconnects to the same provider with the new language and replays the audio recorded after the last finished segment, so the rest of the recording uses the new language. Languages the active provider does not list are disabled in the chip, and **Detect automatically** is disabled for Speechmatics. The Manage sheet warns when your Primary or Secondary language is not listed by that provider.

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

- Audio leaves the Mac only while Live cloud is active (or a provider test is armed), and only to the active provider, or while a meeting records with Live cloud chosen in FluidMeet, and then only to that meeting's provider. It streams during the recording, not after it. The key check at activation sends no audio.
- No network contact with a provider happens until you save its key.
- Only audio and the session settings (model, and language where the provider takes it) are sent. App or window context, preceding text and Custom Dictionary terms are not sent to live providers.
- Deepgram requests do not carry `mip_opt_out=true`, so they take part in Deepgram's Model Improvement Program and Deepgram may use the audio to improve its models. Opting out would forfeit the 50% discount Deepgram's listed prices assume.
- Keys are entered in AI Providers and stored in the personal app's macOS Keychain item under the provider's ID, for example `soniox`, `openai` or `assemblyai`. A provider has one key for everything it does: OpenAI's key serves both its text models and Live cloud, and Mistral's and AssemblyAI's serve text, Cloud and Live cloud. A key saved by an earlier version under `live-transcription.<provider>` was copied to that entry on the first launch of this version; the old entry is kept, and still updated when the key is saved again, so an older build keeps working after a downgrade. A key changed in an older build after that copy is ignored by this version. When AI Providers already held a different key for the same provider, both are kept and the provider shows **Two keys** (see [Cloud transcription](cloud-transcription.md#keys-saved-before-this-version)). A Live cloud provider that was active without a `live-transcription.<provider>` key is cleared on the first launch, so its AI Providers key never starts streaming unasked; until the copy can be written to the Keychain, Live cloud reads only the old `live-transcription.<provider>` entries.
- The debug log records only metadata: the provider id, the model id, an error kind or provider error code, durations such as `LIVE_FINAL ... stopToFinalMs=<n> streamedMs=<n>`, and HTTP or WebSocket close codes. It never records audio, transcript or partial text, API keys, provider error bodies, or WebSocket close reasons.
- Transcripts from live dictation are stored in local history like any other dictation, attributed to provider `live-<provider>` with its model id.

## Usage

Each provider's Manage sheet shows **Streamed on this Mac: <n> min across <n> recordings**. A recording is counted when it returns its final text, including provider tests; the count is the audio streamed to the provider, plus any short silence the app appends so the provider finalizes the last words. Failed recordings and retries of saved recordings are not counted. None of the providers reports cost during a stream, so the app shows no cost and no estimate; the sheet links to the provider's own usage and billing page, which is the reference for what you are charged.
