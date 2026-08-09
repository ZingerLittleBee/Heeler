# Stage attachments over SFTP and insert their paths without submitting

The Composer's Add menu accepts one image from Photos or one document from Files. Images are decoded, bounded, stripped of metadata, and re-encoded into protected app-owned temporary storage. Files are copied into protected app-owned temporary storage while the document provider's security scope is active, capped at 64 MiB, and given a private random local name. The original safe extension is retained so the Agent can identify the staged file type.

`Transport.stageImage(_:)` and `Transport.stageFile(_:)` share the same SFTP implementation: private Host temporary directories, restrictive permissions, partial-file compensation, atomic completion, and the shared SSH session-channel budget. The resulting absolute Host path is copied to the local-only expiring clipboard and appended to the local Composer draft with a trailing space. It never submits the draft. Legacy Agent surfaces without a Composer retain the image-only Attach insertion path; `TerminalInputController` remains their single writer and validates the captured Attach generation before insertion.

`ImageAttachStore` and `FileAttachStore` own preparation, progress, cancellation, retry, clipboard results, and path insertion. Completed Host files intentionally outlive the screen per ADR 0005.

## Considered Options

- **Send attachment bytes through the Attach PTY** — rejected because terminal input has no file framing and would interpret arbitrary binary bytes as keystrokes and control sequences.
- **Use Herdr's private clipboard-image protocol or `pane.send_input`** — rejected because the mobile app should not depend on a private wire format or introduce a second writer beside the live Attach input stream.
- **Stream through a remote shell command when SFTP is unavailable** — rejected for the MVP because it expands the quoting, portability, and security surface. SFTP support is an explicit Host requirement.
- **Submit an instruction and path automatically** — rejected because the app cannot guarantee provider-specific attachment recognition and must not press Send or Enter for the user.

## Consequences

- The Composer handles one attachment operation at a time. Images use `PhotosPicker`; files use the system document picker.
- The app guarantees preparation, staging, clipboard copy, and path insertion. Whether an Agent consumes the staged path as an attachment is outside the capability contract.
- Upload and terminal rendering may continue concurrently. Composer insertion does not write to the PTY; legacy image insertion pauses local terminal input while active.
- Clipboard content is local-only, expires after 24 hours, and replaces the previously copied path.
- Completed remote attachments follow ADR 0005 and are never cleaned up by the mobile client.
