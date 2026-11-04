# Chat troubleshooting

Fixes for the problems you are most likely to meet in [Chat](chat.md). Most other messages in Chat say what to do. If Chat can't do something, tap **Show Agent Terminal** and continue there.

## There is no Show Chat

Chat works only for Claude Code, Codex, Pi, Oh My Pi, Grok Build, and OpenCode on macOS and Linux Hosts. After Heeler starts, **Show Chat** also stays hidden until the Host connects.

## Waiting for Conversation

herdr hasn't told Heeler which conversation the Agent is in yet.

1. For Codex, send a first prompt; it needs one after every start or resume. For OpenCode, open a conversation in the terminal or send a first message there.
2. On the Host, run `herdr integration status` and install the program's integration if it isn't `current` ([Set up the Host](chat.md#set-up-the-host)), then restart the Agent.
3. Tap **Check Again**.

If Codex still waits after you have sent prompts, it was probably started without `--no-daemon`: see the next section.

## Codex Started Without --no-daemon

Codex was started without `--no-daemon` while its background server runs, so herdr can't tell which terminal its conversation is in ([Set up the Host](chat.md#set-up-the-host)). Agents that herdr brings back after a restart also start without it, unless you use the alias in [Set up the Host](chat.md#set-up-the-host). Exit Codex and run `codex --no-daemon resume` to continue the same conversation. When a conversation already shows, a banner warns that it may be another terminal's.

Codex tracks the cause in [openai/codex#48500](https://github.com/openai/codex/issues/48500): its background server runs herdr's integration with the settings of the terminal that started the server. [openai/codex#44902](https://github.com/openai/codex/issues/44902) proposes a fix, and herdr follows it in [herdrdev/herdr#4649](https://github.com/herdrdev/herdr/issues/4649).

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

Install `sqlite3` or Python 3 on the Host, then tap **Check Again**. If Chat says the conversations are in OpenCode's 1.x format, upgrade OpenCode to 2.x.

## SFTP is unavailable on this Host

**Add Image** and **Add File** upload over SFTP. Turn on SFTP in the Host's SSH server settings, then add the file again.

Last checked on 2026-10-25 against herdr 0.9.5.
