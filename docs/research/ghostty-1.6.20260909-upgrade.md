# Ghostty 1.6.20260909 upgrade

PR #298 is integrated on top of main `ce790d8f38cfa160e249bf56ffebf16b3cfc8ac1`,
which includes PR #302. The keyboard views, layout, height tracking, modifier
interaction, press feedback, and Backspace repeat implementation come from #302.

## Dependency audit

- Repository: https://github.com/Lakr233/libghostty-spm
- Release: `1.6.20260909`
- Wrapper commit: `7e45d27160f9b34aca9ca5c9820e9207482f9f04`
- Native Ghostty commit: `82938b633ba646db38591d969c3c526332bd7e65`
- XCFramework archive SHA-256:
  `2d9a26e80c3836c450f03ea2cf9d191841d9093d4f61c1cea466d2fc8e215dbb`

The downloaded release archive matches the SwiftPM manifest checksum and GitHub
asset digest. Its 19 files match the resolved artifact byte for byte. The archive
contains iOS arm64 and iOS Simulator arm64/x86_64 slices. This verifies artifact
identity, not reproducibility of the native build.

Swift sources were reviewed against the previous pin
`356f730bec03281fc7b83666a129b0246137ea26`. Besides the public input API, the update
changes rendering, viewport extraction, clipboard handling, hardware-key routing,
and software-keyboard lifecycle. It is not an API-only wrapper update.

## Input boundary

`HeelerTerminalView` maps existing keyboard actions to `TerminalKeyPress` and
calls public `sendKey`. Ghostty owns cursor-mode and keyboard-protocol encoding,
including paired press/release events. Transport still receives session bytes.
The app-owned encoder and obsolete `TerminalControlKey` interface are removed.

Heeler retains the existing one-shot UI modifiers. They are consumed only when
Ghostty accepts a key; Ghostty's sticky modifier state is not also armed. Composer
quick keys still bypass the draft, while Shell keys retain the local-input gate.
The explicit multiline action remains Ctrl-J (LF in the default encoding).

Ghostty's default fixterms encoding distinguishes Ctrl-I from Tab, Ctrl-M from
Enter, Ctrl-[ from Escape, and Ctrl+Shift combinations from Ctrl alone. These
are intentional changes from the old byte encoder, verified through the pinned
surface's output. See the [upstream explanation of fixterms](https://github.com/ghostty-org/ghostty/discussions/5071).

Desktop bindings are cleared so they cannot intercept remote keys. Font and zoom
updates preserve that configuration. UIKit/Heeler continue to own local paste,
selection, and zoom. The DEC mode tracker remains for touch scrolling and paste
routing; custom keyboard encoding no longer consults it.

## Verification

Hosted surface tests cover default and application cursor modes, Ctrl/Alt/Shift,
US characters and symbols, F1-F12, multiline input, one-shot state, disabled-input
gates, repeated Backspace, appearance changes, and Kitty press/release reporting.
Existing layout and touch tests exercise the unchanged #302 controls.

Final app-suite command (2026-09-12):

```sh
make test-app \
  SIM_DESTINATION='platform=iOS Simulator,id=416FD970-AC18-46F9-AAC9-E37115E8CBC8' \
  TEST_FLAGS='-clonedSourcePackagesDirPath .ci/source-packages -disableAutomaticPackageResolution -skipPackageUpdates -parallel-testing-enabled NO -collect-test-diagnostics never'
```

The final simulator rerun on source commit `c86be45` reports **1,487 passed,
116 skipped by existing suite conditions, and zero failures** (1,603 total).
`make test-app` exited successfully. The result bundle is
`Test-Heeler-2026.09.12_21-39-06-+0800.xcresult` in the worktree's
`build/DerivedData/Logs/Test/` directory.

The initial run had one failure in
`AgentDirectInputTests.composerAndDirectInputTransferVisibleKeyboardWithoutReloading`,
which timed out waiting for a visible software keyboard. The rerun passed this
unchanged test after configuring the Simulator for software-keyboard testing.
Connect Hardware Keyboard was temporarily disabled with user permission and
restored to enabled afterward. No application-code change or weaker assertion
was needed.

Manual checks on the iPhone 17 Pro, iOS 27.0 Simulator also verified:

- Entering Agent detail did not open a keyboard over the toolbar.
- Compose's Agent/Terminal pages switched with a horizontal swipe. In the tested
  portrait layout, the tools dock and system keyboard had aligned top edges.
- Shift+A typed uppercase A remotely and consumed Shift. Alt could be armed and
  cancelled. Ctrl+U cleared the remote input while the Compose draft stayed empty.
- The Fn layer exposed F1-F12. Direct Input exposed only the Terminal keyboard,
  with Skills and Snippets tabs still available.
- Open Terminal connected to a shell and used the same full keyboard. Its Text
  and Keys modes also kept their top edges aligned in the tested portrait layout.

Backspace hold/release, small finger drift, delayed UIKit control events, and
view updates passed the hosted automated touch tests. Manual CUA drag actions
were not used as proof of a sustained hold because they expose no hold duration.
Physical-device behavior, haptic strength, and hardware Cmd+C/V were not exercised
in this run. No real-SSH test evidence is claimed from the skipped suites.
