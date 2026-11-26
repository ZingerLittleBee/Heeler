# Chat troubleshooting

Fixes for the problems you are most likely to meet in [Chat](chat.md). Most other messages in Chat say what to do. If Chat can't do something, tap **Show Agent Terminal** and continue there.

## There is no Show Chat

With herdr, Chat works only for Claude Code, Codex, Pi, Oh My Pi, Grok Build, OpenCode, and Antigravity CLI on macOS and Linux Hosts. On a herdr-core (native Windows included) or tmux Host, [herdr-core](herdr-core.md#chat) and [tmux](tmux.md#chat) list the programs Chat opens for on each system. After Heeler starts, **Show Chat** also stays hidden until the Host connects.

## Waiting for Conversation

herdr hasn't told Heeler which conversation the Agent is in yet.

1. For Codex, send a first prompt; it needs one after every start or resume. For OpenCode, open a conversation in the terminal or send a first message there.
2. On the Host, run `herdr integration status` and install the program's integration if it isn't `current` ([Set up the Host](chat.md#set-up-the-host)), then restart the Agent.
3. Tap **Check Again**.

If Codex still waits after you have sent prompts, it was probably started without `--no-daemon`: see the next section.

## Codex Started Without --no-daemon

Codex was started without `--no-daemon` while its background server runs, so herdr can't tell which terminal its conversation is in ([Set up the Host](chat.md#set-up-the-host)). Agents that herdr brings back after a restart also start without it, unless you use the alias in [Set up the Host](chat.md#set-up-the-host). Exit Codex and run `codex --no-daemon resume` to continue the same conversation. If Codex says the conversation is open in another app, the background server still holds it: run `codex app-server daemon stop`, which also ends any other Codex on that server, then resume again. When a conversation already shows, a banner warns that it may be another terminal's.

Codex tracks the cause in [openai/codex#48500](https://github.com/openai/codex/issues/48500): its background server runs herdr's integration with the settings of the terminal that started the server. [openai/codex#44902](https://github.com/openai/codex/issues/44902) proposes a fix, and herdr follows it in [herdrdev/herdr#4649](https://github.com/herdrdev/herdr/issues/4649).

## Can't Tell the Conversation

On [herdr-core](herdr-core.md#chat), [tmux](tmux.md#chat), and [Rex](rex.md#chat) Hosts, Chat identifies an Agent's conversation from what the Host shows about its running process and never guesses. Chat checks again automatically when the Agent's status changes, or whenever you tap **Check Again**. On macOS and Linux, you can also tap **Choose a Conversation** to pick the conversation yourself.

| Program or situation | Why Chat can't tell and what to do |
| --- | --- |
| **Codex** | A fresh `--no-daemon` Codex starts its conversation with the first message (sent from Chat or the terminal). If Chat still can't tell—for example after `/new`, when Codex keeps more than one thread open—exit Codex, run `codex resume --no-daemon`, and pick the conversation. If Codex started without `--no-daemon`, see [Codex Started Without --no-daemon](#codex-started-without---no-daemon). |
| **Claude Code** | Claude Code registers its session once it reaches its prompt. Finish signing in or answer any trust or startup prompt in the terminal. |
| **Grok Build** | Grok Build lists its active conversation while it runs. After `/new`, it lists both conversations for the same process, so restart Grok Build or use **Choose a Conversation**. |
| **Pi and Oh My Pi** | Pi and Oh My Pi name their conversation through Heeler's extension (`heeler-session.js`). On macOS and Linux herdr-core and tmux Hosts, install the [Host Helper](herdr-core.md#host-helper) from the Host's details and restart the Agent. On [Rex](rex.md#pi-and-oh-my-pi) and [native Windows](herdr-core.md#chat) Hosts, tap **Add Heeler's Extension…** in Chat and restart the Agent. If the extension is already installed, the Agent started before it was added or with `--no-extensions`—restart it with extensions enabled. Without the extension, Oh My Pi still binds after its first message. |
| **Antigravity CLI** | Antigravity CLI creates its conversation on its first message; Chat can send that first message only to a bare `agy` launch, so send it in the terminal otherwise. A conversation already open in another terminal is not locked by a second one, so close the other terminal first. |
| **OpenCode** | OpenCode reports its conversation when started from **New Agent** (version 2.1 or later) or through Heeler's plugin (**Let Chat Follow OpenCode…**). |
| **Windows process read failed** | Heeler couldn't inspect the Agent's process on the Host. Run `herdr-core` and your SSH session at the same elevation (both non-administrator), and avoid PowerShell Constrained Language Mode. |

## Conversation Not Found

- A Claude Code, Codex, or Grok Build Agent started with its own configuration folder (such as `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, or `GROK_HOME`), or an OpenCode Agent using another database (such as `OPENCODE_DB`), can't show in Chat. Chat reads only their default locations.

## Chat says the terminal shows another conversation

Chat sends only while the Agent's terminal shows the same conversation. This happens after `/resume` or `/fork` in Grok Build, or after switching to another session in OpenCode. Go back to the conversation in the terminal, then send again.

## Chat shows an earlier Codex conversation

Codex tells herdr about a conversation only when you send it a prompt. After `/new` or `/resume` in the terminal, send a prompt there and Chat follows. After `/fork`, or after going back to a conversation you opened earlier, Chat can stay on the old one: exit Codex, run `codex --no-daemon resume`, pick the conversation, and send a prompt.

## The Agent's input box already has text

Chat only types into an empty input box. Tap **Open in Terminal**, send or delete the text there, then tap **Send** again. Your message is kept.

## Not delivered. The text is still in the Agent's input box

Your message is in the Agent's input box but wasn't sent, for example because a popup caught the Enter or **Stop** put it back. Tap **Show Agent Terminal**, then press Enter to send it, or clear it. Don't send it again from Chat.

## Stop didn't stop the Agent

Subagents and background tasks can keep an Agent working after **Stop**. Check the Agent's terminal, and tap **Stop** again if the turn is still running.

## Waiting for Input

Heeler doesn't recognize this question, for example any question from Pi. Use the card's keys to press Esc, Tab, the arrows, or Enter (tap **Keys** first if they're hidden), or tap **Open in Terminal** and answer there.

## Reading OpenCode's conversations needs sqlite3 or python3 on the Host

Install `sqlite3` or Python 3 on the Host, then tap **Check Again**. If Chat says it can't list OpenCode's 1.x conversations, add Heeler's plugin with **Let Chat Follow OpenCode…** or upgrade OpenCode to 2.x.

## SFTP is unavailable on this Host

**Add Image** and **Add File** upload over SFTP. Turn on SFTP in the Host's SSH server settings, then add the file again.

Last checked on 2026-10-25 against herdr 0.9.5.
