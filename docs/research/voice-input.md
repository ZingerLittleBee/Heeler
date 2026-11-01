# Voice Input Research

Date: 2026-11-02. Facts were checked on 2026-11-01 and 2026-11-02; prices and
model names change quickly, so recheck them before implementation.

Scope: speech to text into the Composer draft, for several languages,
user-configured bilingual pairs such as zh + en with switching inside a sentence,
and AI cleanup of fillers and self-corrections. Typical input is a spoken coding
instruction full of English identifiers.

Method: six independent research passes (Apple APIs, X posts, cloud APIs, cleanup,
Voxt source, third-party on-device models), then one adversarial check per pass
against primary sources, then a cross-report critique. Of 224 checked claims, 90
were confirmed as written and 134 were corrected, refuted, or unverifiable. Only
surviving facts appear below. **No candidate has been tested with real Heeler
speech on an iPhone.** Every ranking here is a hypothesis for the evaluation in
[Evaluation before picking defaults](#evaluation-before-picking-defaults).

## Conclusions the facts force

- **Apple speech APIs are not a bilingual engine.** `SpeechTranscriber`,
  `DictationTranscriber`, and `SFSpeechRecognizer` each bind one `Locale`, with no
  code-switching parameter. [`SpeechAnalyzer.setModules`](https://developer.apple.com/documentation/speech/speechanalyzer/setmodules(_:))
  documents about two ongoing recognition instances on iOS, so two locales in
  parallel sit at that limit with no merge API.
- **The deployment target stays at iOS 18.** New speech and Foundation Models APIs
  need `#available` gates. Apple reported 79% of iPhones and 68% of iPads on the
  26 releases as of [2026-06-07](https://developer.apple.com/support/app-store/).
- **No API presses the keyboard dictation key or silently runs Writing Tools.**
  Any automatic cleanup needs its own model path.
- **Cleanup is two stages with a recoverable original.** Speech to text produces
  frozen raw speech text; a text model cleans it; a guard falls back to raw. Theo
  [reported](https://x.com/theo/status/2102703393043005737) Wispr Flow dropping
  `not` and `never`; he did not say which layer did it, so both layers need testing.
  A dropped negation in an Agent instruction inverts its meaning. Gemini Smart
  documents no way to also get the uncleaned text, so it cannot be the default.
- **Voice only fills the draft.** It never sends. This matches the Composer
  definition in [CONTEXT.md](../../CONTEXT.md).
- **No single cloud vendor is verified to cover the audience, so plan for at least
  two adapters.** The Gemini, OpenAI, and Anthropic supported-region lists exclude
  mainland China and Hong Kong, and Heeler is on the Hong Kong store. Alibaba offers
  Beijing and Singapore with separate per-region keys, and other vendors' mainland
  reachability is untested. Volcengine requires real-name verification and Bailian
  may; whether overseas identities can pass either is unverified.
- **Cloud speech needs explicit consent per vendor.**
  [Guideline 5.1.2(i)](https://developer.apple.com/app-store/review/guidelines/)
  names third-party AI and has no bring-your-own-key exception.
  [PRIVACY.md](../../PRIVACY.md) currently says prompts travel only over SSH, and
  the Composer definition says "entirely on device". Both change before any cloud
  path ships, under a new ADR that records why cloud speech is now acceptable,
  citing the server recognition rejected in
  [ADR 0003](../adr/0003-ios26-speechanalyzer-dictation.md) as history.
- **Host `claude -p` or `codex exec` is not the default cleanup.** It takes seconds.
  Without `--bare` it runs project hooks and `.mcp.json` from
  [untrusted directories](https://code.claude.com/docs/en/headless.md), and with
  `--bare` it does not use the subscription. macOS Hosts have already shown an
  unreadable login keychain over SSH exec. Anthropic's
  [consumer terms](https://www.anthropic.com/legal/consumer-terms) restrict
  automated access, and nothing names this exact shape, so its status is unsettled.
- **Defaults come from our own evaluation.** No public data covers zh + en technical
  speech, real voices, streaming configurations, and iPhones together.

The old Dictation left no quality evidence: its PR's device checks have no recorded
result, and [ADR 0012](../adr/0012-monitor-non-realtime-agent-surface.md) says no
rationale was recorded when it was removed together with `AgentInputBar`.

## Recommended architecture

```text
Composer mic -> VoiceInputSession (one app-level owner; AVAudioSession is per process)
                 -> capture: 16 kHz mono, buffered locally until the socket is ready
                 -> SpeechEngine: Apple (iOS 26+) | cloud adapters | later on-device
                 -> frozen raw speech text, partials in a preview only
                 -> VoiceTextPolisher: none | BYOK LLM | later Foundation Models
                 -> guard: fall back to raw on any failed check
                 -> one insertion into the draft, with one-tap restore of raw
```

- **Do not stream into the draft.** Partials go to a separate preview. Live writes
  would flip Stop to Send, allow sending half a sentence, grow the editor and resize
  the PTY, and overwrite marked text during IME composition.
- **Keep recording state outside the draft.** `AgentComposerStore.canSend` already
  blocks Send while a dropped image uploads, and voice can add the same kind of gate.
  Do not reuse its private-use placeholder: a token makes the draft non-blank, which
  flips Stop to a disabled Send (`AgentComposerPrimaryControl`), and writing it
  overwrites marked text.
- **Insertion waits for composition.** Store-side draft changes reach the editor as
  `textView.text = text`, so the single insertion, restore, and cleanup action also
  destroy marked text. Insertion waits until `markedTextRange` is nil, and the cleanup
  action is disabled during composition. This needs composition state exposed from
  `AgentComposerUITextView`.
- **A slow result must not overwrite newer work.** Capture the input at start and
  apply the result only if the draft still equals it; otherwise discard it. Without
  this, Send clears the draft and a late write puts the text back, ready to send twice.
  Offer restore only while the draft still equals the polished text.
- **Composer height does not change while recording.** Height inside the terminal
  Composer resizes the remote PTY, so the preview is a fixed-height overlay or uses the
  editor's existing frame. The final insertion may resize once, like typing.
- **Mic placement:** its own control beside the primary button, not a third primary
  state, so it stays available while Stop is showing and when text exists.
- **Surfaces:** Agent terminal and Chat Composers only. Direct Input and Shell
  Terminal write straight to a PTY with no review step.
- **Gesture:** tap to toggle and hold to talk, with a VoiceOver action. X posts show
  both styles in use, with no measured preference.
- **Lifecycle:** recording stops on background and when the Composer leaves the
  screen. Do not add the `audio` background mode, which an SSH companion would
  struggle to justify under guideline 2.5.4. The owner sits above scenes for iPad
  multi-window.
- **A result belongs to its Agent.** Each recording binds to the
  `AgentComposerSession` it started on, and its result only ever enters that draft.
  Stopping because of Direct Input, the Blocked Card, or the last detail leaving
  (`detailDidDisappear`) cancels the pending result instead of inserting into a hidden
  draft (ADR 0016). A Chat and terminal swap keeps the draft and needs an explicit
  decision during implementation.
- **Older systems:** iOS 18 to 25 get cloud engines when a key exists, otherwise the
  system keyboard. No `SFSpeechRecognizer` tier: it needs its own authorization even
  on device, and a [vendor benchmark](https://lyonesse.app/blog/apple-speech-api-benchmark.html)
  measured 9.02% WER against `SpeechAnalyzer`'s 2.12% on clean English (the article
  does not name the module; Mac, published by a transcription app team).

## Bilingual model

Copy Voxt's data model, not its code: an ordered language list where the first entry
is primary and the rest may also appear. It becomes a per-engine strategy, because
the setting means different things:

| Engine class | Meaning of the list |
| --- | --- |
| Single locale (Apple) | Primary locale only. A real constraint; the second language is best effort. |
| Auto-detect with hints (Deepgram, Soniox, Gemini) | A bias, not a limit: Deepgram documents "Hints bias detection; they do not restrict it". |
| Chinese vendors | Vendor-specific; some models take only one language value. |

Whether passing the pair helps or hurts switching is undocumented for Gemini, so it
is an evaluation axis, not a setting to infer. Evidence covers zh + en. ja + en has
only indirect data and zh + ja has none, so the first release promises zh + en and
labels others best effort. Translation (speak one language, output another) is a
separate mode, off by default.

## Speech engines

### Cloud candidates for evaluation

Hourly prices are from vendor pricing pages. "Inside a sentence" means the vendor's
documentation says so explicitly.

| Service | Inside a sentence | Vocabulary | Streaming price | Notes |
| --- | --- | --- | --- | --- |
| ElevenLabs Scribe v2 Realtime | Not stated | 50 terms, 20 chars each | $0.39 | Non-streaming `scribe_v2` had the lowest CoSE-E CER, see below; no Realtime number; `no_verbatim` removes fillers |
| Soniox | Yes, zh to en example | Context | $0.12 | Cheapest explicit option; no Swift SDK |
| AssemblyAI Universal-3.6 Pro Realtime | Yes, includes zh | Keyterms included | $0.45 | Billed by session duration; published 7.20% WER covers European pairs only |
| Deepgram Nova-3 `multi` | Yes, includes zh | Keyterms, +$0.0013/min | $0.55 to $0.63 | zh added 2026-10-23, no independent zh + en data; accepts Opus; needs `mip_opt_out=true` |
| Gemini 3.5 Transcribe Live | Across utterances only; "intra-sentence" is the file model | Up to 1000 | About $0.54 | PCM only; `cmn-Hans-CN` but no `cmn-Hant-TW`; free tier trains; no China or Hong Kong |
| Doubao streaming ASR 2.0 | Language coverage only | Hotwords + context, 100 tokens total | 1 CNY | Now one API key; `enable_ddc` removes disfluency, off by default |
| Alibaba `qwen-audio-3.1-asr-flash-message` | Not stated | Hotwords, context | Token priced | Recommended for input methods; `disfluency_removal_enabled` handles self-correction |

Excluded: Azure continuous language identification (documented as not supporting
same-sentence switching); `whisper-1` and `gpt-4o-*-transcribe` (shut down
2027-02-26); Paraformer-realtime-v2 for new work (Alibaba suggests migrating, and it
is absent from the Singapore list); Whisper family as a mixed-speech primary.

The only independent cross-vendor ZH/EN numbers we found are in
[CoSE-E](https://arxiv.org/html/2609.35645) (WER/CER): Scribe v2 .073/.031,
Qwen3-Omni .040/.039, Gemini 3 Flash .090/.041, AssemblyAI U3.5 .093/.046. These
use ElevenLabs TTS audio, which the paper says favors Scribe and makes results an
upper bound, with no disfluencies, batch configurations, 294 sentences, and different
models from those above. They guide test design, not selection.

Working bets until the evaluation replaces them: Scribe v2 Realtime overseas,
Doubao 2.0 in mainland China. Neither bet is verified on our sentences.

Price is unlikely to separate these. At an assumed 60 clips of 15 seconds per workday,
speech runs about $0.70 to $3.50 per month on the overseas vendors above and cleanup
about $0.20 to $0.60. Setup is the larger cost: account, billing or real-name checks,
a key made on a computer, then the same again for the LLM. A single key covering both
stages would remove a step, but that needs confirming per vendor.

Vendors advise against long-lived keys in mobile clients. Without a backend this is
the only direct shape, and the exposed key is the user's own, so settings explain the
risk and suggest a restricted key. Store them in a separate Keychain service, since
`SecretStore.readAll` walks a whole service. These would be the app's first HTTP calls
from Swift (no `URLSession` exists today) and the first to send user content to a third
party; overlay networks only exchange metadata with theirs.

### Apple on-device (iOS 26+, zero key)

- The zero-key route, single locale and labeled so. `SpeechTranscriber` has a
  hardware gate; a [developer report](https://developer.apple.com/forums/thread/806765)
  has iPhone 12 and later supported.
- [`contextualStrings`](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings)
  (100 total) is documented for `DictationTranscriber`, not `SpeechTranscriber`, and
  `progressiveShortDictation` is the preset that fits short prompts. Compare both.
- One weak probe (macOS 27, three synthetic sentences, `SpeechTranscriber` only):
  zh-CN kept "use effect" but damaged "dependency array", and wrote "run" as a Chinese
  near-homophone. en-US produced pinyin-like garbage. This justifies a device test,
  nothing more.
- A probe found 45 `SpeechTranscriber` and 54 `DictationTranscriber` locales on Apple
  Silicon macOS, including zh-CN, zh-TW, zh-HK, yue-CN, ja-JP, and ko-KR. iPhone lists
  are untested; query at runtime. In the Simulator, `SpeechTranscriber` reports no
  locales, and `DictationTranscriber` lists locales but has no audio formats and fails
  to analyze, so `supportedLocales` does not prove it can transcribe there.

### Third-party on-device (deferred)

Worth a later A/B for offline use and iOS 18, not the first release. No candidate has
a zh + en number on an iPhone.

- **sherpa-onnx v2.0.1:** SwiftPM product with checksummed binaries, Apache-2.0, iOS 15.
- **SenseVoice-Small `2024-07-17-int8`:** the pretrained model leads on ASCEND
  ([paper](https://arxiv.org/html/2501.12122v2): WER .114 vs Whisper .289, Paraformer
  .424; the int8 export is not itself scored). Avoid `2025-09-09`, which has no
  punctuation and is tuned on Cantonese. Commercial use is
  unsettled: the maintainer reopened and downgraded their answer in
  [#334](https://github.com/QwenAudio/SenseVoice/issues/334).
- **X-ASR-zh-en:** Apache-2.0, streaming, roughly 134 MB archive, self-reported numbers.
- **Zipformer bilingual 2023:** real streaming and hotwords, but hotwords require
  `modified_beam_search`, it has no Japanese, and it is dated.
- **WhisperKit:** not a mixed-speech primary. A `nil` language prefills English instead
  of detecting, and one third-party test had Large v3 Turbo out of memory on a 4 GB iPad.
- **Excluded:** Parakeet, Canary, Voxtral Mini 3B (no Chinese); Audio8 (CC-BY-NC);
  Argmax Pro (1000 device-month minimum).

Apple DTS [said](https://developer.apple.com/forums/thread/793131) post-install model
updates are not known to conflict with the guidelines, and suggested confirming with
App Review. Do not depend on `huggingface.co` at runtime from mainland China.

## Cleanup

Is it just a prompt? For a general chat model, yes, plus output checks. The prompt
alone is not sufficient, because a dictated instruction is itself a prompt. "写一个函数"
can produce a function, and a schema allows `{"text":"def f(): ..."}`. The dependable
layer is the fallback, not the wording.

**Prompt rules:** treat the speech text as data; no tools; keep the mixed languages and
never translate; keep identifiers and casing; resolve only explicit self-correction.
Few-shot examples need counterexamples: in "把那个函数改一下" the 那个 carries meaning, and
"这个结果不对，改成 useRef" is a statement plus an instruction, not a correction. Silently
deleting part of an instruction is worse than leaving a filler.

**Guard, on every result:** empty output, refusal text, length ratio, retention of Latin
tokens and negations from raw, and truncation. Code cannot prove a removal was a real
self-correction. Reject a removal when no explicit marker such as 不对 or "I mean" is
present; a marker alone does not prove it either ("这个结果不对，改成 useRef" has one), so
these cases stay in the corpus. Thresholds need corpus data. Apple's `permissiveContentTransformations` returns a refusal
as an ordinary string, so catching thrown errors is not enough.

**Model configuration is per model; wrong values fail outright on some models and
silently degrade on others:**

| Model | Required | Per clip (800 in / 150 out) |
| --- | --- | --- |
| Claude Haiku 5.5 | `thinking: disabled`, no non-default temperature, no prefill (400), `output_config.format`; handle `refusal` stop reason, including false cyber positives | About $0.00016 |
| GPT-6 Luna | Reasoning `none` set explicitly; structured outputs; about 115 tok/s, so 150 tokens decode in about 1.3 s | About $0.00016 |
| DeepSeek V4.1 Flash | `thinking: disabled`; `json_object` only, and blank content can arrive with `stop`; workday hours in Beijing are peak | About $0.00042 at peak |
| Foundation Models (later) | iOS 26+, Apple Intelligence; prompts need retesting on iOS 27; Apple says it may not be suitable for creating code or logical reasoning, while refining or editing text is a listed capability | Free |

`max_tokens` needs a floor for short clips and room for any reasoning tokens. Sampling
is not deterministic on these models, so run each injection case repeatedly. `gpt-5.4-nano`
is deprecated and `gpt-5-nano` shuts down 2026-12-11. Groq's `gpt-oss` documents no way to
turn reasoning off.

**Latency:** Wispr's public budget is [700 ms end to end](https://wisprflow.ai/post/technical-challenges)
on dedicated inference. Whether public BYOK endpoints can come close is unmeasured; the
only public figures use a 10k-token input. Since partials are already visible, start with
a hard timeout of about 2.5 s (an unmeasured working value; set it from evaluation data)
and fall back to raw. Cross-border WebSocket setup adds about 0.6 to
1.2 s by estimate, so audio must buffer locally from the first frame.

**Levels:** off, clean (default once configured), and restructure (off by default). Users
disagree on rewriting: some want tidy instructions, others want their own wording.

**Vocabulary:** feed ASR first, since an LLM cannot restore what ASR lost. Limits differ too
much for one shared list (see the table above), so keep it short and per engine: Voxt uses 8
terms and 220 characters selected by match score. Sources in Heeler include the cwd, Skills,
and sent messages. File names and Agent Transcripts are third-party content, and sending them
widens the privacy disclosure and the injection surface. Whisper
[considers only the final 224 tokens](https://developers.openai.com/cookbook/examples/whisper_prompting_guide)
of a prompt, so order matters on that family.

## What to take from Voxt

Source: [sglang-omni/Voxt](https://github.com/sgl-project/sglang-omni/tree/main/Voxt),
imported from the now archived hehehai/voxt. The macOS pipeline shape matches: ASR, optional
cleanup, insertion, with Precise Cleanup separate from Rewrite.

Take: the ordered language list, a per-engine hint table, the separation of system rules from
an `Input:` user message, the dictionary shortlist, and learning from edits made before Send.

Do not take:

- `LLMVisibleOutputSanitizer`. By code reading, it would truncate a normal instruction at
  `output:` and revert whole results on lines starting with `step 1`. It also does not stop a
  clean-text answer.
- The zh-Hans cleanup prompt as written. It removes 然后, which loses step order, and converts
  括号 and 中括号 into full-width symbols.
- Rewrite in the Composer, which executes the dictated instruction.
- Its multilingual hint text, written but never read (`multilingualContext`).

`Voxt/LICENSE` differs from standard Apache-2.0 in sections 3 and 4(c), and GitHub reports
`NOASSERTION`. Reusing ideas is fine; copied code carries that exact text and needs a legal read.

## Compliance and platform checklist

- `NSMicrophoneUsageDescription` for capture; it is not in [project.yml](../../project.yml)
  today. Add `NSSpeechRecognitionUsageDescription` only if a device test of the Apple engine
  shows it is required (the earlier `SpeechTranscriber` branch omitted it, though Apple's key
  page says to include it for Speech framework use). Keep no "never leaves your phone" wording.
- Per-vendor consent screen on first use and on vendor change (5.1.2(i)); a visible recording
  indicator (2.5.14); Review Notes with a limited test key or a zero-key path (2.3.1(a)); no
  hidden remote toggle (2.5.19).
- App Privacy label for BYOK audio is undefined by Apple's text. Declare conservatively or
  explain in Review Notes, and ask App Review before submission.
- Audio session: without `mixWithOthers`, each press stops the user's music; with it, music
  enters the mic. Haptics are silent during recording unless
  `allowHapticsAndSystemSoundsDuringRecording` is set. Handle `builtInMicMuted` on iPad. AirPods
  input needs `allowBluetoothHFP`. Compare on a device whether session activation clips the
  first syllable. Test the Agent Notification banner tone (`AudioServicesPlayAlertSound(1007)`)
  during recording, and suppress it if it reaches the mic.
- Heeler is not on the mainland China store, so generative AI filing is not a current blocker.
  Do not assume BYOK would be exempt if that changes.
- New Swift files need `make generate`. PRIVACY.md, the source map, CHANGELOG, and
  `Sources/Heeler/PrivacyInfo.xcprivacy` follow; the manifest must match the App Privacy
  declaration.
- CONTEXT.md gets "Voice Input", avoiding confusion with keyboard dictation. Do not reuse
  Transcript, which means what an Agent's program writes on its Host.

## Evaluation before picking defaults

No engine choice is final until this runs.

- **Corpus:** 40 to 60 real sentences recorded on an iPhone, by at least the owner, in quiet and
  noisy settings and with AirPods. Cover zh + en with identifiers, paths, and negations, plus
  self-corrections and its counterexamples, and instruction-shaped sentences.
- **Engines:** the cloud table above (with and without language hints), Apple zh-CN with both
  modules, keyboard dictation as the baseline, SenseVoice and X-ASR on a Mac for accuracy only.
- **Metrics:** identifier retention, negation retention, CER, time to final, reconnect behavior
  on a weak network, and whether WebSocket works under common proxy setups (reports suggest
  `URLSessionWebSocketTask` may ignore system HTTP proxies; unconfirmed). File upload is the
  fallback if streaming fails.
- **Cleanup:** 80 to 150 text pairs with repeated runs on injection cases; no injection may pass
  the guard into the draft.

## Delivery order

1. **Evaluation** (above). It also tests the [UITextInput](https://developer.apple.com/documentation/uikit/uitextinput)
   dictation callbacks on `AgentComposerUITextView`.
2. **Cleanup first:** `VoiceTextPolisher`, guard, and a Composer action. It should also apply to
   keyboard dictation and third-party input methods on iOS 18 (third-party input in Heeler is
   untested), with no microphone or audio work, and it exercises the riskiest layer first. It
   still triggers the consent and privacy work. Its input is the current selection or whole draft,
   not speech text. That may contain pasted text, Snippets, Skill tokens, and Host paths, so consent
   copy says the draft is sent, the action is disabled while `hasPendingDroppedImages` is true, and
   the guard also retains paths and Skill tokens.
3. **In-app capture with cloud engines:** language list, vocabulary, consent, one overseas and one
   mainland adapter. This is what delivers configurable bilingual input.
4. **Apple engine** for a zero-key path on iOS 26+.
5. **Optional, each behind evidence:** sherpa-onnx, Foundation Models cleanup (the Chinese rollout
   in 27.3 is announced, but third-party framework access is unknown), Host relay or inference.
   Host inference could suit Heeler because it already has an encrypted channel to the user's
   machine: audio would stay on those machines and phone memory would stop mattering. There is no
   data yet. `HeelerSSH` exposes direct-streamlocal and exec channels publicly, but direct-tcpip stays
   internal to Jump Hosts and it has no remote forwarding, so a relay needs a prototype over a Unix
   socket or exec.

## Not verified

- Connectivity from mainland China for any vendor, and whether non-mainland identities can open
  Doubao or Bailian accounts.
- Any engine's accuracy on Heeler-style speech, iPhone memory and thermals, Opus encoding on iOS.
- Two concurrent recognizers on an iPhone, and microphone behavior with two foreground iPad apps.
- OpenAI usage terms and Codex help pages (HTTP 403 during checking).
- The legal reading of Anthropic's terms for Host CLI use, which is our interpretation.
