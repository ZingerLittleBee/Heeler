# Voice Input Research

Date: 2026-11-02. Facts were checked on 2026-11-01 and 2026-11-02; prices and
model names change quickly, so recheck them before implementation.

Scope: speech to text into the Composer draft, for several languages,
user-configured bilingual pairs such as zh + en with switching inside a sentence,
and AI cleanup of fillers and self-corrections. Typical input is a spoken coding
instruction full of English identifiers.

Method: two rounds. Round one was six independent research passes (Apple APIs, X posts,
cloud APIs, cleanup, Voxt source, third-party on-device models), one adversarial check
per pass against primary sources, and a cross-report critique: of 224 checked claims, 90
were confirmed as written and 134 were corrected, refuted, or unverifiable. Round two
asked how shipped iOS apps deliver speech to text: four research passes, 81 checked
claims with 47 not confirmed as written, a survey of hosted Qwen models, and a costed
comparison of who provides the API. Only surviving facts appear below. **No candidate has
been tested with real Heeler speech on an iPhone, and no vendor API has been called with
a real key.** Every ranking here is a hypothesis for the checks in
[Evaluation before picking defaults](#evaluation-before-picking-defaults).

## Decisions

Owner decisions (2026-11-02):

- A cloud API is the default engine, and iOS built-in speech is the path for people who
  do not want an API.
- Heeler does not run third-party speech models on the phone, and does not require users
  to install a model on their computer. This also accepts that spoken prompts reach a
  third party, with consent.

Recommendation, pending owner confirmation:

- **Bring your own key first. No Heeler proxy is scheduled.** See
  [Who provides the API](#who-provides-the-api).
- **One OpenAI-compatible upload adapter with two presets:** DeepInfra overseas and
  SiliconFlow CN in mainland China, both serving `Qwen/Qwen3-ASR-1.7B`. See
  [Launch presets](#launch-presets).
- **The first slice has no streaming and no partial preview.** Audio uploads when the
  user stops. Live text is added only if evaluation or users demand it.

"Default" has a limit under this recommendation: with no key configured, the first mic
tap offers a choice between connecting a cloud service (recommended) and using the
device. It is not zero configuration.

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
- **No single cloud vendor is verified to cover the audience, so plan for one overseas
  and one mainland endpoint.** The Gemini, OpenAI, and Anthropic supported-region lists
  exclude mainland China and Hong Kong, and Heeler is on the Hong Kong store. The launch
  presets share one API shape, so this needs presets rather than a second adapter, if the
  SiliconFlow smoke test passes. Mainland reachability is untested for every vendor, and
  whether overseas identities can pass Bailian or Volcengine verification is unverified.
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
                 -> capture: AVAudioRecorder, AAC, 16 kHz mono, about 120 s cap (tune later)
                 -> SpeechEngine: cloud preset (BYOK) | Apple (iOS 26+)
                 -> frozen raw speech text
                 -> VoiceTextPolisher: none | same-key LLM | later Foundation Models
                 -> guard: fall back to raw on any failed check
                 -> one insertion into the draft, with one-tap restore of raw
```

- **Do not write into the draft while recording.** Upload has no partials. If a streaming
  engine arrives later, partials go to a separate preview. Live writes would flip Stop to
  Send, allow sending half a sentence, grow the editor and resize the PTY, and overwrite
  marked text during IME composition.
- **Keep the recording until the result lands.** A failed upload stays local so the user
  can retry or switch engines. Delete it on success or dismissal.
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
  Composer resizes the remote PTY, so any recording or uploading state is a fixed-height
  overlay or uses the editor's existing frame. The final insertion may resize once, like
  typing.
- **Mic placement:** its own control beside the primary button, not a third primary
  state, so it stays available while Stop is showing and when text exists.
- **Surfaces:** Agent terminal and Chat Composers only. Direct Input and Shell
  Terminal write straight to a PTY with no review step.
- **Gesture:** tap to start and stop first, with a VoiceOver action. Hold to talk can
  follow. Moshi treats long press as an optional setting, and X posts show both styles
  with no measured preference.
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
- **Older systems:** iOS 18 to 25 use a cloud preset when a key exists, otherwise the
  system keyboard mic. No `SFSpeechRecognizer` tier: it needs its own authorization even
  on device, and a [vendor benchmark](https://lyonesse.app/blog/apple-speech-api-benchmark.html)
  measured 9.02% WER against `SpeechAnalyzer`'s 2.12% on clean English (the article
  does not name the module; Mac, published by a transcription app team).
- **Third-party keyboards still work.** By source reading, the Composer has no secure-entry
  or keyboard restriction, so input method voice features can be used in it; no device test
  yet. WeChat and Baidu input methods are listed on all seven storefronts checked (cn, us,
  hk, tw, jp, sg, mo), Doubao only on cn, hk, and mo. Their first voice use can jump to the
  input method's app, and past `AppActivityCoordinator.defaultGracePeriod` (15 s) Heeler
  tears down its Host connection. Reachability of their voice clouds from overseas is
  untested, so this is a suggestion to users, not a feature.

## Bilingual model

Copy Voxt's data model, not its code: an ordered language list where the first entry
is primary and the rest may also appear. It becomes a per-engine strategy, because
the setting means different things:

| Engine class | Meaning of the list |
| --- | --- |
| Single locale (Apple) | Primary locale only. A real constraint; the second language is best effort. |
| Auto-detect with hints (Deepgram, Soniox, Gemini) | A bias, not a limit: Deepgram documents "Hints bias detection; they do not restrict it". |
| Qwen3-ASR 1.7B (DeepInfra, SiliconFlow) | One `language` value or none. Whether to send the primary is the first evaluation axis, see below. |
| Alibaba `qwen3-asr-flash` | One value, and the docs say to omit it for mixed languages. |
| Alibaba `qwen-audio-3.1` | `language_hints` such as `["zh","en"]`, up to 4; same-sentence behavior is not stated. |

**The owner's good Mac results may come from forced Chinese.** Voxt registers Qwen3 as
requiring an explicit primary language, and its tests assert that zh-Hans + en resolves to
`Simplified Chinese`. The installed version and settings are unconfirmed. In `qwen_asr`,
forcing a language only appends `language X<asr_text>` after the assistant prompt and skips
language identification; the code has no vocabulary restriction, so English words remain
possible (our reading, untested). To reproduce that experience, send `language=zh` when
Chinese is primary and A/B it against omitting the value on real mixed sentences. The rule
flips on Alibaba Flash, so do not copy Voxt's remote path, which passes the primary.

Whether passing the pair helps or hurts switching is undocumented for Gemini, so it
is an evaluation axis, not a setting to infer. Evidence covers zh + en. ja + en has
only indirect data and zh + ja has none, so the first release promises zh + en and
labels others best effort. Translation (speak one language, output another) is a
separate mode, off by default.

## Speech engines

### Launch presets

| Preset | Model | Price | API | Status |
| --- | --- | --- | --- | --- |
| DeepInfra (overseas) | `Qwen/Qwen3-ASR-1.7B` | [$0.00045/min](https://deepinfra.com/Qwen/Qwen3-ASR-1.7B) | `/v1/audio/transcriptions`, upload only | Model page labels it zero retention; file size limit not documented |
| SiliconFlow CN (mainland) | `Qwen/Qwen3-ASR-1.7B` | [¥0.00022/s](https://siliconflow.cn/pricing), about ¥0.0132/min | `https://api.siliconflow.cn/v1`, upload only | Must pass a real-key smoke test first |

Why these two: they are the only pay-per-use, single-key hosts found for the open 1.7B
family the owner likes, and each also sells a cleanup model on the same key (see
[Cleanup](#cleanup)). OpenRouter's 1.7B only forwards to DeepInfra, with a 60 s upstream
timeout and a minimum top-up. Baseten and FriendliAI are dedicated GPU deployments, which
do not suit a single user's key. fal and Replicate's official organization have no listing
found, and Together and Fireworks list none on their pricing pages.

Known problems with the choice:

- SiliconFlow's speech API reference enumerates only `FunAudioLLM/SenseVoiceSmall` and
  `TeleAI/TeleSpeechASR`, contradicting its pricing page. A third-party issue reports 1.7B
  working. Its real-name requirement comes from third-party guides, and its retention
  policy has not been read.
- Hosts do not disclose quantization, and the owner's Mac runs a 6-bit MLX build, so the
  hosted result may differ from what they use today.
- If SiliconFlow fails, the mainland fallback is Bailian Beijing `qwen3-asr-flash` at the
  same price. It uses `chat/completions` with `input_audio`, so it needs a second adapter.

### Qwen API models are not the open weights

Alibaba never states that its API models match the open 1.7B. The Model Studio pages do not
mention it. The Qwen technical report ([arXiv 2601.21337](https://arxiv.org/html/2601.21337v2))
calls Qwen3-ASR-Flash-1208 a member of the family "for reference", and its self-reported WER
differs from 1.7B: AISHELL-2 2.71 vs 2.53, CV-zh 5.35 vs 4.45, LibriSpeech clean 1.63 vs 1.33,
but GigaSpeech 8.45 vs 8.82. Which snapshot the current `qwen3-asr-flash` serves is not
documented. The report has no same-sentence zh + en data for ASR. Treat them as separate
models.

| Alibaba model | Mode | Price (Singapore / Beijing) | Use |
| --- | --- | --- | --- |
| `qwen3-asr-flash` | Upload, up to 5 min and 10 MB | $0.0021 / about $0.0019 per min | Mainland fallback |
| `qwen3-asr-flash-realtime` | WebSocket, PCM or Opus | $0.0054 / about $0.0028 per min | If live text becomes a hard requirement |
| `qwen-audio-3.1-asr-flash-message` | WebSocket, 16 kHz only | Token priced, about $0.0014 to $0.0023/min input by estimate, plus output | Alibaba's recommendation for input methods; has `disfluency_removal_enabled`, off by default, and hotwords; furthest from the Qwen3-ASR behavior the owner likes |

### Who provides the API

Apps that need no key (ChatGPT, Claude, Wispr Flow, and others) run on a vendor backend paid
by subscriptions. The closest competitor, Moshi, does both: a hosted cloud with 3 free
minutes a month and 60 on Pro, which its [privacy policy](https://getmoshi.app/privacy)
(August 2026) says uses OpenAI, plus a BYOK list behind Pro. Its Cloud requires a registered
push token. [Ramble](https://github.com/Jpoliachik/ramble-ios) is the nearest public blueprint
for a proxy: a stateless Cloudflare Worker with App Attest and StoreKit 2 JWS verification,
no accounts, Apple Speech as the free tier. It has three ratings and no public cost or abuse
data. Spokenly's [iPhone docs](https://spokenly.app/docs/models) list many BYOK vendors, so
the shape exists on the App Store.

| | BYOK | Heeler proxy |
| --- | --- | --- |
| First-use steps | About 8: choose, open site, register, pay or verify, create key, paste, consent, mic | 2: consent, mic |
| Owner's bill | A limited Review key, under $1 a year by estimate | Speech, Workers, tax, refunds, support |
| App changes | Consent, Keychain, HTTP client | All of that plus StoreKit, paywall, restore, quota copy |
| Backend | None | New, with quota counts and a global spending breaker |
| Privacy | Phone to vendor | Spoken prompts pass developer infrastructure, opposite to the Push Relay's stance |
| Mainland China | Direct to a domestic vendor, if reachable | Workers custom domains are best effort, and local hosting needs ICP filing and a Chinese entity |

The money is not the deciding factor. At an assumed 330 minutes a month, a heavy user pays
about $0.15 on DeepInfra and $0.63 on SiliconFlow, plus about $0.33 for cleanup on DeepInfra.
A modeled proxy (5% conversion at $2.99, 200 paid minutes, 15 free minutes, Small Business
commission) nets about $6 a month at 100 voice users, $100 at 1,000, and $1,050 at 10,000. At
2% conversion the same sizes net about -$2, $29, and $337. Those assumptions are ours, not
measurements, and they are too small to pay for operating a paid service.

The abuse risk is documented in adjacent cases only. [Soniox says](https://soniox.com/blog/2025-10-27-free-credits-update-for-soniox-api) fake accounts farmed its $200
free credit. [arXiv 2606.12212](https://arxiv.org/html/2606.12212) found 282 of 444 iOS LLM apps
exploitable, 33% of them through unauthenticated proxies, and only 28% fixed three months after
disclosure. No first-person report of an abused transcription proxy turned up, but logged-in X
search was not available, so that absence proves little. App Attest proves an app instance, not
a user. Its keys are lost on reinstall, so a free tier per device would also need DeviceCheck.

Revisit a proxy only if one of these holds. The thresholds are judgment, not measurement.

- Of 10 or more TestFlight testers with no speech vendor account, fewer than half configure a
  key within 10 minutes, and those who give up blame the key.
- Voice users can reasonably reach about 4,000, or the owner decides to charge for Heeler anyway.
- From a mainland SIM, both presets are unreliable and a custom-domain Worker is stable.

If a proxy ever happens, it is paid and overseas only, with the Apple engine as the free tier
and StoreKit's introductory offer as the trial. Vendors advise against long-lived keys in mobile
clients; under BYOK the exposed key is the user's own, so settings explain that and suggest a
spending limit. Store keys device-only in a separate Keychain service, since
`SecretStore.readAll` walks a whole service. These would be the app's first HTTP calls from Swift
(no `URLSession` exists today) and the first to send user content to a third party; overlay
networks only exchange metadata with theirs.

[VibeTunnel's PR #685](https://github.com/amantus-ai/vibetunnel/pull/685) shows the rough size of a
single-vendor client (`AVAudioRecorder`, multipart upload, Keychain): 462 new lines of Swift and no
dependencies. Heeler needs more, for Composer rules, consent, and the Apple engine.

### Streaming alternatives

Only relevant if evaluation rules out the presets or live text becomes a requirement. Hourly
prices are from vendor pricing pages. "Inside a sentence" means the vendor's documentation says so
explicitly.

| Service | Inside a sentence | Vocabulary | Streaming price | Notes |
| --- | --- | --- | --- | --- |
| ElevenLabs Scribe v2 Realtime | Not stated | 50 terms, 20 chars each | $0.39 | Non-streaming `scribe_v2` had the lowest CoSE-E CER, see below; no Realtime number; `no_verbatim` removes fillers |
| Soniox | Yes, zh to en example | Context | $0.12 | Cheapest explicit option; no Swift SDK |
| AssemblyAI Universal-3.6 Pro Realtime | Yes, includes zh | Keyterms included | $0.45 | Billed by session duration; published 7.20% WER covers European pairs only |
| Deepgram Nova-3 `multi` | Yes, includes zh | Keyterms, +$0.0013/min | $0.55 to $0.63 | zh added 2026-10-23, no independent zh + en data; accepts Opus; needs `mip_opt_out=true` |
| Gemini 3.5 Transcribe Live | Across utterances only; "intra-sentence" is the file model | Up to 1000 | About $0.54 | PCM only; `cmn-Hans-CN` but no `cmn-Hant-TW`; free tier trains; no China or Hong Kong |
| Doubao streaming ASR 2.0 | Language coverage only | Hotwords + context, 100 tokens total | 1 CNY | Now one API key; `enable_ddc` removes disfluency, off by default |

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

### Third-party models on the phone or computer

Out of scope by owner decision. sherpa-onnx, SenseVoice, X-ASR, and WhisperKit were researched in
round one and are not on the roadmap. Foundation Models for cleanup is a system framework, not a
bundled model, and stays a later option.

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
| DeepSeek V4.1 Flash on DeepInfra | Same-key default to test; parameter support on this host is unverified | About $0.00025 at [listed prices](https://api.deepinfra.com/v1/openai/models) |
| Foundation Models (later) | iOS 26+, Apple Intelligence; prompts need retesting on iOS 27; Apple says it may not be suitable for creating code or logical reasoning, while refining or editing text is a listed capability | Free |

`max_tokens` needs a floor for short clips and room for any reasoning tokens. Sampling
is not deterministic on these models, so run each injection case repeatedly. `gpt-5.4-nano`
is deprecated and `gpt-5-nano` shuts down 2026-12-11. Groq's `gpt-oss` documents no way to
turn reasoning off.

**One key for both stages.** DeepInfra and SiliconFlow both list `deepseek-ai/DeepSeek-V4.1-Flash`
alongside `Qwen/Qwen3-ASR-1.7B`, so a preset's key can serve speech and cleanup, removing a second
signup. Whether DeepSeek's `thinking` control and JSON mode carry over to these hosts, and whether
DeepInfra's zero retention label applies to the LLM, still need checking.

**Latency:** Wispr's public budget is [700 ms end to end](https://wisprflow.ai/post/technical-challenges)
on dedicated inference. Whether public BYOK endpoints can come close is unmeasured; the
only public figures use a 10k-token input. The user is already waiting on an upload, so start with
a hard timeout of about 2.5 s (an unmeasured working value; set it from evaluation data) and fall
back to raw.

**Levels:** off, clean (default once configured), and restructure (off by default). Users
disagree on rewriting: some want tidy instructions, others want their own wording.

**Vocabulary:** feed ASR first, since an LLM cannot restore what ASR lost. Limits differ too
much for one shared list, so keep it short and per engine: Voxt uses 8
terms and 220 characters selected by match score. Whether DeepInfra's `initial_prompt` or `prompt`
maps to Qwen's context is unverified, and Alibaba's documents disagree about context on its Flash
models. VibeTunnel attaches a fixed English term prompt, whose effect on mixed Chinese is unknown.
Sources in Heeler include the cwd, Skills, and sent messages. File names and Agent Transcripts are third-party content, and sending them
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
  indicator (2.5.14); Review Notes with a limited test key (2.3.1(a)); no
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

No engine choice is final until this runs. The owner records the corpus and provides the keys.

- **Smoke test first, about half a day:** one real key on each preset. Confirm SiliconFlow serves
  1.7B and honors `language`, accepted formats and file limits, cold starts, and the median time from
  a 15 s clip to its result. Run both presets on an iPhone on a mainland SIM with no proxy; earlier
  probes went through a proxy and prove nothing about direct access.
- **Corpus:** 40 to 60 real sentences recorded on an iPhone, by at least the owner, in quiet and
  noisy settings and with AirPods. Cover zh + en with identifiers, paths, and negations, plus
  self-corrections and its counterexamples, and instruction-shaped sentences. The owner's praise for
  Qwen came from a Hollyland wireless USB mic, so the iPhone mic is the real question.
- **Engines:** both presets with `language=zh` and with it omitted, Alibaba `qwen3-asr-flash` as a
  reference, Scribe v2 as the strongest alternative, Apple zh-CN with both modules, and keyboard
  dictation as the baseline.
- **Metrics:** identifier retention, negation retention, CER, time to final, and retry behavior on a
  weak network.
- **Switch vendors, not the decision, if:** DeepInfra's median for a 15 s clip exceeds about 3 s, or it
  has visible cold starts; the Mac result does not reproduce on hosted 1.7B; or Flash or Scribe clearly
  keeps identifiers and negations better.
- **Cleanup:** 80 to 150 text pairs with repeated runs on injection cases; no injection may pass
  the guard into the draft.

## Delivery order

1. **Smoke test and evaluation** (above). They also test the [UITextInput](https://developer.apple.com/documentation/uikit/uitextinput)
   dictation callbacks on `AgentComposerUITextView`.
2. **In-app capture with both presets:** mic in the terminal and Chat Composers, the first-tap choice,
   consent per vendor, recording indicator, single insertion, retry from the local recording, and a new
   ADR with the PRIVACY.md, CONTEXT.md, and App Privacy updates.
3. **Apple engine** for the no-API path on iOS 26+, labeled single language.
4. **Cleanup:** `VoiceTextPolisher` and its guard, using the preset's key. Polishing was a core request,
   so voice input is not complete until this ships, but it stays a separate slice because its corpus and
   guard are the riskiest layer. It should also offer a Composer action for keyboard dictation and third-
   party input methods. That input is the current selection or whole draft, not speech text. It may
   contain pasted text, Snippets, Skill tokens, and Host paths, so consent copy says the draft is sent, the
   action is disabled while `hasPendingDroppedImages` is true, and the guard also retains paths and Skill
   tokens.
5. **Bilingual settings:** the ordered language list and per-engine strategy. Until then, the primary
   comes from the system language, and only zh + en is promised.
6. **Optional, each behind evidence:** streaming with partials, vocabulary, Foundation Models cleanup
   (the Chinese rollout in 27.3 is announced, but third-party framework access is unknown), custom
   endpoints, and a proxy.

## Not verified

- Any vendor call with a real key, so all latency and accuracy statements remain documentation or model
  cards.
- Connectivity from mainland China for any vendor, and from overseas to SiliconFlow and Alibaba Beijing.
- Whether non-mainland identities can open SiliconFlow, Doubao, or Bailian accounts, and whether DeepInfra
  accepts Chinese-issued cards.
- Any engine's accuracy on Heeler-style speech. No official or independent same-sentence zh + en ASR data
  exists for Qwen3-ASR.
- All usage, conversion, and proxy numbers, which are our assumptions.
- Two concurrent recognizers on an iPhone, and microphone behavior with two foreground iPad apps.
- OpenAI usage terms and Codex help pages (HTTP 403 during checking).
- The legal reading of Anthropic's terms for Host CLI use, which is our interpretation.
