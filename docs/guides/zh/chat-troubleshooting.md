<!-- Translated from docs/guides/chat-troubleshooting.md at ed1e9e66 -->
# Chat 疑难排解

这里是 [Chat](chat.md) 中最常见问题的处理方法。Chat 里的其他提示大多会直接说明该怎么做。如果 Chat 做不到某件事，轻点 **Show Agent Terminal**，在终端中继续。

## 没有 Show Chat

Chat 只支持 macOS 和 Linux Host 上的 Claude Code、Codex、Pi、Oh My Pi、Grok Build 和 OpenCode。此外，Heeler 启动后，在 Host 连接上之前，**Show Chat** 也不会出现。

## Waiting for Conversation

herdr 还没有告诉 Heeler 这个 Agent 正在哪个对话中。

1. 对于 Codex，发送第一条提示；每次启动或恢复（resume）后都需要发送一条。对于 OpenCode，在终端中打开一个对话，或在那里发送第一条消息。
2. 在 Host 上运行 `herdr integration status`，如果该程序的集成不是 `current`，安装它（参见[配置 Host](chat.md#配置-host)），然后重启 Agent。
3. 轻点 **Check Again**。

如果已经发送过提示，Codex 仍在等待，很可能是启动时没有加 `--no-daemon`：参见下一节。

## Codex Started Without --no-daemon

Codex 启动时没有加 `--no-daemon`，而它的后台服务正在运行，所以 herdr 无法判断它的对话在哪个终端里（参见[配置 Host](chat.md#配置-host)）。herdr 重启后恢复的 Agent 也不带这个参数，除非你用了[配置 Host](chat.md#配置-host) 中的别名。请退出 Codex，然后运行 `codex --no-daemon resume` 继续原来的对话。如果已经显示了对话，顶部的横幅会提醒它可能属于另一个终端。

Codex 在 [openai/codex#48500](https://github.com/openai/codex/issues/48500) 中跟踪这个问题的原因：它的后台服务运行 herdr 集成时，使用的是启动该服务的那个终端的设置。[openai/codex#44902](https://github.com/openai/codex/issues/44902) 提出了修复方案，herdr 在 [herdrdev/herdr#4649](https://github.com/herdrdev/herdr/issues/4649) 中跟进。

## Conversation Not Found

- 用自定义配置目录（例如 `CLAUDE_CONFIG_DIR`、`CODEX_HOME` 或 `GROK_HOME`）启动的 Claude Code、Codex 或 Grok Build Agent，或使用其他数据库（例如 `OPENCODE_DB`）的 OpenCode Agent，都无法在 Chat 中显示。Chat 只读取它们的默认位置。

## Chat 提示终端显示的是另一个对话

只有当 Agent 的终端显示的是同一个对话时，Chat 才会发送消息。在 Grok Build 中执行 `/resume` 或 `/fork` 之后，或在 OpenCode 中切换到另一个会话之后，就会出现这种情况。请在终端中回到原来的对话，然后重新发送。

## Chat 显示的是之前的 Codex 对话

Codex 只有在你给对话发送提示时，才会把这个对话告诉 herdr。在终端中执行 `/new` 或 `/resume` 后，在那里发送一条提示，Chat 就会跟上。执行 `/fork` 之后，或回到之前打开过的对话之后，Chat 可能停留在旧对话上：请退出 Codex，运行 `codex --no-daemon resume`，选择该对话，然后发送一条提示。

## The Agent's input box already has text

Chat 只会在 Agent 的输入框为空时输入消息。轻点 **Open in Terminal**，在那里发送或删除这些文字，然后再轻点 **Send**。你的消息会保留。

## Not delivered. The text is still in the Agent's input box

你的消息已经在 Agent 的输入框里，但没有发出去，例如弹出窗口吞掉了 Enter，或者 **Stop** 把它放了回去。轻点 **Show Agent Terminal**，按 Enter 发送，或者把它清空。不要从 Chat 再发送一次。

## Stop 没有停下 Agent

点了 **Stop** 之后，Subagent 和后台任务仍可能让 Agent 保持工作状态。查看 Agent 的终端，如果这一轮仍在运行，再轻点一次 **Stop**。

## Waiting for Input

Heeler 不认识这个问题，例如 Pi 的所有问题。用卡片上的键按 Esc、Tab、方向键或 Enter（如果键被隐藏，先轻点 **Keys**），或者轻点 **Open in Terminal** 到终端中回答。

## Reading OpenCode's conversations needs sqlite3 or python3 on the Host

在 Host 上安装 `sqlite3` 或 Python 3，然后轻点 **Check Again**。如果 Chat 提示对话是 OpenCode 1.x 格式，请把 OpenCode 升级到 2.x。

## SFTP is unavailable on this Host

**Add Image** 和 **Add File** 通过 SFTP 上传。在 Host 的 SSH 服务器设置中开启 SFTP，然后重新添加文件。

最后核对于 2026-10-25，基于 herdr 0.9.5。
