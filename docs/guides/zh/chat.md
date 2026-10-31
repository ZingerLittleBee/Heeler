<!-- Translated from docs/guides/chat.md at aea333b8 -->
# 在 Chat 中使用 Agent

Chat 把 Agent 的对话显示成消息，而不是终端画面。你可以查看 Agent 做了什么、回复它，并用按钮回答它的提问。

你需要一台运行 herdr 的 macOS 或 Linux Host，并在上面运行 Claude Code、Codex、Pi、Oh My Pi、Grok Build 或 OpenCode 的 Agent。

## 配置 Host

**运行位置：Mac 或 Linux**

Chat 需要 herdr 为你使用的每个程序安装集成（integration）。先检查：

```sh
herdr integration status
```

如果某个程序显示的不是 `current`，安装它的集成，然后重启该 Agent：

```sh
herdr integration install claude
```

按需把 `claude` 换成 `codex`、`pi`、`omp`、`grok` 或 `opencode`。OpenCode 需要 2.x 版本，并且 Host 上要有 `sqlite3` 或 `python3`。

启动 Codex 时加上 `--no-daemon`，继续原来的对话用 `codex --no-daemon resume`：

```sh
codex --no-daemon
```

Codex 的共享后台服务无法告诉 herdr 对话在哪个终端里，Chat 可能一直等待，或显示另一个 Agent 的对话。只在 Codex 设置中关闭 `daemon_auto_start` 是不够的。

在 Codex 修复之前，可以在 shell 的启动文件（如 `~/.zshrc`、`~/.bashrc` 或 `~/.config/fish/config.fish`）中加一个别名。herdr 重启后恢复的 Agent 也会用上它：

```sh
alias codex='codex --no-daemon'
```

用了别名后，直接运行 `codex` 和 `codex resume` 即可：Codex 不接受重复两次的 `--no-daemon`。

## 打开 Chat

1. 在 **Agents** 中打开一个 Agent。
2. 轻点右上角的 **Show Chat**（文字气泡图标）。要回到终端，轻点同一个按钮，此时它变成 **Show Agent Terminal**。

Heeler 会记住你的选择，之后打开的 Agent 都会先显示 Chat，直到你切回终端。草稿在两者之间切换时会保留。

如果没有 **Show Chat**，或者 Chat 显示 **Waiting for Conversation**，请参见 [Chat 疑难排解](chat-troubleshooting.md)。

## 阅读对话

- 你的消息在右侧，Agent 的回答、推理和工具步骤在左侧。
- 一轮对话结束后，其中的步骤会折叠到一行 **Worked for …** 后面。轻点这一行可以展开，轻点工具卡片可以查看输出或文件改动。
- 按住一条消息即可复制。
- 向上滚动后，轻点右下角带向下 V 形箭头的圆形按钮，可回到最新消息。
- 在顶部继续下拉可加载更早的消息。

要更改字体或字号，前往 **Settings > Appearance**。

## 发送消息

在 **Message Agent** 中输入内容，然后轻点 **Send**。Chat 会替你把消息输入到 Agent 的终端并按下 Enter，同一条消息绝不会发送两次。

- **Agent 工作时**，Claude Code、Codex、Pi 和 Grok Build 会立即接收你的消息；Oh My Pi 和 OpenCode 要等这一轮结束。
- **停止。** Agent 工作时，如果输入框是空的，**Send** 会变成 **Stop**。轻点它可以中断这一轮。
- **命令。** 输入 `/` 可以选择 `/compact` 或 Agent 的技能。其他命令（例如 `/model`）请在终端中运行。
- **图片和文件。** 轻点 **+**，再选择 **Add Image** 或 **Add File**。Heeler 会把它上传到 Host，并把路径加到你的消息里。

如果 Chat 不能发送某条消息（例如以 `!` 开头的消息），它会保留你的文字，并在输入框下方说明原因。

> [!TIP]
> 在连接了键盘的 iPad 上，按 **Return** 发送，按 **Shift-Return** 换行。

## 回答处于 Blocked 状态的 Agent

当 Agent 请求权限或提出问题时，输入框的位置会换成一张卡片，每个答案对应一个按钮。轻点后立即作答，效果和在终端里按键一样，无法撤销。

Codex 询问 "Implement this plan?" 时，或者要在 Oh My Pi、Grok Build、OpenCode 中输入自己的答案时，请在终端中回答。对于 Pi，卡片上显示的是可以按的键，而不是按钮。

## Host 离线时

Heeler 会在设备上保存最近的对话，即使连不上 Host 也能继续阅读。这些 Agent 会留在 **Agents** 中，并带有 **Saved** 标记。Host 重新连接后，工具输出和发送功能都会恢复。

最后核对于 2026-10-25，基于 herdr 0.9.5。
