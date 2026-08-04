# Attach Image Design Review

Date: 2026-07-23

> **Superseded in part, 2026-08-04.** The SSH backend named throughout this
> review no longer exists. ADR 0011 replaced Citadel, NIOSSH, and SwiftNIO with
> the repository-local `HeelerSSH` package (libssh2 + OpenSSL), and image
> staging now runs over that package's SFTP client. The design conclusions below
> — remote path, SFTP rather than the PTY, `Transport` as the boundary, shared
> channel budget — all still hold; only the named dependency changed. Statements
> about Citadel are kept as the record of what was true on 2026-07-23 and are
> marked where they are now historical.

## Decision

Image input is feasible without changing Attach into a file-transfer protocol.
The single-image MVP will:

1. Select one image with `PhotosPicker`.
2. Decode and normalize it in app-owned temporary storage.
3. Stage the result in the Host operating system's temporary storage over SFTP.
4. Copy the remote absolute path to the iOS clipboard.
5. Insert the path into the same live Attach input stream used by the terminal,
   followed by a separately inserted space and no Enter.

The image bytes never enter the PTY. Heeler guarantees that a Staged Image
exists and that its path is copied and/or inserted. It does not guarantee that a
remote Agent or model interprets the path as an Image Attachment.

The user-facing action remains `Attach Image`. This label describes user intent,
not a stronger success claim. Result messages describe the path operations that
actually completed.

## Why the path must be remote

The selected photo initially exists only within the iOS app's scoped access.
The Agent runs on a remote Host and cannot read the phone's Photos library,
local file URLs, or clipboard. The app must transfer the binary to that Host
before inserting a usable path.

The PTY is an ordered terminal byte stream, not a file-transfer envelope.
Writing PNG or JPEG bytes to it would turn arbitrary binary data into terminal
input and control sequences. SFTP provides file framing, streamed writes,
progress, cancellation, permissions, and completion semantics without mixing
binary transfer with terminal input.

## Current system findings

- `Transport` is already the boundary between UI code and the SSH backend
  (Citadel at the time of writing; `HeelerSSH` since ADR 0011). The image
  feature should extend that boundary rather than expose SFTP primitives.
- `TerminalAttachSession` already carries one ordered stream of terminal input,
  output, and resize events. Image-path insertion should use that same input
  path rather than create a second writer through Herdr's JSON API.
- `SSHTransport` reserves capacity for short request channels, events, and
  Attach under OpenSSH's usual session-channel limit. SFTP must acquire capacity
  from the same bounded pool.
- The pinned SSH dependency already provides an SFTP client with streamed
  writes, so no new SSH dependency is required. (This was Citadel 0.12.1 on
  2026-07-23; it is `HeelerSSH`'s libssh2-backed `SSHSFTPClient` since
  ADR 0011.)
- The Attach keyboard accessory already has room for a system Paste control,
  and the embedded Ghostty view has an app-owned text-input seam.
- iOS does not need a terminal `Ctrl+V` key. A system Paste control provides the
  touch path, while a physical keyboard uses `Command+V`. `Ctrl+V` retains its
  terminal meaning.

## Final architecture

```text
PhotosPicker
    |
    v
ImagePreparer
    |  decode, orient, resize, re-encode, strip metadata
    v
PreparedImage in protected iOS temporary storage
    |
    v
ImageAttachStore
    |  state, progress, cancellation, retry, session generation
    v
Transport.stageImage(_:)
    |  shared SSH channel permit, remote mktemp, SFTP, permissions, rename
    v
StagedImage with an absolute Host path
    |                         |
    |                         +--> local-only iOS clipboard, 24-hour expiry
    v
TerminalInputController
    |  insert path, then insert one space, never Enter
    v
Current live Attach session
```

### Module boundaries

`ImagePreparer` owns local image work:

- load the selected Photos item into app-controlled temporary storage;
- verify that it decodes as an image;
- apply orientation;
- bound decoded pixel memory;
- resize and re-encode;
- strip metadata;
- produce a `PreparedImage`.

`Transport` exposes one domain-level operation:

```swift
func stageImage(_ image: PreparedImage) async throws -> StagedImage
```

The concrete transport owns:

- acquisition of a shared SSH session-channel permit;
- creation of a private directory in OS-designated remote temporary storage;
- SFTP streaming and byte progress;
- restrictive directory and file permissions;
- incomplete `.part` handling;
- atomic rename to the final random filename;
- validation of the returned absolute path.

UI code never sees SSH backend types, constructs remote commands, chooses remote
paths, or manages SSH permits.

`ImageAttachStore` owns the operation lifecycle:

- one operation at a time;
- the Attach session generation captured when selection or explicit Retry starts;
- preparation and upload progress;
- user cancellation;
- retry with the already prepared local file;
- clipboard and insertion results;
- recovery actions for partial success.

`TerminalInputController` is the single application-level writer for local
terminal input. Keyboard input, system Paste, and image-path insertion all pass
through it. `ImageAttachStore` requests text insertion; it does not write raw
SSH bytes or call Ghostty directly.

## Image preparation

The MVP accepts one `PhotosPicker` selection. Camera and Files sources are
future work.

Every input is decoded and re-encoded:

- preserve transparency with PNG;
- encode opaque content as JPEG, starting near quality `0.9`;
- apply orientation before encoding;
- discard EXIF, GPS, original filename, and other source metadata;
- use an unguessable random output name;
- limit the long edge to 4096 pixels;
- limit the final encoded file to 16 MiB;
- lower JPEG quality and, when necessary, dimensions to fit;
- scale PNG dimensions while preserving alpha;
- fail only when a valid bounded output cannot be produced.

Decoded pixel count and allocation must be bounded before full-resolution
rendering so a small compressed file cannot cause unbounded memory use.

The prepared file is:

- stored in app-owned temporary storage;
- excluded from backup;
- protected with the strongest file protection compatible with immediate use;
- deleted after success, explicit cancellation, unrecoverable failure, or
  leaving Attach;
- retained after a background-interrupted upload so the user can retry on
  foreground return;
- removed on the next launch if a crash left it behind.

## Remote staging

The feature supports macOS and Linux Hosts. It must not hardcode `/tmp`, a
macOS-only directory, a home-directory cache, or a repository-relative path.
The transport creates a private directory through a controlled remote
`mktemp -d` operation using the Host operating system's temporary-directory
selection.

Remote requirements:

- one unique directory per operation, mode `0700`;
- one random `.part` file, mode `0600`;
- direct restrictive creation rather than permissive creation followed by a
  best-effort chmod;
- streamed SFTP write;
- final size verification;
- atomic rename from `.part` to the final PNG or JPEG name;
- failure if restrictive permissions cannot be enforced;
- no caller-supplied remote filename or destination.

SFTP is a deliberate Host requirement for the MVP. If the subsystem is
disabled, the app reports that requirement and stops. It does not fall back to
base64, `cat`, shell stdin, Herdr's private clipboard protocol, or PTY transfer.

The upload operation may attempt to delete only its own incomplete `.part` file
after failure or cancellation. It never scans old directories. Disconnects may
prevent even that compensation.

Completed Staged Images are outside the mobile client's cleanup ownership. The
app neither deletes them nor promises a TTL. Host operating-system cleanup may
eventually remove them, but its timing is not part of the product contract. See
[ADR 0005](../adr/0005-keep-staged-image-cleanup-outside-mobile.md).

## Attach behavior

### Entry point

`Attach Image` appears as a photo-icon action in the navigation toolbar only
while Attach is live. It is disabled without a usable live session. It is not
added to other Agent surfaces in the MVP.

The action and its VoiceOver label are both `Attach Image`.

### Operation state

Only one image operation may be active. A second selection is disabled; there
is no queue and no latest-wins replacement.

While active:

- terminal output continues rendering;
- local terminal text, Keys controls, and Paste are disabled;
- a compact bottom status presents progress and Cancel;
- preparation is indeterminate: `Preparing Image…`;
- upload uses actual streamed bytes: `Uploading Image… 42%`;
- no fake preparation percentage or flashing finalization state is shown.

After upload, clipboard copy and insertion happen immediately without an extra
visible phase.

### Session binding

The store captures the Attach session generation when selection or an explicit
Retry begins. Automatic insertion occurs only if that exact live session still
exists when staging completes.

If the session disconnects, reconnects, exits, or is replaced:

- the completed remote image remains staged;
- the app still attempts to copy its path;
- the app does not automatically insert into the new session;
- the result explains that the path was copied but not inserted.

A remote TUI focus change within the same session does not cancel automatic
insertion. This accepts the small risk that the path reaches a different input
inside that same terminal.

### Input sequence

Automatic insertion sends two ordered operations:

1. the absolute path as one standalone text insertion;
2. one space.

It sends no quotes, Markdown, explanation, newline, or Enter. The user remains
responsible for adding an instruction and submitting it.

### Clipboard

After successful staging, the app copies the path before attempting automatic
insertion. Clipboard data:

- is plain text;
- uses the local-only option;
- expires after 24 hours;
- replaces the previous copied image path;
- is not stored in an app clipboard history.

Clipboard expiration has no relationship to the lifetime of the remote file.

### Result and recovery

The ordered outcome is stage, copy, then insert.

| Outcome | Message | Recovery |
| --- | --- | --- |
| Staged, copied, inserted | `Image path inserted and copied.` | None |
| Staged and copied, insertion failed | `Image path copied, but couldn't be inserted.` | Paste manually or use `Insert Path` |
| Staged and inserted, copy failed | `Image path inserted, but couldn't be copied.` | Use `Copy Path` |
| Staged, copy and insertion failed | `Image uploaded, but its path couldn't be copied or inserted.` | Use `Copy Path` or `Insert Path` |
| Staging failed | `Image upload failed.` | Retry when a prepared file exists |
| User cancelled | No message | None |

A successfully returned `StagedImage` remains available in the Attach-local
result UI until dismissed or until the user leaves Attach. Recovery actions do
not re-upload:

- `Copy Path` retries the clipboard write;
- `Insert Path` explicitly targets the current live Attach session;
- `Dismiss` removes the result UI but does not delete the Host file.

### Retry and interruption

A transient upload failure retains the normalized local file for session-local
Retry. Retry uses the current live Attach session and does not reselect or
re-encode the image. Retry state does not survive app restart.

When the app backgrounds during upload:

- cancel the SFTP operation;
- attempt compensation for the current `.part`;
- retain the prepared local file;
- do not copy or insert a path;
- show Retry after returning to the foreground;
- do not start an automatic retry or background task.

Explicit Cancel or leaving Attach ends the operation and removes the local
prepared file. A completed remote Staged Image remains untouched.

## Terminal Paste

Paste is a generic plain-text terminal action, not an image-only control.

Add a system `UIPasteControl` to the left side of the Attach keyboard
accessory. It remains visible in both Text and Keys modes and exposes the
VoiceOver label `Paste`. A physical keyboard uses the standard `Command+V`.
Do not add `Ctrl+V`.

Paste safety:

- ordinary single-line text inserts immediately;
- multiline text opens a review sheet with line count, character count, and a
  truncated monospaced preview;
- Cancel is the default action in that review;
- confirmed ordinary multiline text inserts as one paste;
- NUL, ESC, and other non-whitelisted control content is rejected rather than
  reviewed.

Using the system Paste control keeps the action user initiated and uses iOS's
standard pasteboard interaction instead of a custom clipboard button.

## Diagnostics and privacy

Diagnostics may record:

- operation phase;
- normalized format and dimensions;
- byte count;
- duration;
- sanitized error category.

Diagnostics must not record:

- image bytes or rendered previews;
- the iOS temporary path;
- the full remote path;
- clipboard content;
- source Photos metadata.

User-facing errors explain the actionable phase, such as preparation failure,
SFTP unavailability, upload failure, or insertion failure. Raw SSH and SFTP
details remain in sanitized diagnostics.

## Rejected alternatives

### Use `pane.send_input`

Rejected for this flow. Attach already has a live terminal input stream, and a
second API writer introduces ordering and lifecycle ambiguity. The
application-owned `TerminalInputController` keeps one authoritative local input
path and one session-generation check.

### Use Herdr's private clipboard-image protocol

Herdr's remote client validates the upload-then-paste-path concept, but its
clipboard bridge is a private protocol for `herdr --remote`. Depending on it
would add a second versioned wire protocol and bypass the app's current
transport boundary.

### Submit the prompt automatically

Rejected. Provider and model behavior is outside the app's capability
contract, and the app must not press Enter on the user's behalf. The standalone
path plus trailing space leaves the terminal draft under user control.

### Stream through a shell command

Rejected for the MVP. A shell fallback broadens quoting, executable discovery,
portability, and failure semantics. An explicit SFTP requirement is smaller and
more testable.

### Perform OCR on iOS

OCR produces text, not image input, and loses layout, diagrams, color, and other
visual information. It may be a separate future feature but is not a fallback
inside `Attach Image`.

## Verification plan

### Unit tests

- orientation is applied correctly;
- alpha selects PNG and opaque content selects JPEG;
- metadata is absent after encoding;
- 4096-pixel and 16 MiB limits are enforced;
- decoded memory is bounded;
- state transitions cover success, partial success, cancellation, background
  interruption, retry, session replacement, and leaving Attach;
- clipboard options and expiration are correct;
- image-path insertion is path then space, with no Enter;
- Paste accepts single-line text, reviews multiline text, and rejects unsafe
  controls.

### Real SSH integration tests

- macOS and Linux temporary-directory creation;
- real SFTP streamed writes through the pinned SSH backend;
- directory mode `0700` and file mode `0600`;
- `.part` to final atomic rename;
- current-operation compensation after failure and cancellation;
- SFTP-disabled error behavior with no fallback;
- shared channel permits with events and Attach active;
- disconnect and `MaxSessions` exhaustion;
- no image bytes written to the PTY.

### iOS interaction verification

- Photos selection and cancellation;
- `Attach Image` availability in live and disconnected Attach states;
- real preparation and upload progress;
- disabled local input while remote output continues;
- background cancellation and foreground Retry;
- system Paste in Text and Keys modes;
- multiline review and unsafe-control rejection;
- physical-keyboard `Command+V`;
- VoiceOver labels and focus order.

Agent/model image interpretation is intentionally not an acceptance criterion.

## Acceptance criteria

The MVP is ready when:

1. One selected image is normalized within the documented dimension and size
   bounds.
2. The normalized file is staged over real SFTP on both supported Host
   operating systems.
3. Remote directory and file permissions are enforced before sensitive bytes
   are exposed.
4. Image bytes never enter the Attach PTY or Herdr JSON API.
5. Upload uses the existing bounded SSH session-channel capacity.
6. Clipboard copy occurs only after successful staging and uses local-only,
   expiring data.
7. Automatic insertion targets only the original live Attach session.
8. The inserted sequence is the path followed by a separate space, with no
   Enter.
9. Failure, partial success, cancellation, retry, backgrounding, and session
   replacement have verified state transitions.
10. The mobile client never enumerates or deletes completed remote Staged
    Images.

## Primary sources

- [Apple: Selecting photos and videos in iOS](https://developer.apple.com/documentation/photokit/selecting-photos-and-videos-in-ios)
- [Apple: What's new in the Photos picker](https://developer.apple.com/videos/play/wwdc2022/10023/)
- [Apple: UIPasteControl](https://developer.apple.com/documentation/uikit/uipastecontrol)
- [Apple: UIPasteConfigurationSupporting](https://developer.apple.com/documentation/uikit/uipasteconfigurationsupporting)
- [Apple: UIPasteboard](https://developer.apple.com/documentation/uikit/uipasteboard/)
- [RFC 4254: The Secure Shell Connection Protocol](https://datatracker.ietf.org/doc/html/rfc4254)
- [Citadel SFTP client](https://github.com/orlandos-nl/Citadel/blob/ae8562f895de06ccb86fdb1cbb65fd99c8976e12/README.md#sftp-client)
  (the SSH backend on 2026-07-23; replaced by `HeelerSSH` in ADR 0011)
- [Herdr remote workflow](https://herdr.dev/docs/how-to-work/)
- [Herdr clipboard bridge commit](https://github.com/ogulcancelik/herdr/commit/ed478be)
