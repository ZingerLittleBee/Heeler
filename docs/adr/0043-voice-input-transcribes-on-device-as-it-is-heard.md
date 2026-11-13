---
status: accepted
---

# Voice Input transcribes on device as it is heard

[ADR 0036](0036-voice-input-sends-recordings-to-the-users-speech-service.md)
sends a finished recording to the user's speech service and lets the draft
take the text once. Voice Input now also offers On Device, Apple's dictation
model from iOS 26, whose text arrives while the user speaks. This amends
ADR 0036's "Upload, not streaming" and its rejection of live partials: the
partials show in a recorder, not the draft, which still takes the text once.
The rest of ADR 0036 stands.

## Decision

- **On Device is a service.** It is listed first from iOS 26 and needs no key
  or agreement, since nothing leaves the device. It uses
  `DictationTranscriber` with `progressiveShortDictation`, the keyboard
  dictation model, and passes Keywords as `contextualStrings`. The model is
  downloaded from Settings or from the recorder when a recording finds it
  missing; recording never waits on a download it did not ask for.
- **One language per recording.** Every Speech transcriber takes one
  `Locale` (unchanged through the iOS 27.2 SDK). A Chinese locale keeps
  English words spoken inside Chinese; an English locale garbles Chinese, so
  the language is the one the user mostly speaks. On a Mac probe with
  synthetic zh + en speech, Keywords turned most misheard identifiers into
  exact ones.
- **A recorder takes the input's place.** From the first tap the Composer's
  input area gives way to a recorder, outlined in red, with the keyboard put
  away; the status line and Agent switcher stay. It shows the text as it is
  heard, settled words in full and words still being revised underlined,
  after the whole draft, with a caret at the end; a
  prompt appears only in an empty draft, so it never covers the user's text. Its text box grows a line
  at a time up to three and never shrinks while recording, so the terminal
  above resizes at most twice; longer text scrolls. Below it are the level
  and time, Stop, and Send.
- **The draft still takes the text once.** Stop settles the last words and
  appends the text to the draft, where the recorder showed it, then focuses
  the input with the caret after all the text. Send does the same without
  the focus, then sends the draft through the Composer's own Send, so its
  refusals stay where they are. There is no Cancel: unwanted words are
  deleted from the draft like typed ones. Every other ending — the time
  limit, a call, an engine error, leaving the screen — lands what was heard
  and leaves recording mode without a notice. Only a recording that could
  not start, or heard nothing, shows a failure in the recorder, with its fix:
  Settings, a model download in place, or Try Again.
- **One capture for every service.** `AVAudioEngine`'s input tap is converted
  to 16 kHz mono 16-bit PCM, the format the dictation model asks for and the
  speech services take as WAV. The same audio feeds the device's model as it
  arrives and is kept in memory for upload; it is never written to a file.
- **Recording leaves other audio alone.** The session mixes with other apps,
  keeps Bluetooth A2DP output, and defaults to the speaker rather than the
  receiver, so music on a Bluetooth speaker or headphones keeps playing where
  it plays. Other audio can reach the microphone; that is accepted. The
  hands-free call profile stays excluded, as in ADR 0036.

## Considered Options

- **Text written into the draft as it is heard**: rejected. The editor would
  have to refuse typing and hold its height to keep ADR 0036's rules, and a
  recorder in the input's place shows the same text with neither.
- **A fixed-height recorder**: rejected. Short prompts would leave empty
  lines, and folding from one line to a tall recorder moves the terminal
  further than growing does.
- **Two transcribers in parallel, one per language**: not now. iOS allows
  about two recognition instances and offers no way to merge them; a single
  Chinese locale already carries English words.
- **Streaming to a cloud service**: not now. No streaming protocol is shared
  across vendors, so it needs one adapter per vendor.

## Consequences

- The real engine runs only on a device; the Simulator lists locales but
  cannot analyze. Session tests use a scripted transcriber.
- No speech-recognition permission is asked, as the earlier Dictation
  shipped without it (ADR 0003). Add `NSSpeechRecognitionUsageDescription`
  only if a device shows it is needed.
- Accuracy on real speech with Heeler's vocabulary is still unmeasured.
