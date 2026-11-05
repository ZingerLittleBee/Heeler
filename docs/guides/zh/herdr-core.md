<!-- Translated from docs/guides/herdr-core.md at 53f78222 -->

# 连接 herdr-core

在 Herdr 桌面端启动的 Agent 归属于 `herdr-core`，它与 Herdr TUI（`herdr`）是两个相互独立的服务。即使使用同一个 SSH 账号登录同一台机器，桌面端的 Agent 也不会出现在 Herdr TUI 的主机条目里，因此在 Heeler 中每个服务都对应单独的主机条目。大多数人在 Mac 上搭配 Herdr 桌面端运行 `herdr-core`；Heeler 也支持连接 Linux 上的 `herdr-core` 以及[原生 Windows](#native-windows) 上的 `herdr-core.exe`。

## 添加主机

Heeler 在连接或执行环境检查时绝不会自动启动 `herdr-core`。请先在目标机器上启动 Herdr 桌面端或 `herdr-core`。

### 1. 填写 SSH 连接设置

1. 在 **Hosts** 页面轻点 **Add Host**（列表为空时轻点 **Add Manually**）。配对码始终只会添加 Herdr TUI 主机。
2. 填写 SSH **User**、添加路由，并选择 **Device Key**（将公钥写入目标机器的 `~/.ssh/authorized_keys`）、**RSA Key** 或 **Password**。
3. 按需填写 **Session name**，轻点 **Save**，核对主机密钥指纹无误后轻点 **Trust**。

| 字段 | 值 |
| --- | --- |
| **Session name** | 留空表示使用 `default`，或填写该 `herdr-core` 会话对应的 `HC_SESSION` 名称 |

### 2. 确认 Server Kind

Heeler 会在不启动任何服务的前提下检查一次目标机器的运行环境，随后请你确认 **Server Kind**：

- 当检测到 `herdr-core` 时，轻点 **Use herdr-core**。
- 如果同时检测到 `herdr-core` 与 Herdr TUI（或两者都尚未启动），在此条目中确认 **Use herdr-core**；若还需要连接 Herdr TUI，请再添加一条主机并选择 **Use Herdr TUI**。

一旦确认，该主机条目的 **Server Kind** 即固定不变。

**成功的标志是** 主机详情页显示 **Server Kind** 为 `herdr-core`、附上服务端版本号，且 `herdr-core running` 检查项通过。

## 无法连接时的排查方法

当 `herdr-core` 处于停止状态时，Heeler 会自动定期重检，你也可以随时轻点 **Run Checks Again**：

| 主机显示 | 处理方式 |
| --- | --- |
| **herdr-core is not running** | 在主机上启动 Herdr 桌面端或 `herdr-core`，或检查 **Session** 名称。若崩溃后残留了套接字文件，请重新启动 `herdr-core` 或在 `sshd_config` 中开启本地套接字转发。 |
| **herdr-core is not installed** | 将 `herdr-core` 安装到 SSH `PATH`、`~/.local/bin/herdr-core`，或通过 Windows 安装程序安装，随后轻点 **Run Checks Again**。 |
| **herdr-core needs an update** | 在主机上运行主机详情页给出的更新命令，然后轻点 **Run Checks Again**。 |
| **The SSH server refuses socket forwarding** | 在 `sshd_config` 中设置 `AllowStreamLocalForwarding yes` 并重载 `sshd`，随后轻点 **Run Checks Again**。 |
| **The herdr-core socket path is too long** | 改用更短的会话名称或套接字路径。 |

在 Linux 主机上，当 `herdr-core` 未运行时，可轻点检查列表下方的 **Start herdr-core** 并确认 **Start**，通过登录 Shell 启动会话并自动开启 `systemd` linger；在 macOS 与 Windows 上，主机详情页会直接给出需要在目标机器上运行的命令。

## 控制台

当 `herdr-core` 由 Herdr 桌面端管理时，Heeler 会同步桌面端的 Space 与标签页：

- **桌面端 Space 与标签页：** 每个桌面端 Space 按桌面端的顺序显示为一张工作区卡片，标签页显示为 **Tab “name”** 或 **Tab N**。
- **其他终端：** 子终端会归入其父终端所在的卡片；不属于任何桌面端 Space 的其他终端按 Git 仓库目录或启动目录分组。
- **Agents 与 Terminals：** 已知的编程 Agent 以及上报状态的非 Shell 程序显示在 **Agents** 中；普通交互式 Shell 留在 **Terminals** 中。

| 状态 | 含义 |
| --- | --- |
| **Working** / **Idle** | 正在执行一轮任务（**Working**），或在提示符前等待输入（**Idle**）。 |
| **Blocked** / **Error** | 正在等待你回答提示（**Blocked**），或上报了错误（**Error**，与 **Blocked** 一起置顶排序）。 |
| **Done** | 按设备独立记录：Agent 在当前设备未打开它时完成了一轮回复；在此设备上打开该 Agent 只会清除本设备的 **Done**。 |
| **Unknown** | 尚未上报状态。轻点状态栏上的 **Unknown** 可查看原因；对于 macOS 或 Linux 上的 Grok Build，可轻点 **Turn On Grok Build's Status** 与 **Apply This Change**，在 `~/.grok/config.toml` 中写入 `program_status = "on"`（可随时在该面板轻点 **Undo** 或在主机详情页的 **Harness Edits** 中撤销）。 |

在 macOS 与 Linux 上，当 Herdr 桌面端正在运行时，打开该空间内任一 Agent 的输入框 **More** 菜单（位于 **Add** 旁）并轻点 **Rename Workspace**，即可同时在两端重命名该桌面空间。

## 启动终端、Agent 与工作区

- **New Agent：** 轻点 **New Agent**，选择工作区，并从登录 Shell `PATH` 检测到的列表中选择 Agent（或选择来自 **Settings > Agents & Accounts** 的 **Preset**）。除非你的自定义参数已经指定了会话标志，否则 Heeler 会自动传入会话标志（并为 Codex 传入 `--no-daemon`）。
- **New Terminal：** 轻点 **New Terminal** 打开登录 Shell；在桌面端 Space 中，它会作为新标签页同时出现在 Heeler 与桌面端中。
- **New Workspace：** 选择 **New Workspace**（或 **Browse Directory…**）；当 macOS 或 Linux 上的桌面端正在运行时，填写 **Workspace name (optional)** 可直接命名新空间。
- **Templates：** 保存在 `~/.config/herdr-core/templates`（或 `$XDG_CONFIG_HOME/herdr-core/templates`）中的角色会出现在 **New Agent** 的 **Templates** 分组下，并直接运行其配置的命令。
- **Worktrees：** 在 macOS 与 Linux 上，可在 **New Agent** 中开启 **Start in a new worktree** 并填写 **Branch**，将 `~/.herdr/worktrees/<repository>/<branch>` 检出为新工作区。要移除它，打开其中的 Agent 并轻点 **More > Worktree Details > Remove Worktree**。

> [!NOTE]
> 如果 `herdr-core` 从其他工具或终端复用器继承了环境变量（如 `CLAUDECODE`、`TMUX`、`HERDR_PANE_ID`），主机详情页会显示 **Core Environment** 并列出变量名及其影响；从干净的终端重新启动 `herdr-core` 即可清除。

## 与 Agent 交互

同一台主机的所有实时终端共享同一个 SSH 连接，任何设备都可以直接输入，无需接管步骤。你可以使用直接输入模式，或使用底部输入框：

- **Send 与 Stop：** **Send** 会粘贴草稿，并仅在同一个 Agent 仍持有该终端时按下回车提交。当状态为 **Working** 且草稿为空时，**Send** 会变为 **Stop**（在 Grok Build 上，请改用直接输入或扩展键盘发送 **Control-C**）。
- **Add：** 轻点输入框旁的 **Add**（或直接输入模式 **More** 菜单下的 **Add Image** / **Add File**）可将文件上传到主机并把路径插入草稿。
- **关闭：** 关闭标签页或面板会彻底终止对应的终端进程。

如果 **Send** 或 **Stop** 未能顺利完成，输入框会保留你的草稿并显示提示：

| 提示内容 | 处理方式 |
| --- | --- |
| **stayed in the Agent's input unsubmitted** / **may still be in the Agent's input** | 先查看终端，提交或清空输入框中的残留文字后再重新发送。 |
| **no longer in the terminal** / **may still be in the terminal** | Agent 在提交前已退出；请先查看终端画面。 |
| **not accepting a paste** / **keeps a shell open** | 等待 Agent 回到提示符，或改用直接输入模式（Windows 上若 Agent 退出后仍保留外层 Shell，则必须使用直接输入）。 |
| **waiting on its question on screen** / **still shows Working** / **may or may not have reached the Agent** | 先用扩展键盘或在 Chat 中回答 **Blocked** 提问，或查看终端后再次轻点 **Stop**。 |

## Chat

在 **Chat** 视图中，你可以阅读对话记录、发送消息、停止当前轮次，并通过按钮回答 **Blocked** 权限或提问：

| 程序 | 会话绑定说明 |
| --- | --- |
| Claude Code (`claude`) | 在 macOS、Linux、Windows 上可用；到达提示符后立即绑定，并自动跟随 `/clear` 与 `/resume`。 |
| Codex (`codex`) | 在 macOS、Linux 上可用；附带 `--no-daemon` 启动时在发送首条消息后绑定。 |
| Grok Build (`grok`) | 在 macOS、Linux、Windows 上可用；当工作区只有一个活动对话时自动绑定（执行 `/new` 后请重启或在 macOS/Linux 上手动选择）。 |
| Pi (`pi`), Oh My Pi (`omp`) | 在 macOS、Linux、Windows（安装扩展后）上可用；搭配 [Host Helper](#host-helper) 或 Windows 扩展时精确绑定，未安装时在 macOS/Linux 上按启动进程或首轮回复标题绑定。 |
| OpenCode (`opencode`) | 仅提供终端视图（在 `herdr-core` 主机上未启用 Chat）。 |

- **Can't Tell the Conversation：** 当 Chat 无法唯一定位该终端对应的对话记录时，会显示 **Can't Tell the Conversation**、修复建议与 **Check Again**。在 macOS 与 Linux 上，可轻点 **Choose a Conversation** 预览候选对话并轻点 **Use This Conversation**。
- **Windows 上的 Pi 与 Oh My Pi：** 在 Chat 中轻点 **Add Heeler's Extension…**，核对 `.pi\agent\extensions`、`.omp\agent\extensions` 及 Oh My Pi 配置目录后轻点 **Add to … Folders**（写入 `heeler-session.js`），随后重启 Agent。

## Host Helper

在 Linux 与 macOS 上，**Host Helper** 是 Heeler 的 Node.js 后台服务（Linux 上为 `systemd --user` 服务，macOS 上为 `launchd` LaunchAgent）。它只跟随 `herdr-core` 而不主动启动核心，并提供 **Agent Notifications**（**Settings > Notifications**）、应用内 **Banners**、**Live Activity**、**Usage**（**Token Usage**、**Usage Limits** 与桌面小组件）以及 **Pi** 和 **Oh My Pi** 的会话扩展。

### 1. 查看将写入的文件

1. 在 **Hosts** 中打开主机并轻点 **Host Helper**。
2. 查看 **Files This Writes**（Linux 上的 `~/.local/share/heeler/host-helper` 或 macOS 上的 `~/Library/Application Support/heeler/host-helper`、用户级服务文件，以及 Pi 与 Oh My Pi 的 `agent/extensions` 目录）。

### 2. 安装 Helper

1. 轻点 **Install**。
2. 在 Linux 上，如果显示 **Systemd Linger**，请轻点 **Turn On Linger**（或运行 `sudo loginctl enable-linger <user>`），以便退出 SSH 登录后服务继续在后台运行。

**成功的标志是** 主机详情页的 **Host Helper** 行显示已安装版本号，且面板顶部显示 **The Host Helper is running.**

| 行状态 | 含义与操作 |
| --- | --- |
| **Not Installed** / 版本号（如 `0.5.4`） | 轻点 **Install** 安装；有内置新版本时在面板中轻点 **Update**。 |
| **Damaged** / **Node.js Moved** / **Service Failed** | 文件被改动、Node.js 路径变化或服务停止；在面板中轻点 **Repair**。 |
| **Node.js Missing** / **Linger Off** / **Not Available** | 安装 Node.js 22+ 后轻点 **Run Checks Again**，或轻点 **Turn On Linger**；Windows 主机（及无 `systemd` 的 Linux 主机）不提供 Host Helper。 |

如需卸载，打开 **Host Helper** 并轻点 **Remove**，Heeler 会停止服务并删除其文件、Pi/Oh My Pi 扩展以及 Helper 目录（包括该主机的通知注册信息）。

## Native Windows

你可以通过 Windows 自带的 OpenSSH Server（`sshd`）添加原生 Windows 主机：

- **安装位置与启动方式：** Heeler 会查找 `%LOCALAPPDATA%\Programs\herdr-core\herdr-core.exe`，且仅在其命名管道已存在时连接。请使用主机详情页给出的命令，在 Windows 桌面会话的非管理员 PowerShell 窗口中启动 `herdr-core`。
- **支持的功能：** 控制台工作区与状态、实时终端、**New Terminal**、**New Agent**（通过 Windows PowerShell 启动）、**New Workspace**（在桌面端命名该空间前使用目录名）、输入框 **Send**、**Stop** 与 **Add**（单文件上限 8 MiB，暂存至 `%LOCALAPPDATA%\herdr-core\<session>\files\<terminal>\`），以及 Claude Code、Grok Build、Pi 与 Oh My Pi 的 **Chat**。
- **Windows 上不提供的功能：** **Rename Workspace**、**Worktrees**、**Changes**、**Skills**、**Choose a Conversation**、自动修改配置文件，以及 **Host Helper**（显示为 **Not Available**）。

## 已知限制

- **不支持重命名 Agent：** 在 `herdr-core` 主机上无法重命名单个 Agent；工作区仅支持在 macOS 或 Linux 上通过正在运行的 Herdr 桌面端重命名。
- **OpenCode 未启用 Chat：** `herdr-core` 主机上的 OpenCode Agent 仅提供终端视图。
- **未安装钩子时的进程内 `/new`：** 在 Codex 中执行 `/new` 后，请先使用终端直至退出并运行 `codex resume --no-daemon`；在未安装 Host Helper 的 Pi 中，执行 `/new` 后需等 Chat 发送消息未出现在旧记录中时才会提示重新绑定。
- **不显示跨机联邦终端：** 请将另一台机器作为独立的主机条目添加。
- **首次使用 `zsh` 且无 `~/.zshrc`：** 若登录 Shell 为 `zsh` 且没有任何启动文件，`zsh` 会弹出首次配置向导，新启动的 Agent 会停在向导后面，直到你完成向导或创建 `~/.zshrc`。

最后核对于 2026-11-06，核对依据为 herdr-core 0.1.18 与 Herdr 桌面端 0.1.13。
