# Composer Staging Store

Status: Proposed for review

## Decision

Replace the production-unreachable Composer-less image staging route and the
parallel `ImageAttachStore` and `FileAttachStore` workflows with one deep
`ComposerStagingStore` module.

`AgentAttachStore` owns and lifecycle-coordinates the module. The Agent detail
View uses it through `attach.staging`, without media-specific forwarding
methods. This is a bounded ownership compromise: Attach remains display-only
under ADR 0013, while the staging module is nested there solely because that
owner already serializes false-disappear recovery, staging cancellation, and
terminal teardown. Renaming the owner or adding an Agent-detail aggregate is a
separate architecture change.

The design keeps `Transport.stageImage(_:)` and `Transport.stageFile(_:)` as
two typed operations. Their shared SFTP implementation is already deep enough;
merging them would erase useful domain types without removing a caller burden.

## Evidence and rejected seams

The only production construction of `AgentTerminalView` comes from
`AgentDetailView`, and it always supplies an `AgentComposerStore`. The optional
Composer and terminal insertion route are therefore compatibility code without
a production adapter.

Three ownership seams were considered:

1. A child of `AgentAttachStore`. Chosen. The owner survives terminal-child
   replacement and already orders staging shutdown before terminal shutdown.
2. A sibling in `AgentDetailView`. Rejected. It has exactly the same lifetime
   as the attach owner, gains no reconnect persistence, and would duplicate or
   weaken the existing lifecycle guard.
3. A store cached above the detail branch. Rejected. It would make an upload
   survive the reconnect placeholder, a new product behavior with no current
   requirement and no resume contract.

The selected seam passes the deletion test: the old stores, the legacy terminal
destination, and all paired staging forwards can be removed without a
compatibility wrapper. The remaining module boundary carries the real workflow
invariants used by both image and file adapters.

## Interface

The intended source-level shape is:

```swift
@MainActor
@Observable
final class ComposerStagingStore {
    private(set) var state: State
    var canBegin: Bool { !state.isBusy }
    var presentation: Presentation? { presentation(for: state) }

    func begin(_ source: Source)
    func perform(_ command: Command)
    func didEnterBackground()
    func leave() async

    enum Source {
        case photo(any ImageSelection)
        case file(URL)
    }

    enum Command: Hashable {
        case cancel
        case retry
        case copyPath
        case dismiss
    }

    enum State: Equatable {
        case idle
        case preparing(Medium)
        case uploading(Medium, AttachmentStageProgress)
        case failed(Failure)
        case backgroundInterrupted(Failure)
        case completed(Outcome)
    }

    enum Medium: Equatable {
        case image
        case file
    }

    struct Failure: Equatable {
        let medium: Medium
        let message: String
        let isRetryable: Bool
    }

    struct Outcome: Equatable {
        let medium: Medium
        let path: String
        var copied: Bool
    }

    struct Presentation: Equatable {
        let icon: String
        let title: String
        let accessibilityLabel: String
        let commands: [Command]
    }
}
```

`presentation` is a pure projection of `state`. It owns action availability so
the View does not duplicate retryability, copy recovery, or busy-state rules.
The module does not throw across its View interface; preparation and staging
errors become explicit states.

The Composer dependency is strong and non-optional. During a live detail view,
`AgentDetailView` strongly retains the Composer in `@State`, giving it exactly
the lifetime required by staging. `ConsoleStore` is an additional owner whose
cache is pruned when a Host leaves the catalog. The Composer has no reference
back to staging, so this creates no cycle. A completed outcome therefore means
the Host path has already been inserted into the draft. The old `inserted` flag
and `Insert Path` recovery action represented a production-unreachable
weak-reference failure and are removed. Clipboard copy remains fallible and
retains an explicit `Copy Path` recovery action.

## Invariants

1. There is one operation slot across both media. A begin request while busy is
   ignored and is not queued.
2. Beginning a new selection from a result or failure state first discards the
   prior retained local preparation and presentation.
3. An operation identifier rejects progress and completion from superseded
   tasks. It is an implementation detail, not interface state.
4. The module deletes only app-created local prepared files. It never deletes a
   completed Host file, per ADR 0005.
5. A retryable failure retains its prepared local file. A non-retryable failure
   deletes it.
6. Background interruption never retries implicitly on foregrounding. The user
   may retry explicitly when the local preparation remains available.
7. Successful staging copies the path when possible and always appends the path
   plus a trailing space to the Composer draft. It never submits the draft.
8. `leave()` is idempotent. It cancels and awaits an in-flight task, deletes its
   local preparation, and returns to idle.
9. `AgentAttachStore.leave()` retains its synchronous false-disappear guard and
   serialized order: `staging.leave()` completes before `terminal.stop()`.
10. Replacing the terminal child does not replace staging. Leaving the detail
    screen does; uploads are not persisted across a reconnect placeholder.

The state sequence is:

```text
begin -> preparing -> uploading -> completed | failed | backgroundInterrupted
```

`retry` is valid only for a retryable failure or background interruption,
`copyPath` only for a completed outcome whose initial copy failed, `cancel`
only while busy, and `dismiss` only while not busy.

## Adapter and naming boundaries

Image and file preparation remain medium-specific adapters. The workflow
normalizes their prepared source, progress reporting, staging closure, error
classification, clipboard action, and Composer insertion behind private
implementation types. There is no public medium registry or type-erased
extension point. A third medium can justify another internal adapter when it
exists; it does not justify interface cost now.

Mechanism types shared by both media receive neutral names:

| Current | Proposed |
| --- | --- |
| `ImageStageProgress` | `AttachmentStageProgress` |
| `ImageStageProgressReporter` | `AttachmentStageProgressReporter` |
| `ImageStagingError` | `AttachmentStagingError` |
| `ImageClipboard` | `AttachmentClipboard` |
| `invalidPreparedImage` | `invalidPreparedSource` |

The domain operations and results remain medium-specific:
`Transport.stageImage(_:)`, `Transport.stageFile(_:)`, `StagedImage`, and
`StagedFile` do not change. This separates neutral implementation mechanisms
from the two domain results and keeps Transport behavior, concurrency, retry,
and error semantics unchanged.

## Test migration

The current staging baseline is 16 tests: 14 in `ImageAttachStoreTests` and two
staging happy paths in `ComposerAttachmentTests`.

- Delete three tests whose only invariant is the unreachable terminal
  destination: generation-matched insertion, pausing terminal input, and
  explicit insertion into the current live session.
- Merge the test where both post-stage actions fail into the existing recovery
  test. Composer insertion is constructionally available, leaving clipboard
  copy as the sole recoverable post-stage failure.
- Migrate the remaining ten workflow tests and parameterize each across image
  and file, producing 20 cases.
- Add two cross-media cases: a file begin is ignored while an image is active,
  and a new begin clears a prior presented result.
- Remove the two superseded Composer staging happy paths while retaining the
  unrelated link-presentation test.
- Add `stageFile` and `configureFileStaging` to `ScriptedTransport`; file staging
  currently lacks the scripted adapter required for symmetric unit coverage.

The result is 22 staging-specific cases with symmetric media coverage.
`AgentSurfaceReplacementTests` keeps its eight production SwiftUI seam cases,
but their fixtures must move to the production configuration: six currently
construct a Composer-less detail and must receive the required Composer, while
direct `owner.selectImage` and `owner.imageState` calls move to
`owner.staging`. These fixture changes do not count toward the 22 staging cases.
`ImageStagingE2ETests` remains the real-SSH SFTP check and changes only for
mechanical type renames.

## Implementation sequence

Each step must leave the relevant checks passing and must replace rather than
layer compatibility wrappers:

1. Rename the shared staging mechanism types without changing behavior.
2. Remove the Composer-less image route and its three terminal-only tests.
3. Add scripted file staging support to the Transport test double.
4. Introduce `ComposerStagingStore`, replace both old stores in one change, and
   migrate the staging suite to 22 cases.
5. Regenerate and commit `Heeler.xcodeproj` for source moves, then update domain
   and architecture documentation.

## Documentation changes

- `CONTEXT.md` replaces obsolete **Attach Image** with the Composer action
  **Add**, adds **Staged File**, and deliberately does not add a **Staged
  Attachment** umbrella term.
- ADR 0006 names the unified workflow and records why its display-only Attach
  owner coordinates the lifecycle.
- ADR 0005 and ADR 0013 remain unchanged and authoritative.
- No changelog entry is needed because the removed route is production
  unreachable and the rest is an internal refactor.

## Non-goals

- No changes to Transport method shape or behavior.
- No unification of `StagedImage` and `StagedFile`.
- No third-medium registry or generalized attachment framework.
- No rename of `AgentAttachStore` and no Agent-detail aggregate.
- No staging persistence across the missing-Agent reconnect placeholder.
- No Host-side cleanup or upload resume contract.
- No terminal keyboard, Composer delivery, or SSH package changes.
- No rewrite of the historical `docs/research/image-input.md`; its superseded
  action and insertion route are marked at the top of that record.

## Review frontier

Codex and Claude Code agree on this version. User review should focus on the
only material product simplification beyond structural refactoring: a live
Composer is made a required dependency, so path insertion is guaranteed and
the unreachable `Insert Path` recovery button is removed. Reverting that choice
is bounded to making the dependency weak again, restoring one command and one
outcome flag, and adding two recovery cases; it does not change the selected
module seam.
