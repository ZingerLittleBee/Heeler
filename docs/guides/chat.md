# Chat with an Agent

Chat shows an Agent's conversation as messages instead of a terminal screen. Read what the Agent did, reply, and answer its questions with buttons.

You need a macOS or Linux Host running herdr, and an Agent there running Claude Code, Codex, Pi, Oh My Pi, Grok Build, or OpenCode.

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

Replace `claude` with `codex`, `pi`, `omp`, `grok`, or `opencode` as needed. OpenCode must be version 2.x, and the Host needs `sqlite3` or `python3` for it.

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
- After scrolling up, tap the round button with a down chevron at the bottom right to jump back to the newest message.
- Pull down past the top to load earlier messages.

To change the font or text size, go to **Settings > Appearance**.

## Send a message

Type in **Message Agent** and tap **Send**. Chat types the message into the Agent's terminal and presses Enter for you, and never sends a message twice.

- **While the Agent works**, Claude Code, Codex, Pi, and Grok Build take your message right away. Oh My Pi and OpenCode need the turn to finish first.
- **Stop.** While the Agent works and your message is empty, **Send** becomes **Stop**. Tap it to interrupt the turn.
- **Commands.** Type `/` to pick `/compact` or one of the Agent's skills. Other commands, such as `/model`, go in the terminal.
- **Images and files.** Tap **+**, then **Add Image** or **Add File**. Heeler uploads it to the Host and adds its path to your message.

If Chat can't send something, such as a message starting with `!`, it keeps your text and says why under the message box.

> [!TIP]
> On an iPad with a keyboard, press **Return** to send and **Shift-Return** for a new line.

## Answer a Blocked Agent

When the Agent asks for permission or asks a question, a card takes the place of the message box, with a button for each answer. A tap answers right away, just like pressing the key in the terminal, and can't be undone.

Answer in the terminal when Codex asks "Implement this plan?", or to type your own answer in Oh My Pi, Grok Build, or OpenCode. For Pi, the card shows keys to press instead of buttons.

## When the Host is offline

Heeler keeps recent conversations on your device, so you can still read them when the Host can't be reached. Their Agents stay in **Agents** with a **Saved** badge. Tool output and sending come back once the Host connects.

Last checked on 2026-10-25 against herdr 0.9.5.
