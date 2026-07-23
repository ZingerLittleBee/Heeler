# Stage images over SFTP and insert their paths through Attach

`Attach Image` prepares one Photos image locally, stages it in the Host operating system's temporary storage over SFTP, copies the resulting absolute path to the iOS clipboard, and inserts that path into the existing Attach input stream without submitting it. Image preparation stays outside `Transport`; `Transport.stageImage(_:)` owns SFTP, remote temporary-directory creation, restrictive permissions, partial-file handling, and the shared SSH session-channel budget. This keeps Citadel and remote shell details out of UI code and keeps image bytes out of the terminal stream.

`ImageAttachStore` owns the user operation, including preparation, progress, cancellation, retry, clipboard results, and the Attach session generation captured when selection or an explicit retry begins. `TerminalInputController` remains the single writer for local terminal input. Automatic insertion occurs only if that live Attach session still exists; it sends the path as one operation and a trailing space as a second operation, never Enter. A user may explicitly insert a successfully staged path into the current live session after an automatic insertion failure or session change.

## Considered Options

- **Send image bytes through the Attach PTY** — rejected because terminal input has no file framing and would interpret arbitrary binary bytes as keystrokes and control sequences.
- **Use Herdr's private clipboard-image protocol or `pane.send_input`** — rejected because the mobile app should not depend on a private wire format or introduce a second writer beside the live Attach input stream.
- **Stream through a remote shell command when SFTP is unavailable** — rejected for the MVP because it expands the quoting, portability, and security surface. SFTP support is an explicit Host requirement.
- **Submit an instruction and path automatically** — rejected because the app cannot guarantee provider-specific image recognition and must not press Enter for the user.

## Consequences

- The MVP is available only in a live Attach surface, handles one image at a time, and uses `PhotosPicker` as its only source.
- The app guarantees preparation, staging, clipboard copy, and path insertion. Whether an Agent turns the Staged Image into an Image Attachment is outside the capability contract.
- Upload and terminal rendering may continue concurrently, but all local terminal input is paused while `Attach Image` is active.
- Clipboard content is local-only, expires after 24 hours, and replaces the previously copied path.
- Completed remote files follow ADR 0005 and are never cleaned up by the mobile client.
