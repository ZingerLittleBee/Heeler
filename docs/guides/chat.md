# Chat with an Agent

Use your coding Agent in Heeler's native Chat on iPhone or iPad. Read conversations and reply over SSH while your Agents keep running on the Host.

You need a Host running herdr, [herdr-core](herdr-core.md#chat), [tmux](tmux.md#chat), or [Rex](rex.md#chat) (see its supported programs), and a supported coding Agent running there (Claude Code, Codex, Pi, Oh My Pi, Grok Build, OpenCode, or Antigravity CLI). Droid and local Devin CLI Chat support all four backends on macOS and Linux. The available controls depend on the foreground evidence each backend provides.

## Set up the Host

**Run on: Mac or Linux**

Chat needs herdr's integration for each program you use. Check them:

```sh
herdr integration status
```

If a program doesn't read `current`, install its integration, then restart that Agent:

```sh
herdr integration install claude
```

Replace `claude` with `codex`, `pi`, `omp`, `grok`, `opencode`, `antigravity-cli`, or `droid` as needed. OpenCode must be version 2.x, and the Host needs `sqlite3` or `python3` for it.

Start Codex with `--no-daemon`, and continue a conversation with `codex --no-daemon resume`:

```sh
codex --no-daemon
```

Codex's shared background server can't tell herdr which terminal a conversation is in, so Chat could keep waiting or show another Agent's conversation. Turning off `daemon_auto_start` in Codex's settings isn't enough.

Until Codex fixes this, add an alias to your shell's startup file (such as `~/.zshrc`, `~/.bashrc`, or `~/.config/fish/config.fish`). It also covers Agents that herdr brings back after a restart:

```sh
alias codex='codex --no-daemon'
```

With the alias, run plain `codex` and `codex resume`: Codex refuses `--no-daemon` given twice.

## Open Chat

1. Open an Agent from **Agents**.
2. Tap **Show Chat** (the text bubble) at the top right. To go back to the terminal, tap the same button, now **Show Agent Terminal**.

Heeler remembers your choice, so Agents keep opening on Chat until you switch back. Your draft carries over between the two.

If there is no **Show Chat**, or Chat shows **Waiting for Conversation**, see [Chat troubleshooting](chat-troubleshooting.md).

## Read the conversation

- Your messages are on the right. The Agent's answers, reasoning, and tool steps are on the left.
- When a turn finishes, its steps fold behind a **Worked for …** line. Tap it to see them, and tap a tool card to see its output or file changes.
- Touch and hold a message to copy it.
- Tap an image under a tool step, or a path to an image in a message (shown after a photo symbol, or in color on a line of its own in a code block), to open it with zoom.
- After scrolling up, tap the round button with a down chevron at the bottom right to jump back to the newest message.
- Pull down past the top to load earlier messages.

To change the font or text size, go to **Settings > Appearance**.

## Send a message

Type in **Message Agent** and tap **Send**. Chat types the message into the Agent's terminal and presses Enter for you, and never sends a message twice.

- **While the Agent works**, Claude Code, Codex, Pi, and Grok Build take your message right away. Oh My Pi, OpenCode, and Antigravity CLI need the turn to finish first.
- **Stop.** While the Agent works and your message is empty, **Send** becomes **Stop**. Tap it to interrupt the turn.
- **Commands.** Type `/` to pick `/compact` or one of the Agent's skills. Other commands, such as `/model`, go in the terminal.
- **Images and files.** On Herdr TUI, herdr-core, tmux and Rex Hosts, tap **+**, then **Add Image**, **Paste Image** or **Add File**. Paste Image takes the image on your clipboard, as does pasting one into the message. Heeler uploads it to the Host and adds its path to your message.

### Devin CLI

Open a running local Devin on a macOS or Linux Host. The session name above the timeline identifies the conversation that owns the Composer. Chat checks the foreground client, its ACP process and that process’s open session lock. The Host needs Python 3 with SQLite. Heeler reads Devin’s own store over SSH and does not install a plugin or change the user’s Devin configuration.

On a POSIX Host, New Agent starts an uncustomized Devin with its own writer. Presets and explicit arguments keep their settings. If the terminal uses a shared daemon, open a local client with `devin --process-model=in-process --resume SESSION`. A blocked sign-in belongs in the terminal. A recognized trust card shows the Host, full path and both choices before a session exists. A Rex block with Unknown status opens its terminal for trust and approvals.

- **Messages.** Send from the empty message field. A desktop draft, an active picker, Bash input or a working turn holds delivery. Enable terminal colors so Heeler can distinguish Devin’s placeholder from identical typed text. Use Devin’s terminal to steer. A session move parks the old draft. Returning to that session restores it.
- **Permissions.** Check the path or full command and scope before answering. The command chooser can offer Once, Session, Project and Always. A write permission can offer a change to Accept edits or Bypass mode. A partial screen, an unsupported tool or a proposal with additional execution settings stays in the terminal.
- **Questions and plans.** Answer a choice or type an Other response in its card. Devin advances to the next question and submits the final answer. Plan mode can ask to switch to Accept edits, switch to Bypass or decline. After a decline, send revisions through the plan feedback field.
- **Background work.** Open the task strip for each reported shell or subagent. Chat ties output to the shell ID or child agent ID in this session. A parent reply can arrive first. When Devin has not recorded an exit, the task keeps its last known state. Open the terminal’s task panel to manage active work.

The [Devin acceptance matrix](../agents/devin-chat-validation.md) records the independently exercised paths for each backend.

### Droid

On macOS and Linux, **New Agent** on herdr-core and tmux supplies a hook through Droid’s process-only `--settings`. If you supply your own `--settings`, Heeler keeps it. For a manually started Droid on herdr-core, tmux, or Rex, choose **Install Droid Hook…** in Chat, then restart or resume Droid in its terminal. Installing requires Python 3 on the Host. Heeler adds its handlers to `~/.factory/settings.json` alongside existing hooks. The installation sheet also offers **Remove Hook from Droid Settings**. Herdr TUI uses its built-in Droid integration. If the terminal is ready and the UUID is missing, run `herdr integration status` on that Host and check the Droid entry. Heeler also checks Factory’s foreground process and session lifecycle on the Host. With herdr 0.9.5 the reported ID can survive a desktop session switch. If the foreground UUID cannot be verified, open that Agent’s terminal. Enabling a hook in settings takes effect when Droid starts or resumes.

Droid Chat shows the foreground session UUID above its timeline. When a running session asks to change directories, declining the folder keeps the current session open. A verified folder trust card shows the Host, full directory, and both of Droid’s choices before there is a session. On a Rex block whose status is Unknown, finish trust in that block’s terminal. Factory sign-in also happens in the terminal.

Review the command, file changes, permission scope, or proposal in the card before choosing a response. A shortened command is verified against Droid’s approval details before the key goes to the terminal. Chat shows the complete patch for a single literal file passed to `git apply`, including quoted filenames with spaces. Open the Agent’s terminal for compound patch commands, multiple operands, or an unreadable patch. Chat rereads the displayed file before answering. A two-question AskUser form has a review step. A single question submits when selected. AskUser answers and Spec feedback have separate fields. If the desktop already answered, wait for the next card. An unrecognized request or an unreadable patch has a terminal entry.

Send while Droid’s message box is empty. After waiting for the terminal writer, Chat checks the displayed session and its input again. On herdr-core, tmux, and Rex it also checks its pasted text before Enter. A desktop draft, a menu, Bash mode, a running turn, or a different foreground session holds Send. Return to the original UUID to recover its draft. A lost acknowledgement stays in the timeline for reconciliation. **Stop** rechecks the displayed session, its active transcript turn and Droid’s interrupt prompt before sending Esc. Use the terminal for steering, queue editing, selectors, side chats and Mission Control.

Open the task bar for background commands and sub-Droids. A parent reply can arrive while a task is running. A recorded completion carries its own output. A running command with a verified PID and complete command line can be inspected and stopped from its details. When a narrow terminal also clips the command in the details, Chat returns to the previous screen and offers the terminal. When Droid has supplied only its last report, Chat shows that report. An interactive `/fork` leaves the original conversation open. Resume the copy in the terminal to switch Chat to its UUID.

If Chat can't send something, such as a message starting with `!`, it keeps your text and says why under the message box.

> [!TIP]
> On an iPad with a keyboard, press **Return** to send and **Shift-Return** for a new line.

## Hand work to another Agent

When an Agent is stuck or out of usage, or you want another opinion, give its conversation to another Agent on the same Host.

1. Long-press the Agent in **Agents**, or open the **More** menu at the top of the Agent, and tap **Hand Off**.
2. Choose **Take Over** to have the other Agent carry the work on, or **Second Opinion** to have it review the work.
3. Pick an Agent, or **New Agent…** to start one in the same directory.

Heeler writes the conversation to a file on the Host, without tool output, and opens the other Agent with a message about that file in its message box. Nothing is sent until you tap **Send**, so you can reword it first.

Hand Off needs an Agent whose conversation Chat can show and a Host that takes files, the same Hosts as **Add File**.

## Answer a Blocked Agent

When the Agent asks for permission or asks a question, a card takes the place of the message box, with a button for each answer. A tap answers right away, just like pressing the key in the terminal, and can't be undone.

Answer in the terminal when Codex asks "Implement this plan?", or to type your own answer in Oh My Pi, Grok Build, or OpenCode. For Pi, the card shows keys to press instead of buttons.

## When the Host is offline

Heeler keeps recent conversations on your device, so you can still read them when the Host can't be reached. Their Agents stay in **Agents** with a **Saved** badge. Tool output and sending come back once the Host connects.

Last checked on 2026-10-25 against herdr 0.9.5.
