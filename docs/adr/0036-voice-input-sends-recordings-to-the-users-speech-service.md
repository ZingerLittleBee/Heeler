---
status: accepted
---

# Voice Input sends recordings to the user's speech service

[ADR 0003](0003-ios26-speechanalyzer-dictation.md) chose on-device
SpeechAnalyzer dictation because "nothing I say to my Agents ever leaves the
phone", and the feature was later removed without a recorded reason. Voice
Input returns with a different constraint from the owner (2026-11-03): cloud
recognition is the default, a recording may go to a third party once the user
agrees, and no model runs on the phone or on the user's computer. The
research behind it, including the vendor evidence, is
[voice-input.md](../research/voice-input.md).

## Decision

- **Bring your own key.** Heeler operates no speech proxy. The user picks a
  service in Settings › Voice Input and enters their own API key, which stays
  in the Keychain on this device only. Built-in services are OpenAI
  (`gpt-transcribe`), DeepInfra and SiliconFlow (China) (both
  `Qwen/Qwen3-ASR-1.7B`).
- **One request shape.** Every service, built-in or Custom, takes OpenAI's
  `POST <base>/audio/transcriptions`: multipart `file` and `model`, a Bearer
  key, and a JSON `text` in reply. Per-service differences are data on the
  preset, not code paths: `gpt-transcribe` takes the possible languages as
  `languages[]` and answers 400 when `language` comes beside them; DeepInfra
  takes one `language`; SiliconFlow documents neither, so nothing is sent.
  Custom adds `response_format=json` and sends `language` only when the user
  turns it on.
- **Custom is fenced.** A Custom base URL must be https, with no user
  information, query or fragment; a pasted `/audio/transcriptions` or trailing
  slash is stripped. Its key is stored under a digest of the normalized URL,
  so an edited URL never inherits the old key, and saving a new URL deletes
  the old one. Every redirect is refused rather than followed, since
  URLSession resends the body, key header included, on 307 and 308.
- **Agreement per destination.** Save asks once before recordings may go to a
  service, naming its operator or host. Agreement is kept per preset and
  model, and per Custom URL and model, so a different destination asks again.
- **Upload, not streaming.** The recorder writes 16 kHz mono 16-bit WAV, at
  most two minutes (under 4 MB), to a temporary file with Complete
  protection, read into memory and deleted when recording stops. A failed
  upload keeps the recording in memory for Retry.
- **The draft takes the text once.** Nothing is written while recording.
  Send, or Stop, hides from the first tap until the text lands, and Send
  waits one second after, since the text can turn Stop into Send under a
  finger. Because Send cannot empty the draft meanwhile, the text goes in at
  the caret like a Snippet, waiting while the input method holds marked text,
  which a store write would destroy. Spaces are added only between Latin
  words.
- **A recording belongs to its Composer.** One app-level session owns the
  microphone, since the audio session is per process; starting another
  Composer's recording stops the first, whose text still goes to its own
  draft. Backgrounding, the Composer leaving the screen, or the system ending
  the recording (time limit, call, lost route) sends what was heard. Direct
  Input, Chat's Blocked Card and the last detail leaving the Agent cancel it.
  Heeler declares no audio background mode.

## Considered Options

- **A Heeler-run proxy with one bundled key**: rejected. It puts the
  developer between the user and every recording, needs accounts and abuse
  limits, and makes the developer pay for speech.
- **Only built-in vendors**: rejected. The OpenAI-shaped endpoint is what
  self-hosted servers, aggregators and other vendors share, so Custom costs
  one form and no new client.
- **Live partials into the draft**: rejected. Partials flip Stop to Send,
  allow sending half a sentence, resize the terminal Composer and the PTY
  with it, and overwrite marked text.
- **Discard the text when the draft changed**: rejected once Send is gated;
  only Send could empty the draft under a pending result, so discarding
  would throw away speech for ordinary edits.

## Consequences

- PRIVACY.md and the App Privacy answers must name the built-in services and
  say that Custom sends audio wherever the user points it. The DeepInfra and
  SiliconFlow presets need a real-key smoke test before a release ships
  them; only OpenAI's was run (synthetic speech, 2026-11-03).
- Apple's on-device engine (iOS 26+) and text cleanup with the same key are
  later slices; both plug in behind the session without changing the draft
  rules.
- The microphone usage string now says recordings go to the chosen service.
