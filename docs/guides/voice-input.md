# Use Voice Input

Tap the microphone beside **Send** in the Composer to speak, and tap again to stop. The transcribed text lands at the cursor in your Agent terminal or [Chat](chat.md) draft.

You need your own API key for OpenAI, DeepInfra, SiliconFlow (China), or a compatible speech service. Heeler keeps no copy of your recordings.

## Set up Voice Input

1. Open **Settings > Voice Input**, or tap the microphone in the Composer before Voice Input is set up.
2. In **Service**, choose **OpenAI** (`gpt-transcribe`), **DeepInfra** or **SiliconFlow (China)** (`Qwen/Qwen3-ASR-1.7B`), or **Custom**.
3. For **Custom**, fill in:
   - **Base URL**: an `https://` URL compatible with OpenAI's `audio/transcriptions` endpoint.
   - **Model**: the model name the service expects.
   - **Send Language**: sends your first preferred language when on. Leave it off if the service rejects the language setting.
4. Enter your **API Key** and tap **Save**.
5. On the first save for a service, Heeler asks **Send Recordings to …?**. Tap **Send Recordings** to confirm.

The first time you record, iOS asks for microphone permission.

Your key stays in this device's Keychain. Tap **Remove Key** in **Settings > Voice Input** to delete it.

## Record a message

Tap the microphone beside **Send** to speak, then tap it again to stop. The text lands at the cursor in **Message Agent**, so you can edit it before sending.

- A recording bar shows cancel (**✕**), a volume waveform, and elapsed time.
- The microphone turns red while recording, and **Send** and **Stop** hide to avoid stray taps.
- While transcribing, the microphone shows a spinner; tap **✕** to cancel.
- Each recording lasts up to 2 minutes, then stops and transcribes automatically.
- Backgrounding Heeler or leaving the Composer ends the recording and transcribes it into that draft. Entering Direct Input, leaving the Agent, or a Blocked Card replacing the Composer in Chat cancels it.

## Keywords and Prompt

In **Settings > Voice Input**, two fields shared across all services stay when you switch **Service**:

- **Keywords**: comma-separated names and terms you say, such as `herdr, Claude Code, Codex, pnpm, SwiftUI`, so the service spells them right.
- **Prompt**: context for what you talk about, sent as written.

**OpenAI** reads **Keywords** directly and leaves **Prompt** unchanged. **DeepInfra**, **SiliconFlow (China)**, and **Custom** do not read **Keywords**; editing **Keywords** under them or switching to one syncs a `Vocabulary: …` line in **Prompt** so **Prompt** shows what is sent.

## Choose a microphone

On iOS 26 and later, AirPods with high-quality recording are used automatically; other Bluetooth headphones use your iPhone or iPad microphone.

Turn on **Always Use iPhone Microphone** (or **Always Use iPad Microphone** on iPad) in **Settings > Voice Input** to always use the built-in microphone. It is off by default.

## When something goes wrong

When a recording produces no text, the Composer shows the reason with **Retry** (sends the same recording again), **Voice Input Settings**, **Open Settings** (for microphone permission), and **Dismiss**.

- **The speech service rejected the API key.** — Tap **Voice Input Settings**, save a valid key, then tap **Retry**.
- **Heeler can't use the microphone. Turn it on in Settings.** — Tap **Open Settings** and allow microphone access.
- **The recording was too short.** — Speak for at least half a second.

## Privacy

Recordings are uploaded to your chosen service under its terms and billed to your key. Heeler's developer receives none of them. See the [Voice Input section of the Privacy Policy](../../PRIVACY.md#voice-input).

Last checked on 2026-11-05.
