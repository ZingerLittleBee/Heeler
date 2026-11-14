<!-- Translated from docs/guides/tmux.md at bb0ae7a6 -->
# 连接 tmux

通过 SSH 将 Heeler 连接到你在 Mac 或 Linux Host 上运行的 tmux 服务端，与 Herdr TUI 和 [herdr-core](herdr-core.md) 并列使用。每个 tmux socket 在 Heeler 中都是各自的 Host，可在控制台和原生 [Chat](#chat) 中直接使用其中的会话、窗口与编程 Agent。

## 开始之前

- 在 Mac 上开启“远程登录”并记录其 SSH 指纹：[准备 Host](overlay-networks.md#准备-host)。在 Linux 上运行 OpenSSH。tmux Host 不支持原生 Windows。
- 登录 shell 的 `PATH` 中装有 tmux 3.3 或更新版本（`tmux -V`）。Ubuntu 22.04 以及 AlmaLinux、Rocky Linux 9 自带 tmux 3.2a，请先安装更新版本。
- 在 Mac 上已启动 tmux 服务端（`tmux` 或 `tmux -L <name>`）。在 Linux 上可以提前启动 tmux，也可以稍后通过 **New Workspace** 启动。
- 让 iPhone 或 iPad 能够连通 Host：处于同一局域网下直连、通过 [Overlay Network](overlay-networks.md) 连接，或经由 [Jump Host](vps-jump-host-setup.md) 中转。一个 Host 可以配置[多条路由](host-routes.md)。

## 添加 Host

Heeler 在连接或检查时绝不会启动 tmux 服务端。

### 1. 填写 SSH 设置

1. 在 **Hosts** 中轻点 **Add Host**，列表为空时轻点 **Add Manually**。[扫码配对](pairing.md)始终添加 Herdr TUI Host。
2. 输入 SSH **User**，添加一条 Route，并选择 **Device Key**、**RSA Key** 或 **Password**。
3. 若选择 **Device Key**，请将表单中的公钥行复制到 Host 的 `~/.ssh/authorized_keys` 中。
4. 如果你的 tmux 服务端是以 `tmux -L <name>` 启动的，请填写 **Session name**，然后轻点 **Save**，并在核对 Host 的密钥指纹后轻点 **Trust**。确认为 tmux 后，该字段会在 **tmux Socket** 下显示为 **Socket name**。不支持手动输入自定义 socket 文件路径（`tmux -S <path>`）。

| 字段 | 值 |
| --- | --- |
| **Session name** / **Socket name** | 留空表示 `default`（未带 `-L` 启动的 tmux），或填写 `-L <name>` 的 socket 名称 |

### 2. 确认 Server Kind

Heeler 会通过你的登录 shell 在不启动任何服务的情况下检查一次，随后请你确认 **Server Kind**：

| Heeler 检测到 | 操作方法 |
| --- | --- |
| 一个 tmux 服务端 | 轻点 **Use tmux**。 |
| 多个 tmux 服务端 | 在 **tmux Socket** 下选择对应的 socket，然后轻点 **Use tmux**。 |
| 同时检测到 tmux 与 Herdr TUI 或 herdr-core | 先在此确认其中一种，再为同一台机器重新添加一个 Host 以使用另一种。 |
| 未检测到正在运行的服务端 | 如果这台 Host 将用于运行 tmux，请轻点 **Use tmux**。随后它的检查项会说明需要启动或安装什么。 |

确认后，**Server Kind** 即固定不变。之后你可以在 Host 详情中修改 **Socket name**。

**成功的标志是** Host 详情将 **Server Kind** 显示为带版本号的 `tmux`，**Socket** 显示你的 socket 名称，且 **tmux server running** 检查通过。

## 无法连接时

当 tmux 服务端停止运行时，Heeler 会自动重新检查，你也可以轻点 **Run Checks Again**：

| Host 显示 | 操作方法 |
| --- | --- |
| **No tmux server running** | 在 Host 上启动 `tmux`（或 `tmux -L <name>`），或在 Linux 上通过 **New Agent** 或 **New Terminal** 中的 **New Workspace** 启动。 |
| **Start tmux on the Mac first** | 在 macOS 上无服务端运行时执行 **New Workspace** 会显示此提示，因为通过 SSH 启动的服务端不在你的 Mac 登录会话中，缺少登录钥匙串。请在 Mac 的“终端”中启动 `tmux`。 |
| **tmux is not installed** | 在登录 shell 的 `PATH` 中安装 tmux 3.3 或更新版本，然后轻点 **Run Checks Again**。 |
| **Update required** | 将 Host 上的 tmux 升级到 3.3 或更新版本，然后轻点 **Run Checks Again**。 |

在 Linux 上当没有 tmux 服务端运行时，在 **New Agent** 或 **New Terminal** 中选择 **New Workspace** 会通过你的交互式登录 shell 启动服务端，使新建窗口继承你的 shell 配置。

> [!NOTE]
> 如果某个 Agent 会话的变量泄漏到了 tmux 中，Host 详情会发出提醒并说明清理方法。

## 控制台

Heeler 会直接将你的 tmux 结构映射到控制台中，而不会改动你原有的全局选项或快捷键绑定：

- **Workspaces、Tabs 与 Panes：** 按 tmux 自身的顺序，每个 tmux 会话（session）是一个 Workspace，每个窗口（window）是一个 Tab，每个窗格（pane）是一个 Pane。链接到多个会话中的同一个窗口只显示一次。
- **Agents 与 Terminals：** 正在运行 Claude Code、Codex、Grok Build、OpenCode、Pi 或 Oh My Pi 的窗格显示在 **Agents** 中。Shell 和其他程序显示在 **Terminals** 中。

| 状态 | 含义 |
| --- | --- |
| **Working** | 正在运行一轮对话。 |
| **Idle** | 在提示符处等待。 |
| **Blocked** | 等待你的回答，或在 Claude Code 中正在运行你已批准的工具。 |
| **Error** | 上报了错误，并与 **Blocked** 一起排序。 |
| **Done** | 在当前设备未打开该 Agent 时完成了一轮对话。打开该 Agent 仅会清除当前设备上的 **Done**。 |
| **Unknown** | 尚未上报状态。轻点 **Unknown** 可查看该程序在 tmux 中需要什么配置。 |

当 Grok Build 显示 **Unknown** 时，轻点 **Unknown**，再轻点 **Turn On Grok Build's Status** 和 **Apply This Change**，即可在 `$GROK_HOME/config.toml` 或 `~/.grok/config.toml` 中设置 `program_status = "on"`，并安装 [Host Helper](#host-helper) 以便 Heeler 读取其状态上报。可随时通过 **Undo** 或在 Host 详情的 **Harness Edits** 下还原该文件改动。

## 启动项目

- **New Agent：** 轻点 **New Agent**，选择工作区（tmux 会话）与目录，并从登录 shell 的 `PATH` 中选择 Agent，或从 **Settings > Agents & Accounts** 中选择 **Preset**。Heeler 会在后台新建窗口而不切换桌面端当前所在的窗口，在你未指定会话参数时以 `--no-daemon` 启动 Codex，并为本次启动的 Claude Code 自动传入 Heeler 的状态 hooks。
- **New Terminal：** 在所选工作区中打开一个运行登录 shell 的新窗口。
- **New Workspace：** 以你输入的名称创建一个新的 tmux 会话；留空时使用 tmux 默认编号。
- **Rename Workspace：** 在 Agent 或终端的 **More** 菜单中轻点 **Rename Workspace** 以重命名该 tmux 会话。
- **Worktrees：** 在 **New Agent** 中开启 **Start in a new worktree** 并输入 **Branch**，即可在独立的 tmux 会话中检出 `~/.heeler/worktrees/<repository>/<branch>`。要移除它，轻点 **More > Worktree Details > Remove Worktree**；Heeler 会先关闭该 worktree 会话的所有窗格，再移除检出目录。

## 使用 Agent

即使同一个 tmux 窗口被拆分为多个窗格，实时终端也会单独打开目标 Pane，任何查看者无需 Take Over 步骤即可直接输入：

- **窗口尺寸：** 当你在 iPhone 或 iPad 上查看某个 Pane 时，Heeler 会将该窗口调整为适合屏幕的尺寸，并保持在同一窗口已打开的桌面终端范围内。离开该 Pane 后会将窗口尺寸交还给其他客户端，同一会话中的其他窗口则不会被调整尺寸。
- **Send 与 Stop：** **Send** 在确认同一个 Agent 仍位于窗格前台、未处于 **Blocked** 状态且可接收粘贴后，才会粘贴草稿并按下回车。当状态为 **Working** 或 **Blocked** 且草稿为空时，对所有受支持的 Agent（包括 Grok Build），**Send** 都会变为 **Stop**。
- **Add：** 在 Composer 中轻点 **Add**，或在 Direct Input 的 **More** 菜单中轻点 **Add Image**、**Paste Image** 或 **Add File**，通过 SFTP 上传图片或文件并插入其路径。
- **Changes 与 Skills：** 从 Agent 标题栏或 **More** 菜单打开 **Changes** 以查看所在目录未提交的 Git 变更，并在 Composer、Direct Input 或 Chat 中使用 `/` 或 **Skills** 浏览并插入 Host 上的技能。
- **Close：** 关闭 Agent 或终端会关闭其对应的窗格或窗口。

### Direct Input 中的换行键

在 tmux 默认的 `extended-keys off` 下，tmux 不会把 **Shift-Return** 等带修饰键的回车作为独立按键转发，Heeler 也会扣留 tmux 尚未启用的扩展按键，以免将按键名称当作普通文本输入到窗格中：

| 按键 | 在 tmux 中的行为 |
| --- | --- |
| **Control-J** | 无需修改 tmux 设置，即可在 Claude Code、Codex、Grok Build、OpenCode、Pi 和 Oh My Pi 中换行。 |
| **Option-Return** | 可在 Claude Code、Codex、Grok Build、OpenCode 和 Oh My Pi 中换行；在 Pi 中会直接提交。 |
| **Shift-Return** | 在 tmux 3.5 或更新版本且 `~/.tmux.conf` 设置了 `set -g extended-keys on` 时，可在 Claude Code、OpenCode、Pi 和 Oh My Pi 中换行。在 Codex 和 Grok Build 中从 Heeler 发送 **Shift-Return** 不会生效，请改用 **Control-J** 或 **Option-Return**。 |

当 Composer 中的 **Send** 或 **Stop** 无法干净地完成时，会保留你的草稿并显示[与 herdr-core 相同的恢复提示](herdr-core.md#使用-agent)。

## Claude Code hooks

通过 **New Agent** 启动的 Claude Code Agent 会自动上报 **Working**、**Blocked**、**Done**、**Error** 及其会话，无需修改 `~/.claude/settings.json`。

若想让你自己在 tmux 终端中手动启动的 Claude Code Agent 也获得同样的状态与 [Chat](#chat) 会话提示：

1. 连接该 Host，在 **Hosts** 中打开它，找到 **Claude Code Hooks**。
2. 在 **Default**（`~/.claude/settings.json`）或任意已添加的 [Claude Code Account](usage.md#添加-claude-code-account) 上轻点 **Add Hooks**。
3. 查看 Heeler 将写入的具体设置差异与脚本文件，然后轻点 **Apply This Change**。

**成功的标志是** **Claude Code Hooks** 中该配置目录所在行显示为 **On**。

- 这些 hooks 不依赖 [Host Helper](#host-helper) 即可生效，且当 Claude Code 在 tmux 之外运行时（包括在 Herdr TUI 或 herdr-core 下）不会执行任何操作。
- 在尚未信任的文件夹中，Claude Code 在你接受信任提示之前不会运行任何 hook，在此之前该 Agent 会显示 **Unknown**。
- 在 Claude Code 中批准权限请求后，耗时较长的工具执行期间 Agent 可能保持 **Blocked**，此时 Composer 中仍可使用 **Stop**。如果在 Claude Code 等待模型响应时从桌面终端按 Esc 中断，状态可能保持 **Working** 直到下一次事件。
- 日后如需移除这些 hooks，回到 **Claude Code Hooks**，轻点 **Remove Hooks**，再轻点 **Apply This Change**。

## Chat

在 **Chat** 中，你可以阅读对话、**Send** 消息、**Stop** 当前轮次，并通过按钮回答 **Blocked** 提示，全程不会改变你的 tmux 窗口尺寸：

| 程序 | 会话说明 |
| --- | --- |
| Claude Code | 通过 **New Agent** 启动或搭配 [Claude Code hooks](#claude-code-hooks) 时跟随 `/clear` 与 `/resume`；否则请使用 **Choose a Conversation**。 |
| Codex | 以 `--no-daemon` 启动时在首条消息后绑定（参见[为什么需要 `--no-daemon`](chat.md#配置-host)）。 |
| Grok Build | 当 Grok Build 只列出一个对话时绑定；执行 `/new` 后，请重启或使用 **Choose a Conversation**。 |
| Pi | 通过 **New Agent** 启动或搭配 [Host Helper](#host-helper) 时绑定；否则请使用 **Choose a Conversation**。 |
| Oh My Pi | 搭配 [Host Helper](#host-helper)，或在首条消息打开其会话文件后绑定；否则请使用 **Choose a Conversation**。 |
| OpenCode | 在 tmux Host 上关闭。仅提供终端视图。 |

当 Chat 无法证实某个 Pane 当前显示的是哪个对话时，会显示 **Can't Tell the Conversation** 以及 **Check Again** 和 **Choose a Conversation**。选择对话并轻点 **Use This Conversation** 后，在该 Agent 或 tmux 服务端结束之前，Heeler 都会为该 Pane 记住这一选择。

## Host Helper

日常使用终端与 Chat 不需要 Host Helper。在装有 Node.js 20 或更新版本的 macOS 或 Linux 上安装它，可额外启用：

- **Agent Notifications**（**Blocked**、**Error** 与 **Done**）、应用内横幅以及 **Live Activity**；
- **[Usage](usage.md)**（Token Usage、Usage Limits 以及主屏幕和锁定屏幕小组件）；
- **Codex、Grok Build 与 OpenCode 状态：** 为运行这些程序的窗格上报状态（Grok Build 还需开启 **Turn On Grok Build's Status**）；
- **Pi 与 Oh My Pi 状态及 Chat：** 安装 Heeler 扩展，使你手动启动的窗格也能上报 **Idle**、**Working**、**Done**、**Error** 及当前 Chat 对话；
- **Claude Code 桌面端 Esc 清理：** 当你在桌面端按 Esc 拒绝权限提示时自动清除 **Blocked**。

在 **Hosts** 中打开该 Host，轻点 **Host Helper**，查看 **Files This Writes**，轻点 **Install**，并在 **Settings > Notifications** 下开启该 Host，具体步骤与状态说明同[连接 herdr-core](herdr-core.md#host-helper)。移除 Host Helper 后，你已添加的 [Claude Code hooks](#claude-code-hooks) 仍会继续工作。

## 已知限制

- **仅限装有 tmux 3.3 或更新版本的 macOS 和 Linux：** 不支持原生 Windows，且仅支持通过 `-L` socket 名称而非自定义 `-S` 路径指定 tmux 服务端。
- **早于 3.5 的 tmux：** **Shift-Return** 不会送达 Agent；请改用 **Control-J**（或在 Pi 之外使用 **Option-Return**）。
- **`window-size largest` 下缩小桌面终端：** 当其他终端自行改变尺寸时 tmux 不会发出通知，因此在 `window-size largest` 下，若桌面终端未分离或切换窗口而直接缩小，窗口尺寸会在下一次窗口或客户端变动时才重新收紧；若读取客户端尺寸失败，Heeler 不会改动窗口尺寸。
- **不提供 Templates、Take Over 或重命名 Agent/Tab：** 不提供 herdr-core Templates、Take Over、窗格缩放，也不支持从 Heeler 重命名 Agent 或 Tab；窗格标题由程序自身设置，Tab 名称跟随 tmux 窗口名称。
- **OpenCode Chat 已关闭：** OpenCode Agent 仅提供实时终端视图，且 OpenCode 在 tmux 中的状态支持来自源码审阅而非实机运行。
- **Pi 与 Oh My Pi 扩展：** 扩展会上报 **Idle**、**Working**、**Done** 与 **Error**，不上报 **Blocked**；通过 `npx` 启动的 Pi 不会加载扩展。
- **已重定向输出的窗格：** 如果你已经在 tmux 中自行重定向某个窗格的输出，Heeler 不会改动它，其中的 Codex、Grok Build 或 OpenCode 会保持 **Unknown**。
- **包装脚本：** 以子进程方式启动 Agent 的脚本会留在 **Terminals** 中；请在脚本末尾使用 `exec`（例如 `exec claude "$@"`），让 Agent 直接主导窗格。
- **目前的实测范围：** tmux Host 已在搭载 tmux 3.3a 与 3.7b 的 macOS 自动化 SSH 测试夹具上验证；Linux Host（包括通过 **New Workspace** 启动已停止的服务端）以及在真实机器上搭配实时 Agent、**Chat**、Claude Code hooks 和 Host Helper 的完整应用流程尚未实机运行。

最后核对于 2026-11-12，核对依据为 macOS 测试夹具上的 tmux 3.3a 与 3.7b。
