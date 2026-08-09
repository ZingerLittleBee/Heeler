# Raise deployment target to iOS 26 for SpeechAnalyzer Dictation

Status: Superseded. The custom reply bar and Dictation feature were removed in
favor of direct terminal input through the standard iOS keyboard. With the
iOS 26-only implementation gone, the app has returned to ADR 0001's iOS 18
baseline.

## Current Outcome

Heeler supports iOS 18 and later. `Synchronization.Mutex` is the remaining
source-level floor; the app, HeelerSSH package, and bundled OpenSSL/libssh2
artifacts all declare the same iOS 18 minimum. The iOS 27 status-bar treatment
is availability-gated and has an older-system fallback.

Dictation (hold-to-talk voice input on the Agent reply box, see CONTEXT.md) transcribes speech on device. We adopt the iOS 26 Speech framework's `SpeechAnalyzer` / `SpeechTranscriber` and raise the app's minimum deployment target from iOS 18 to iOS 26, giving the whole app a single code path with no `#available` branches. This drops support for devices that cannot run iOS 26, which we accept: the app is early, has no installed base to protect, and the modern speech stack is the reason Dictation is worth building at all.

## Considered Options

- **`SpeechAnalyzer` / `SpeechTranscriber` (iOS 26), target raised to iOS 26** — chosen. The modern stack is on-device, streams partial→final results, manages its own language models via `AssetInventory`, and resolves locales through a supported-locale equivalence lookup. Requiring iOS 26 app-wide means no availability guards and no dual-engine maintenance. The cost is a hard floor on supported OS versions.
- **`SFSpeechRecognizer`, keep target at iOS 18** — rejected. The legacy recognizer defaults to server-side recognition (on-device is best-effort and lower quality), which violates the "nothing I say to my Agents ever leaves the phone" requirement. Its API predates structured partial/final streaming and has no first-class model-download management. Keeping it would also not lower the real floor much for the quality we need.
- **Gate the modern stack behind `#available(iOS 26, *)` and keep an iOS 18 fallback** — rejected. Two engines doubles the surface that must be tested and reasoned about, and the fallback path (`SFSpeechRecognizer`) is the option we already rejected on privacy grounds. Availability branches would also leak the Speech framework's version shape into stores and UI, against the single-seam discipline (`DictationEngine`, mirroring Transport vs Citadel).

## Consequences at Adoption

- Devices that cannot run iOS 26 are unsupported. Acceptable now; revisit only if a real user base on older OSes emerges.
- No `#available` guards for the speech stack anywhere; the app compiles against iOS 26 APIs unconditionally.
- The real engine cannot be exercised in CI or the Simulator — `SpeechTranscriber` reports no supported locales there — so store-level tests run against a scripted `DictationEngine` double and the concrete engine is verified manually on device. This is why the target raise ships as its own prefactor ahead of the Dictation feature work.
- The microphone usage description must be present in the generated Info.plist before any capture path ships. Whether the legacy speech-recognition authorization is still required by the new on-device API is verified during feature implementation (expected: not required).
- ADR 0001's "iOS 18+" floor is superseded by this decision; the native-stack rationale itself is unchanged.
