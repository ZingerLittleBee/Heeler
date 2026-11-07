# Claude Code model options for an existing terminal

Observed on 2026-11-07 for PR #647. The initial investigation and Linux
mapping experiment are followed by the former native-menu adapter and
its verification below. That adapter has since been removed.

## Current product decision

The owner chose fixed Opus, Sonnet, Haiku and Fable shortcuts instead of
discovering the running session's choices. The native menu opens locally;
opening or dismissing it sends no terminal command. Selecting a shortcut
sends `/model <alias>`, using Claude Code's normal resolution and persistence.
Third-party users configure `ANTHROPIC_DEFAULT_<FAMILY>_MODEL` themselves;
Heeler neither inspects nor writes those mappings, and does not certify that
the provider can serve a shortcut. The displayed model still comes from the
transcript, welcome banner or a confirmed command response. An unknown custom
model is not guessed to belong to a particular alias.

Unlike the removed adapter's `s` action, a direct `/model <alias>` also saves
Claude Code's user default. This follows the standard CLI command, not a
session-only API. The research and dynamic-menu measurements below describe
the superseded implementation, not the current menu's behavior.

### Fixed-menu verification

Candidate: the uncommitted `fix/pr647-centered-dialog` worktree on
`685ca26edc331b5d1810473574eb035e98790c28`, tested on 2026-11-07.
`make test-app` ran all 79 tests in `AgentSessionSettingsTests` and
`AgentComposerStoreTests`, with zero skips. `make check-test-membership`
passed for 433 sources, and `make sim-id` installed the candidate on the
iOS 27.0 Simulator `B5748333-61F7-4E7E-8212-B9CFE4BC5B89`.

On the existing Linux session, three menu openings took 0.336, 0.243 and
0.254 seconds (median 0.254), versus two successful dynamic-menu openings
of 20.477 and 21.185 seconds. These timings include accessibility polling;
they are Simulator measurements, not physical-device measurements.
Opening the fixed menu left the terminal history unchanged. A separate
isolated Linux fixture's transcript hash also stayed unchanged across
three openings, with no additional `/model` record.

The fixture used real Claude Code 2.1.318 and herdr-core, a disposable HOME,
dummy authentication and a loopback request recorder. Selecting Sonnet
through the native menu sent `/model sonnet`; the next request carried the
configured `probe/small-model` instead of `openai/gpt-5.6-luna`. On the final
candidate, selecting Fable produced Claude's confirmation and the status
label `Fable 5.1 · high`, without its persistence notice. The reopened menu
showed Fable and high checkmarks in separate leading columns. Screenshots
were inspected for alignment and clipping. The first fixture run was
discarded because recorder output polluted its TTY; the successful fixture
redirected that output to its own log.

This verifies command delivery, alias resolution against the test endpoint,
and native presentation. It does not establish availability or billing for
any real provider. Official subscription, Windows and physical-device
behavior were not retested for this candidate.

## Result

Claude Code has a runtime model-catalog control request, `list_models`, but
this investigation did not establish a supported connection from Heeler to
that protocol on an arbitrary existing interactive terminal. The Agent SDK's
`supportedModels()` is not an attach-by-session-ID API.

Opening the existing Agent's `/model` picker is a verified way to inspect
what that process offers. Its options are not a guarantee that a third-party
provider can serve every listed model. A terminal-menu adapter must preserve
this distinction rather than claim to discover provider availability.

## Sources and scope

| Source | Version and evidence |
| --- | --- |
| Local Claude Code native binary | 2.1.319, arm64, 321,995,200 bytes, SHA-256 `1f53587e92dee8e089fa349188a4cda64fa34ace6e7b0ca2ee278ddaa3cc2ebd`; static embedded-JavaScript inspection |
| Existing Linux Agent | Claude Code 2.1.318, herdr-core 0.1.18; live `/model` menu opened, browsed with Down, and dismissed with Esc |
| [Agent SDK TypeScript reference](https://code.claude.com/docs/en/agent-sdk/typescript) | `supportedModels()`, `initializationResult()`, `reinitialize()`, `ModelInfo` |
| [Model configuration](https://code.claude.com/docs/en/model-config) | Aliases, restrictions, gateway overrides, and session-only versus persistent selection |
| [Gateway model discovery](https://code.claude.com/docs/en/llm-gateway-protocol#model-discovery) | Opt-in discovery, filtering, caching, and built-in options |

Binary offsets below are zero-based decimal byte offsets in the original
2.1.319 executable. Minified identifiers are version-specific observations,
not a public integration contract. Credentials, private keys and settings
contents of existing user sessions were not read. The initial menu/source
investigation made no inference request or model selection. The later
isolated Linux experiment below exercised both against a loopback recorder.

## Runtime catalog and picker are related, not identical

The common catalog builder is `cGe` at byte 264920380, in embedded module
`/$bunfs/root/chunk-rzpdyy5a.js`. It applies policy, eligibility, billing,
custom entries and disabled-row handling. `ise` at 264918883 explicitly
filters `!n.disabled`; displayed rows and selectable rows are different.

The TUI wrapper `ILn` at 264919660 feeds the actual picker `V$e` at
299477886. That picker can additionally insert Current model or Base model
rows not in the base catalog (299479105), and handles search and More models.
It refuses selection when `Yn.disabled === true` (299481401).

`list_models` has a control-protocol schema at 262203418. The handler at
289356077 returns `{models:C_e(cGe())}`; the dispatch table at 289370514
connects it to that request. Its schema explicitly includes disabled rows.
It reconstructs the process's catalog, not necessarily a fresh provider
discovery response.

Claude's own thin client sends this request at 309343651, uses it when
opening the picker at 309351398, and checks `modelCatalog` capability and a
control channel at 309362980. That transport is not Heeler's existing SSH
connection to herdr. No such control request was sent in the live test.

## SDK initialization is not an arbitrary TTY query

The embedded SDK implementation at 288619433 is:

```js
async supportedModels() { return (await this.initialization).models }
```

It reads the initial snapshot rather than issuing `list_models`. The worker
at 290243970 separates selectable `models` from unavailable entries;
initialize at 290442364 serializes them. The schema at 262153601 preserves
selectable-only `models` and limits `unavailable_models` to certain hosts.
Not every control transport supplies the same data: one Remote Control
bridge initialize path at 267287555 returns `models: [], account: {}`.

`reinitialize()` at 288619258 resends initialization, including other
initialization parameters; it is not a dedicated, side-effect-free model
query. The SDK's process transport constructs stream-JSON input/output and
`--resume` arguments before spawning a process (288576349, 288576394,
288577624). Resuming a transcript in another process does not establish the
original TTY's current model catalog.

No public file export or CLI list command equivalent to an arbitrary live
TTY's picker was found within this investigation. This is a bounded finding,
not proof that no private connection can exist. Private sockets were not
connected to, and no session was restarted or converted to SDK mode.

## IDs, current selection, effort and billing

`C_e` at 264930396 serializes `value`, `resolvedModel`, `displayName`,
`description`, optional `disabled`, and model capabilities. `value` can be
`default`, an alias, or a concrete ID. `resolvedModel` applies the running
process's alias/default resolution, including environment overrides and
context suffixes (`Vt`, 263088786).

`default` is a selectable default rule, not the current selection.
`ModelInfo` has no selected marker. An internal `current_model` initialize
field has a separate meaning (schema at 262154117).

The official SDK reference also documents `supportsEffort`,
`supportedEffortLevels`, `supportsAdaptiveThinking`, `supportsFastMode` and
`supportsAutoMode`. Do not substitute a universal list of effort levels for
these capabilities. The TUI's effort builder `m5` at 299485960 has further
runtime/default constraints, so catalog capabilities alone do not establish
the selected effort.

Billing handling in `cw` at 264932090 can produce `Fable (disabled)` and
credit-related explanations. Selectable is not synonymous with included in
the subscription, free, or guaranteed to have sufficient balance.

## Live third-party endpoint observation

The existing Linux Agent used `openai/gpt-5.6-luna` with custom endpoint
configuration. Whitelisted environment observations had established that
the Opus, Sonnet and Haiku defaults all mapped to that same ID. The endpoint
and authentication values are intentionally not recorded here.

The 44-column, 24-row native menu contained five numbered entries:

| Position | Observed label and description |
| --- | --- |
| 1 | Default, with description resolving to `openai/gpt-5.6-luna[1m]` |
| 2 | `openai/gpt-5.6-luna`, checked; Custom Opus model |
| 3 | Fable; Fable 5.1, with per-token pricing |
| 4 | `openai/gpt-5.6-luna`; Custom Sonnet model |
| 5 | `openai/gpt-5.6-luna`; Custom Haiku model |

Several labels were truncated at this width, and descriptions wrapped across
many lines. Moving Down from the fifth entry returned to the first. The
focus cursor moved independently of the checked current model. These are
concrete obstacles to treating one text screen as a complete catalog or
treating a display label as a unique command value.

Fable was listed without a disabled label; whether the configured provider
would serve it was not tested. The menu therefore cannot justify claiming
that this endpoint supports Fable. Duplicate Luna labels also cannot justify
inventing distinct Opus, Sonnet and Haiku backend models.

The probe used `herdr-core send --if idle t1 /model`, screen reads, Down
keys, and Esc. It never pressed Enter to select a model or changed effort.
After cancellation Claude printed `Kept model as openai/gpt-5.6-luna`;
the Agent retained its PID, Idle state, turn 0 and empty input box. Both
user settings files checked before and after remained absent. Opening the
menu did leave its ordinary command/cancellation echo, so this is terminal
interaction, not an invisible read-only query.

## Why gateway files do not solve this generically

Official discovery requires `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`
(off by default), requests `/v1/models?limit=1000`, and filters IDs to those
containing `claude` or `anthropic`. This does not discover
`openai/gpt-5.6-luna`. Built-in options may remain unless configured away;
policy restrictions and custom picker settings still apply.

The gateway cache at `~/.claude/cache/gateway-models.json` (or the configured
Claude root) is only an input. In 2.1.319, `NZe` at 263025952 checks the
feature/provider/base URL but does not reject a matched cache based on
`fetchedAt`. `model-capabilities.json` holds capability data, while
`model-access.json` holds provider access observations; neither exports the
current TTY's picker. Reading these caches cannot prove a current,
credential-scoped provider inventory.

## Implications for Heeler

The working PR integration currently hard-codes four aliases in
`AgentSessionSettings.modelChoices`, and stores the selected alias as an
override after `/model <alias>` succeeds. It does not consume a live catalog
or preserve a custom alias's resolved model. A green app test suite does not
validate those assumptions for third-party endpoints.

The smallest supported experience is to make the model control open this
Agent's native `/model` picker through the existing Terminal surface, after
the existing session, idle and empty-input checks. Official-subscription
users retain model switching through Claude's own menu. No fixed fallback
catalog or provider-availability claim is needed. This is a proposal only.

A native iOS projection of that menu is possible in principle, but requires
a separately verified versioned adapter: complete scrolling, truncated and
duplicate labels, disabled/current/base rows, stable live menu identity,
input ownership across clients, and safe refusal on unknown shapes. A
selection must target the observed menu, not rebuild `/model` commands from
display text. Reusing the Terminal surface avoids promising this adapter
before it has been built and tested.

If a future integration owns a supported Claude control connection, prefer
capability-gated `list_models`, retaining disabled rows, descriptions,
`value` and `resolvedModel` separately. That would require a new transport
contract; it is not a small replacement for an SSH file read.

Provider-guaranteed choices require a provider-specific authoritative catalog
under the same account and policy. Even then availability can change before
inference. No generic third-party availability guarantee was established.

Finally, model selection has persistence semantics: official documentation
says `/model <name>` and normal picker Enter save the default for future
sessions; the picker offers a session-only action (default key `s`, which can
be rebound). A future Heeler implementation must not silently call a
persistent operation a current-session-only change.

## Executed Linux alias-mapping experiment

The subsequent verification ran entirely on `herdr-linux-test`, using its
installed Claude Code 2.1.318 executable, SHA-256
`708c77b204db30086ff6f1ed34577bda03e1be74ced80557cbf7b54249ebf0bd`.
No model test ran on the local Mac.

Four fresh interactive TTY processes used separate temporary HOME,
CLAUDE_CONFIG_DIR and empty project directories. The environment was built
from an allowlist, with a dummy API key and ANTHROPIC_BASE_URL pointing to a
Python HTTP recorder in the same VM. A Linux network namespace had only the
loopback interface and no route to external providers. Neither `--bare` nor
`--safe-mode` was used. Tools and MCP servers were disabled; no existing
session was resumed or controlled.

Each process started with `ANTHROPIC_MODEL=openai/gpt-5.6-luna`. After an
initial prompt, the probe submitted `/model opus`, `/model sonnet`,
`/model haiku` and `/model fable` through the actual terminal, confirmed the
cache-change dialog when present, and submitted one prompt after each
switch. The recorder captured the actual outgoing JSON `model` field and
returned a fixed Anthropic-compatible streaming response. It did not perform
alias resolution itself.

The final run executed:

```sh
sudo -n unshare --net -- sh -c 'ip link set lo up; exec runuser -u boxd -- python3 /tmp/heeler-model-mapping.7kKjwh/probe.py --binary /home/boxd/.local/share/claude/versions/2.1.318 --output /tmp/heeler-model-mapping.7kKjwh/matrix-1'
```

Twenty distinct case/selection pairs matched twenty recorded streaming
Messages requests. Every initial request used `openai/gpt-5.6-luna`.
The remaining sixteen requests were:

| Configuration | After `/model opus` | After `/model sonnet` | After `/model haiku` | After `/model fable` |
| --- | --- | --- | --- | --- |
| Only ANTHROPIC_MODEL | `claude-opus-5-5` | `claude-sonnet-5-5` | `claude-haiku-5-5` | `claude-fable-5-1` |
| Opus, Sonnet and Haiku defaults set to Luna | Luna | Luna | Luna | `claude-fable-5-1` |
| All four defaults set to Luna | Luna | Luna | Luna | Luna |
| Four distinct default overrides | `probe/large-model` | `probe/mid-model` | `probe/small-model` | `probe/other-model` |

Here Luna abbreviates the literal request ID `openai/gpt-5.6-luna`. Defaults
mean `ANTHROPIC_DEFAULT_<ALIAS>_MODEL`, not just ANTHROPIC_MODEL. The distinct
overrides are the control: they show that requests follow each alias's own
mapping rather than always using the startup model or always using Claude
IDs. These synthetic IDs are not claims about real provider inventories.

All four temporary user settings files ended with `model: "fable"`, also
confirming that these `/model` switches persisted the alias. The authoritative
model evidence is the captured HTTP body, not a terminal label: an ANSI
redraw can repeat an older confirmation line in a linear output log.

Initial harness attempts were discarded: SFTP was unavailable, so the script
was transferred over SSH stdin; terminal output encoded spaces as cursor
positions, and startup required accepting the dummy key; a later attempt
stopped at the cache-change confirmation. The complete matrix ran only after
handling those known test-setup states. None of the discarded attempts was
counted among the twenty complete cases.

Evidence is retained under `.amp/in/artifacts/`: `model-mapping-linux-matrix.log`,
`model-mapping-linux-validation.log`, and `model-mapping-linux-evidence.tar.gz`
(recorder, raw requests/results, and terminal captures). The temporary
processes were stopped, and the original Agent PID 5310 and start time were
unchanged. The working fixture directories are disposable and are removed
after collecting the evidence.

This proves that the tested Claude Code does not collapse all aliases onto
ANTHROPIC_MODEL when given a custom endpoint. It does not test a real
provider's downstream routing or model availability: no request left the
namespace and no paid inference was invoked.

## Not verified

- A live official-subscription picker or its billing restrictions.
- A real provider response after a switch, or any effort change.
- A live `list_models` exchange, private socket attach or remote-control setup.
- Complete parsing of arbitrary widths, custom entries or future versions.
- Whether every menu entry on the Linux provider is actually callable.

The investigation itself changed no product source. The subsequent native
adapter is described below; earlier working-tree changes and local main
merges were preserved.

## Native menu implementation

The requested UI remains native: `AgentModelMenuButton` uses an uncached
`UIDeferredMenuElement` and single-selection `UIMenu` sections. UIKit supplies
the loading state, scrolling and separate leading checkmark column. Model
titles and subtitles come from the current TTY, not a fixed alias list.
The model label keeps the requested `#87BAB3` tint.

`ClaudeModelMenu.Visit` opens `/model` only over an empty idle prompt and
walks the numbered picker until its focus returns to the first row. It
closes the picker before completing the native menu. Duplicate labels retain
their separate row numbers and descriptions. Selecting opens and checks the
catalog again, then targets the observed row with the footer's advertised
session-only key. It does not construct `/model <display name>` and does not
use the persistent Enter action. Unknown syntax, an incomplete cycle or a
changed catalog stops the operation, never falling back to fixed aliases.
Loading failures offer Open Terminal; selection failures report the refusal.

The shared Composer session owns the setting-operation lock. Process identity
includes the start time; the view also checks its conversation generation.
The core's checked typing rechecks the foreground holder and fresh screen for
each key. Herdr TUI Hosts perform a screen and process read before each key.
Unanswered input is neither repeated nor followed by a blind Escape. A model
label changes only after the terminal confirms it; the session-only suffix
is not part of the model name.

This is terminal interaction, not a side-effect-free catalog API. Loading can
take several network round trips and adds `/model` / Kept model entries to
Claude's transcript. Other terminal clients can see the picker briefly.
It mirrors what Claude offers, including a built-in model such as Fable on a
custom endpoint, rather than certifying the provider can serve that model.
Effort remains the existing fixed choices; it is not dynamically discovered.

## Native menu verification

The iOS 27.0 Simulator `B5748333-61F7-4E7E-8212-B9CFE4BC5B89` connected over
SSH to `herdr-linux-test` (Claude Code 2.1.318, herdr-core 0.1.18). No Claude
process was run on the local Mac. The original Linux session's five model
rows appeared in the native menu, including three Luna names with different
Custom Opus / Sonnet / Haiku subtitles. Dismissing it left the terminal's
input empty and its model unchanged.

A disposable Linux session used an isolated HOME/config/project, dummy
authentication and a loopback HTTP recorder. Its Sonnet alias resolved to
`probe/small-model`, while Opus and Haiku resolved to Luna. Unlike the earlier
alias-mapping experiment, this UI fixture was not network-namespace isolated.
It used no real provider credentials and its model requests reached the
loopback recorder, not a paid service.

Selecting the distinct custom model through the actual native menu produced
`Set model to probe/small-model for this session only` in the terminal. The
next streaming Messages request carried `model: "probe/small-model"`, versus
`openai/gpt-5.6-luna` before selection. Reopening showed its new checkmark.
The temporary `settings.json` remained absent. This establishes UI-to-TTY-to-
request selection and session-only persistence, not real-provider availability.

Live testing caught two argument-hint paint variants: truecolor gray and
indexed gray 246. The initial version stopped at its own unsubmitted `/model `
instead of pressing Enter over unrecognized text. Both are now covered by
the command-hint regression, alongside rejection of an actual typed argument.
Temporary test launches that stripped `HC_SCOPE` could not bind Chat; those
were discarded and replaced by a launch preserving its core-provided scope.

Evidence under `.amp/in/artifacts/` includes the native menu screenshots,
`model-menu-linux-selection.log` (outgoing model fields and absent settings),
and focused `make test-app` / `make sim-id` logs. The kept tests replay the
captured Linux picker and exercise loading/cancellation, duplicate names,
changed catalogs, process replacement, existing drafts, unknown syntax,
disabled rows, session-only selection and unanswered-key refusal. These
fixtures do not establish compatibility with arbitrary future Claude menus.

The final uncommitted candidate on `fix/pr647-centered-dialog` passed
`make test-app` with `AgentSessionSettingsTests`, `ClaudeModelMenuTests` and
`AgentComposerStoreTests`: 88 executed, zero skipped, three selectors verified
(`model-menu-tests-final-clean.log`). `make sim-id` installed that candidate;
`make check-test-membership` and `git diff --check` also passed. Two incremental
test builds hit a stale `CLibSSH2` PCM / missing `CHeelerSSHSupport` cache error;
removing only this task's disposable Build and ModuleCache directories and
rebuilding resolved it without changing the source or weakening checks.

On the final build, a native menu load completed in 22.1 seconds on this
connection. A later selection was confirmed 17.0 seconds into the remote
observer's wait (which started after the tap, so not total tap latency).
`model-menu-final-selection.log` records the subsequent request model and
absent settings file. A separate live test left `keep` in the terminal's
input: opening the native menu refused and preserved that draft without
submitting it. After clearing only this test draft, the menu recovered.

The disposable TTY sessions, recorder and temporary HOME/config/project were
removed after collecting evidence. The original Linux Claude PID 5310 was
preserved, and its native menu was left open in the installed Simulator for
review. No commit, push, release or deployment was performed.
