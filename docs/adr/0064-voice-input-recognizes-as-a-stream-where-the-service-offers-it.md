---
status: accepted
---

# Voice Input recognizes as a stream where the service offers it

[ADR 0036](0036-voice-input-sends-recordings-to-the-users-speech-service.md)
uploads a finished recording; [ADR 0043](0043-voice-input-transcribes-on-device-as-it-is-heard.md)
shows On Device's text in a recorder as it is heard, and set streaming to a
cloud service aside because every vendor speaks its own protocol. Volcengine's
Doubao speech recognition is the first service to stream, so how a service
recognizes speech becomes a property of the service rather than of On Device.

## Decision

- **Two ways, declared per service.** A service lists the ways it offers,
  its default first: **stream** (text as it is heard, in ADR 0043's
  recorder) or **batch** (the finished recording, ADR 0036's bar). On Device
  streams, the upload services and Custom take batches, Volcengine offers
  both and streams by default. Where a service offers both, Settings shows
  **As You Speak** and **After Recording**, saved with the service's options.
  `VoiceRecognizers` is the one place that turns the saved settings into a
  recognizer; the session sees only `VoiceStreamRecognizer` and
  `VoiceBatchRecognizer`.
- **A failed stream falls back to the whole recording.** The recorder keeps
  every recording in memory whatever the way, so when a stream cannot settle
  (a lost connection, an error from the service, no last result within ten
  seconds) a service that also takes batches is sent the whole recording,
  without asking: it is the same destination the user agreed to. A batch
  that fails then offers Retry in the recorder. On Device has no batch and
  keeps landing what it heard.
- **A stream connects before recording.** The recorder starts once the
  service has accepted the request, as On Device waits for its model; the
  handshake took about 150 ms in testing. A handshake refused for
  the key opens Voice Input Settings; any other failure offers Try Again.
- **Volcengine.** One API Key from the current console, sent as
  `X-Api-Key`, with `X-Api-Resource-Id: volc.seedasr.sauc.duration`
  (streaming recognition 2.0) and a fresh `X-Api-Request-Id`, without which
  the handshake is refused. The older console's App ID and Access Token pair
  is not offered. Both ways use the same binary frames over a WebSocket to
  `openspeech.bytedance.com`, uncompressed: batch sends the WAV at once to
  `bigmodel_nostream`, which needs no pacing; stream sends the microphone's
  PCM in 200 ms frames to `bigmodel_async` with second-pass recognition, so
  each sentence is heard again by the batch model and settled when it ends.
  Keywords go as hotwords, free of charge, so they are always sent; the
  Prompt is not, since Volcengine's context is a dialog history. Over its
  hotword limits the service ignores the list without an error, so stream
  sends leading Keywords up to 100 characters and batch up to 5000 words.
  Disfluency removal stays off, as it may drop a negation. No language is
  sent: the default covers Mandarin, Chinese dialects and English, mixed.
  [Volcengine streaming recognition](https://docs.volcengine.com/docs/6561/2687968)
- **Redirects are refused** on the WebSocket handshake as on uploads, and
  each connection uses its own ephemeral session.

## Considered Options

- **Volcengine's file recognition over HTTP** (`auc_turbo`): rejected. It is
  withdrawn from the console for new users and has only the 1.0 model.
- **Sending a stream's audio paced like speech for batch**: not needed. The
  service accepted a whole recording at once in testing, and its answer came
  about a second after the last frame.
- **Recording before the handshake completes, buffering the audio**: not now.
  The handshake is short, and an early failure would otherwise need a
  recording that silently changes way.
- **Asking before falling back to a batch**: rejected. The recording already
  went, or was going, to the same service.

## Consequences

- PRIVACY.md names Volcengine and says a stream sends audio while the user
  speaks.
- `VolcengineSpeechLiveTests` checks both ways and a refused key against the
  real service; session and protocol tests use a scripted WebSocket.
- Hotwords that help recognition were measured only on synthetic speech.
  Real-voice accuracy against the other services is unmeasured.
