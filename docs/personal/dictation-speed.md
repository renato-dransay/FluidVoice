# Dictation speed

How long a dictation takes after you stop depends on how many requests it needs and on the models that answer them.

## One request or two

With OpenRouter as the Cloud voice engine and a Cleanup Style on, the recording and the style go to the Style model in one request; see [Two models, chosen by the Cleanup Style](cloud-transcription.md#two-models-chosen-by-the-cleanup-style). With every other Cloud provider, with Local and with Live cloud, the transcript comes first and the Cleanup Style runs afterwards as a second request on the default text provider; see [Dictation with a provider other than OpenRouter](cloud-transcription.md#dictation-with-a-provider-other-than-openrouter). Live cloud has the transcript ready when recording stops, so only the Cleanup Style request remains.

## What the app does on its own

- **It opens connections while you speak.** When a recording that will be cleaned up starts, the app opens the connection to the text provider that will run the Cleanup Style, so the request after the recording does not wait for a new connection. With a Cloud provider other than OpenRouter, it also opens the connection to that speech provider. See [Text fidelity, costs, and privacy](cloud-transcription.md#text-fidelity-costs-and-privacy) for what this sends.
- **It asks for a lower reasoning effort for Cleanup Styles** on models whose provider documents one, when you have not saved a reasoning setting for that model: Gemini 2.5 Flash and Flash-Lite turn thinking off, Gemini 3 models use their lowest level, Gemini Pro models use `low`, Qwen on Groq turns reasoning off, and OpenAI's o-series uses `low` instead of `medium`. This applies only on the provider's own server, not through OpenRouter, AssemblyAI's gateway or a custom server. Command Mode, Edit and meeting summaries keep the model's usual setting. If a provider rejects the lower setting, the app sends the request again without it and does not ask again until it is restarted.

The provider, the model and the style's prompt are never changed. A lower reasoning effort can change the wording a model returns.

## What you can choose

A small text model answers faster than a large or reasoning model. The Reasoning row in **AI Providers > Manage** shows what is sent for the selected model ("Automatic: …" or "Custom: …") and, when Cleanup Styles send something lower, says so under the row. To keep a model's own reasoning for Cleanup Styles, open Reasoning > Configure…, leave the switch off, and press Save; a saved setting is used for every feature. **Reset to Automatic** in the same editor removes it again.
