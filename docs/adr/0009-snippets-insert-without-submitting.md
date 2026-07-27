# Snippets insert without submitting, and multiline goes out as a bracketed paste

Tapping a Snippet inserts its text into the live Attach session and stops there; the user still presses Enter. Snippets reach the pane through a dedicated `TerminalInputController` entry point rather than the Paste path, so `TerminalInputController` remains the single writer for local terminal input. A multiline Snippet is wrapped in bracketed paste (`ESC [ 200~` … `ESC [ 201~`) whenever the remote application has enabled DECSET 2004, which `TerminalModeTracker` now tracks alongside the mouse and cursor-key modes; `confirmPaste` uses the same path, since ordinary Paste had the same gap.

The name "phrases you send to an Agent" invites the opposite reading, so the reasoning is worth keeping: an app that presses Enter on the user's behalf can send an unfinished or wrong message to a working Agent, and that is not undoable. This matches ADR 0006, which already refuses to submit an inserted image path.

## Considered Options

- **Insert and submit, always** — rejected. One mistaken tap while an Agent sits at a confirmation prompt is unrecoverable, and the app cannot know what state the pane is in.
- **A per-Snippet `autoSubmit` flag** — rejected. It makes the guarantee conditional, so no reader of the code or the UI can rely on "tapping a Snippet never sends anything," and the safe default has to be argued for every Snippet instead of once.
- **Forbid multiline Snippets** — rejected. Multiline prompt templates are a main reason Snippets carry an optional Title at all, and forbidding them would trade a real capability for a problem bracketed paste already solves.
- **Send multiline text raw** — rejected not because LF submits (it does not; Enter is CR 0x0D, a Snippet's newlines are LF 0x0A, and a TUI in raw mode generally reads LF as a newline) but because that behaviour is each TUI's private choice across three different stacks. Bracketed paste states the intent on the wire instead of depending on it.

## Consequences

- Enter is on a different tab of the Keys keyboard than Snippets, so tapping a Snippet switches back to the control-key tab.
- Snippet text is normalised on save: `\r\n` and lone `\r` become `\n`, and other control characters are refused. The real submit hazard is a CR pasted into the editor from elsewhere, not the newlines the user types.
- When the remote application has not enabled DECSET 2004 (a plain shell, say), multiline text is sent raw and its lines will execute. Attach targets Agent TUIs, which do enable it.
