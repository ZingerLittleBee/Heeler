<!-- Translated from docs/guides/rex.md at 56f5cb32 -->
# 连接 Rex

通过 SSH 将 Heeler 连接到 Mac、Linux 或 Windows Host 上已在运行的 Rex 服务端，在 Rex 继续运行这些终端的同时，在 iPhone 或 iPad 上打开它们。Host 上的 Rex 服务端在 Heeler 中是该 Host 的一个 Server，与 Herdr TUI、[herdr-core](herdr-core.md) 和 [tmux](tmux.md) 并列。

> [!IMPORTANT]
> Rex 支持仍处于实验阶段。它基于 macOS 上的 Rex 0.1.0-preview.14（Rex API revision 12）开发和测试，可以打开 Rex 中已有的终端和 Agent，并能新建 Shell：请参阅[尚未支持的功能](#尚未支持的功能)与[已知限制](#已知限制)。

## 开始之前

- 0.1.20 之后的 Heeler 版本。
- Host 上的 Rex 以你通过 SSH 登录的账户运行。Heeler 只连接已在运行的 Rex 服务端，绝不会自行启动。
- 在 Mac 上开启“远程登录”并记录其 SSH 指纹：[准备 Host](overlay-networks.md#准备-host)。在 Linux 上运行 OpenSSH。在 Windows 上运行 Win32-OpenSSH，并让 `rex.exe` 位于该账户的 PATH 中（WinGet 安装时即如此）；Heeler 通过 Rex 自带的 stdio 桥接连接服务端，那里的 [Chat](#chat) 支持 Claude Code。
- 在 Mac 或 Linux 上，SSH 服务端允许转发到 Unix socket，OpenSSH 默认即允许。如果它的 `sshd_config` 设置了 `AllowStreamLocalForwarding no` 或 `AllowTcpForwarding no`，Heeler 将无法连接 Rex。
- 让 iPhone 或 iPad 能够连通 Host：处于同一局域网下直连、通过 [Overlay Network](overlay-networks.md) 连接，或经由 [Jump Host](vps-jump-host-setup.md) 中转。一个 Host 可以配置[多条路由](host-routes.md)。

## 添加 Host

Heeler 在连接或检查时绝不会启动 Rex；在你轻点 [New Terminal](#new-terminal) 之前，也不会在其中启动任何东西。在 Mac 或 Linux 上它从不运行 `rex` 命令；在 Windows 上，由于 SSH 无法直接访问 Rex 的命名管道，每个连接都会运行 `rex __internal dial-stdio --autostart=false`，即 Rex 自己的命令通过 SSH 使用的桥接，它不会启动服务端。

### 1. 连接

1. 在 **Hosts** 中轻点 **+**，列表为空时轻点 **Add Manually**。也可以改为[扫描配对码](pairing.md#配对没有-herdr-的机器)，这样会跳过本步骤，直接进入[选择 Server](#2-选择-server)。
2. 输入 **Address**，并以运行 Rex 的账户作为 SSH **User**。端口、Jump Host 和 Overlay Network 在 **More Options** 中。
3. 选择 **Device Key**、**RSA Key** 或 **Password**。若选择 **Device Key**，请将公钥行复制到 Host 的 `~/.ssh/authorized_keys` 中。
4. 轻点 **Connect**，核对 Host 的密钥指纹，然后轻点 **Trust and Continue**。

| Connect | Trust |
| --- | --- |
| <a href="../images/hosts/add-host-connect.png"><img src="../images/hosts/add-host-connect.png" width="260" alt="New Host 面板的 Connect 步骤，包含 Address、User、More Options 和 Connect 按钮"></a> | <a href="../images/hosts/add-host-trust.png"><img src="../images/hosts/add-host-trust.png" width="260" alt="New Host 面板的 Trust 步骤，显示 Trust this Host?、密钥指纹、Copy the Command That Prints It 和 Trust and Continue"></a> |

### 2. 选择 Server

Heeler 会通过你的登录 shell 在不启动任何服务的情况下查看一次，并列出这台机器上运行的内容。一个 Host 只有一个 Rex Server，显示为 **Rex**：

| Heeler 检测到 | 操作方法 |
| --- | --- |
| **Rex** 显示 **Running** | 保持勾选 **Rex**，然后轻点 **Add Host with 1 Server**。 |
| **Rex** 显示 **Not running** | Rex 已安装但没有运行，因此 **Rex** 默认不勾选。勾选 **Rex**，等你启动 Rex 后它就会连接。也可以先不勾选它添加 Host，然后启动 Rex，打开该 Host，轻点 **Scan Again**，再开启 **Rex**。 |
| 同时检测到 Rex 与 Herdr TUI、herdr-core 或 tmux | 勾选你想在 Heeler 中使用的每一个。它们都是这同一个 Host 的 Server。 |
| 没有 **Rex** | Rex 没有安装。仍然添加该 Host，安装并启动 Rex，打开该 Host，轻点 **Scan Again**，然后开启 **Rex**。 |

每个 Server 在 Host 页面上都有一个开关。**Rex** 开启后，轻点它可打开它自己的页面，其中有它的检查项。连接属于 Host，显示在 **Routes** 下。**Add by Name…** 不提供 Rex：一个 Host 唯一的 Rex Server 没有需要输入的名称，而且只要装了 Rex，Heeler 就会列出它。

如果 Host 页面上的 **Rex** 显示 **Socket found, but this account cannot use it**，说明 Rex 以另一个账户运行。请以该账户作为 **User**，把这台机器另外添加为一个 Host。

**成功的标志是**该 Host 所在的行显示绿色的 **Rex** 标签，该 Host 的页面将 Rex 列为 **Running**，且该 Server 的页面上 **SSH connection**、**Rex installed**、**Rex server running** 与 **protocol compatible** 均通过。

## 无法连接时

| Host 显示 | 操作方法 |
| --- | --- |
| **Rex is not running** | 在 Host 上启动 Rex，然后轻点 **Run Checks Again**。 |
| **The SSH server refuses socket forwarding** | 在 Host 的 SSH 服务端中允许转发到 Unix socket（参见[开始之前](#开始之前)），然后轻点 **Run Checks Again**。 |
| **Rex is not answering** | Heeler 无法判断是以上哪一种情况。请两项都检查，然后轻点 **Run Checks Again**。 |
| **Rex did not let this account in** | Rex 以另一个账户运行。请以该账户作为 **User**，把这台机器另外添加为一个 Host。 |
| **This version of Rex is not supported** | Heeler 支持 Rex API revision 12 到 19。如果提示中 Rex 提供的 revision 更旧，请升级 Rex；如果更新，请等待 Heeler 更新。 |
| **Rex was not found on this Host** | 安装并启动 Rex，然后轻点 **Run Checks Again**。 |

## 控制台

Heeler 按原样显示你的 Rex 结构，只有在你新建 [New Terminal](#new-terminal) 时才会改动它：

- **Workspaces、Tabs 与 Panes：** 按 Rex 自身的顺序，每个 Rex 会话（session）是一个 Workspace，每个窗口（window）是一个 Tab，每个终端是一个 Pane。会话中不属于任何窗口的终端共用一个名为 **Detached** 的 Tab。没有终端的会话不会列出。
- **Agents 与 Terminals：** 程序为 Claude Code、Codex 或 Heeler 认识的其他编程 Agent 的终端显示在 **Agents** 中，并带有该 Agent 向 Rex 上报的状态。Shell 和其他程序显示在 **Terminals** 中；Agent 退出后，终端会回到 **Terminals**。终端全是 Agent 的会话在 **Terminals** 中显示为只含 **New Terminal** 的卡片。标题、程序与目录会随 Rex 中的变化同步更新。

| 状态 | 含义 |
| --- | --- |
| **Working** | 正在运行一轮对话。 |
| **Idle** | 在提示符处等待。 |
| **Blocked** | 等待你的回答。 |
| **Error** | 上报了错误，并与 **Blocked** 一起排序。 |
| **Done** | 在当前设备未打开该 Agent 时完成了一轮对话。打开该 Agent 仅会清除当前设备上的 **Done**。 |
| **Unknown** | 该 Agent 尚未向 Rex 上报状态，或最近一次上报来自另一个程序，例如一个已经退出的程序。 |

作为 Rex 终端自身命令（而不是从其 Shell）启动的 Agent，以及用 `exec` 启动的 Agent，会留在 **Terminals** 中。Heeler 要等终端下一次输出时才能看到其程序的变化，因此 Agent 出现在 **Agents** 中或从中离开可能会稍有延迟。

## 使用终端

在 **Terminals** 中轻点一个终端即可打开。在 **Agents** 中轻点的 Agent 会像其他 Host 上的 Agent 一样打开，带有 [Chat](#chat) 和它的终端；如果打开期间 Agent 退出，会显示 **Agent Gone**，终端回到 **Terminals**。你操作期间，其他 Rex 客户端会继续显示它：

- **打开：** 终端会在 Rex 重绘完屏幕和历史记录后显示，因此在较慢的连接上，较长的历史记录可能需要几秒钟。持续输出的程序（例如 spinner）在暂停之前，可能有几行重复或错位；暂停后 Heeler 会重新绘制。
- **输入与粘贴：** 在 Text 或 Keys 模式下输入、轻点 **Paste**，或发送 Snippet。无论终端尺寸由哪台设备设定，你都可以输入。你输入的内容按顺序到达终端，Heeler 绝不会重复发送：如果连接在 Rex 回复前断开，终端会显示 **Connection dropped** 和 **Reattach**，此后输入的内容都没有发送。Heeler 重新连接期间输入的按键同样不会发送；终端会重新连接并重新绘制。过大、无法一次发送的粘贴会被阻止而不会拆分；请分几次粘贴。
- **结束：** 当终端在 Rex 中关闭或其中的程序退出时，它的视图随之结束。

终端停止时会说明原因：

| 终端显示 | 操作方法 |
| --- | --- |
| **Connection dropped** | 你输入的内容可能没有送达。轻点 **Reattach**，确认屏幕内容后再继续输入。 |
| **This terminal's history is too long to show** | 在 Rex 中清除该终端的回滚记录，然后轻点 **Reattach**。 |
| **Rex stopped sending this terminal's output** | Host 保持连接期间，Rex 停止了该终端的输出。轻点 **Reattach**。如果是与 Host 的连接断开，终端会自行重新连接并重新绘制，不会显示这条消息。 |
| **This Terminal belongs to a Rex server that is gone** | Rex 已重启。请从 **Terminals** 重新打开该终端。 |

### 适配你的屏幕

Rex 终端只有一个尺寸，同一时间由一台设备设定。从 **Terminals** 打开 Rex 终端，或显示 Agent 的终端时，Heeler 会在显示之前先把它适配到你的屏幕。Chat 从不调整终端尺寸。Rex 调整的是终端本身而不只是你看到的视图，因此在你在这里打开它期间，所有显示它的设备（包括 Mac 上的 Rex 应用）都会变成你屏幕的尺寸。当你离开该终端、Heeler 进入后台或终端结束时，Heeler 会交还尺寸，原先设定尺寸的设备会重新拿回。再次回来时会重新适配。

### Sized for another device

如果在你打开终端期间，另一台设备（例如 Rex 应用）取走了尺寸，Heeler 会让该设备保留它，不会自动取回。适配没有成功时也是如此。此时 Heeler 会按该设备的尺寸显示终端，不会缩放：比屏幕宽的行会折到下一行，因此占满整行宽度的程序（例如表格或编辑器）可能显示错乱。约一秒后终端上会出现 **Sized for another device**：输出只占上半部分时它在底部，否则在顶部，以免挡住提示符：

- **Fit to Screen** 会把尺寸取回，适配你的屏幕。
- 轻点 **×** 按钮关闭提示，在你停留期间保留其他设备设定的尺寸。当又有另一台设备设定尺寸时，提示会再次出现。
- 如果轻点 **Fit to Screen** 后没有适配成功，提示会说明原因，轻点 **Try Again** 可再试一次。

离开该终端再回来，会重新适配你的屏幕。

在 iPad 上，同一 Host 的 Rex Agent 终端同一时间只在一个窗口中显示。另一个窗口打开它时会显示 **Live in Another Window**；轻点 **Take Over Here** 即可移到该窗口。

## New Terminal

Heeler 会像 Rex 自己的 New Terminal 一样，在 Rex 的新窗口中启动一个 Shell：

- **在现有 Workspace 中：** 在 **Terminals** 中轻点 Workspace 卡片末尾的 **New Terminal**，或轻点 **+** 并选择该 Workspace。Rex 会在该会话的新窗口中、以 Workspace 的目录打开 Shell。新窗口在后台打开：Mac 上的 Rex app 仍显示原来的窗口。
- **在新 Workspace 中：** 在 **+** 面板中选择 **New Workspace**，浏览到某个目录，或留空以使用你的主目录。Rex 会新建一个包含该 Shell 的会话，名称为你输入的名字；名字留空时以目录名命名。这里没有 Tab 名称可填。
- **打开：** Rex 列出新终端后，它会立即在这里打开，像其他终端一样适配你的屏幕，离开时交还尺寸。
- **Rex 没有应答时：** Heeler 绝不会向 Rex 发送两次请求。如果错误提示 Rex 没有应答，终端可能仍已创建：请先查看 **Terminals** 再重试。

要启动 Agent，请先打开 New Terminal，再在其中启动。Agent 运行后会移到 **Agents**。

## Chat

在 macOS 和 Linux 上，Rex 中的 Claude Code、Codex、Pi 和 Oh My Pi 可以使用 **Chat**；在 Windows 上，Rex 中的 Claude Code 可以使用。Claude Code 和 Codex 无需在 Host 上安装任何东西；Pi 和 Oh My Pi 需要 [Heeler 的扩展](#pi-与-oh-my-pi)，Chat 会提示你添加。Heeler 通过 Host 的 SSH 连接读取对话，并经由 Rex 向终端输入，不会调整终端尺寸。你可以阅读对话、**Send** 消息、**Stop** 一轮对话，以及在 **Blocked** 提示上轻点按钮作答：

| 程序 | 会话说明 |
| --- | --- |
| Claude Code | 根据正在运行的 Claude Code 本身绑定，在 Windows 上也是如此。执行 `/clear` 或 `/resume` 后，Chat 会在发送你的下一条消息前重新检查。 |
| Codex | 在它持有对话文件后（首条消息之后）绑定。请用 `--no-daemon` 启动它（[原因](chat.md#配置-host)）；否则 Chat 会显示 [**Codex Started Without --no-daemon**](chat-troubleshooting.md#codex-started-without---no-daemon)，而不显示对话。 |
| Pi | 通过 [Heeler 的扩展](#pi-与-oh-my-pi)绑定，Pi 一启动即可。执行 `/new` 后，Chat 会在发送你的下一条消息前重新检查。 |
| Oh My Pi | 通过 [Heeler 的扩展](#pi-与-oh-my-pi)绑定，Oh My Pi 一启动即可。没有扩展时，Chat 会在它的首条消息之后跟上对话。执行 `/new` 后，Chat 会在发送你的下一条消息前重新检查。 |
| 其他 Agent | Rex Host 上暂不提供 Chat，会以其终端打开。在 Windows 上，Codex、Pi 和 Oh My Pi 也是如此。 |

- **Can't Tell the Conversation：** 当 Chat 无法证实 Agent 显示的是哪个对话时，会这样提示并提供 **Check Again**。对于 Claude Code 和 Codex，轻点 **Choose a Conversation**，预览一个对话后轻点 **Use This Conversation**。Heeler 会在当前设备上为这个终端记住这个选择，直到该 Agent 退出或 Rex 重启。Host 上不会写入任何内容。对于 Pi 和 Oh My Pi，请改为[添加 Heeler 的扩展](#pi-与-oh-my-pi)。
- **Send：** **Send** 会先确认仍是同一个 Agent 占据终端、它不处于 **Blocked**，并且接受粘贴，然后粘贴你的消息并按下 Enter。终端下方的 Composer 也以同样方式发送。如果 Rex 没有回应，Heeler 绝不会重新发送该消息；请先查看终端。
- **Stop 和 Blocked 提示取决于 Agent 的状态：** 当 Agent 显示 **Working** 且消息为空时，**Send** 会变成 **Stop**，先确认仍是同一个 Agent 占据终端，再按下 Esc。Agent 显示 **Blocked** 时会出现带按钮的卡片。不向 Rex 上报状态的 Agent 显示为 **Unknown**：既没有 **Stop**，也没有卡片，请在它的终端中停止或作答。Claude Code 的回合已经结束、但它放到后台的命令还在运行时，显示为 **Done** 或 **Idle**，你可以直接发送下一条消息；**Stop** 不会结束这条后台命令，请在终端中结束它。
- **命令：** 在 Agent 上报空闲时，`/` 提供 `/compact`，不提供 Agent 的技能。其他操作请在终端中完成。
- **图片和文件：** 在 Chat 或 Agent 的终端中轻点 **+**，再选择 **Add Image**、**Paste Image** 或 **Add File**。Heeler 通过 Host 的 SSH 连接（而不是经由 Rex）把文件上传到你登录所用账户的临时目录下的一个新文件夹（在 Windows 上是其用户文件夹中的 `AppData\Local\Temp`），并把路径加到你的消息里；**Send** 会把路径连同消息一起输入，且只输入一次。图片以不超过 16 MiB 的 JPEG 或 PNG 发送，文件最大 64 MiB。Heeler 从不删除已上传到 Host 的文件。如果 Rex 重启，之后开始的上传会停止并显示 **This Terminal belongs to a Rex server that is gone**；已在进行的上传会完成，文件留在 Host 上，但 **Send** 随后会以同样的提示拒绝发送。请从列表中重新打开该 Agent。

### Pi 与 Oh My Pi

Pi 和 Oh My Pi 通过 Heeler 的扩展告诉 Chat 自己正处于哪个对话。扩展是一个名为 `heeler-session.js` 的文件，放在该 Agent 自己的扩展文件夹中，例如 `~/.pi/agent/extensions`。Rex 没有 Host Helper 来安装它，所以由 Chat 来询问你：

1. 打开该 Agent 并显示 **Chat**。它会显示 **Can't Tell the Conversation**，并提供 **Add Heeler's Extension…**。
2. 轻点 **Add Heeler's Extension…**。Heeler 会显示它将写入的唯一一个文件夹，这个文件夹是根据正在运行的 Agent 找到的。
3. 轻点 **Add to This Folder**。Heeler 通过 Host 的 SSH 连接写入这个文件，替换其中的旧版本，不会写入其他内容。
4. 退出该 Agent，并在同一个终端中重新启动它。它会在启动时加载扩展。

**成功的标志：** Agent 启动几秒后，Chat 自行显示它的对话。

- **仍然显示 Can't Tell the Conversation：** 如果提示说该 Agent 尚未加载扩展，说明它是在你添加扩展之前启动的，或者启动时带了 `--no-extensions`。请在启用扩展的情况下重新启动它。
- **扩展做了什么：** Pi 和 Oh My Pi 会为 Host 上的每个会话加载它。在 Rex 终端中，它会在扩展文件夹旁的 `heeler-session` 文件夹里为每个正在运行的 Agent 保留一个记录对话的小文件，并在 Agent 退出时删除。在 Rex、tmux 和 herdr-core 之外，它什么也不做。
- **移除扩展：** 从扩展文件夹中删除 `heeler-session.js`，并删除它旁边的 `heeler-session` 文件夹。

## 尚未支持的功能

- **只有状态、Chat 和附件：** Rex 没有 Changes、Skills、Agent Notifications、Live Activities、Usage 或小组件。同一 Host 的其他 Server 不受影响。
- **不提供 New Agent、Rename 与 Close：** Heeler 只启动 Shell。请在 [New Terminal](#new-terminal) 中启动 Agent，并在 Rex 中重命名或关闭；Heeler 会显示结果。
- **Rex 不支持 Worktrees、Host Helper 与 Add by Name。**

## 已知限制

- **支持 Rex API revision 12 到 19：** Heeler 提供 revision 19，并接受 12 及以上的 revision，由 Rex 选择双方都支持的最新 revision。两者没有共同 revision 的 Rex 会被拒绝。Heeler 基于 Rex 0.1.0-preview.14（revision 12）开发，并在 Rex 0.1.0-preview.23（revision 19）上核对过。
- **尚未在 Linux 上试用：** Heeler 会在 Linux 上 Rex 存放 socket 的位置查找，但还没有用 Linux 上的 Rex 服务端实际试过。
- **颜色、光标形状和历史记录：** Rex 终端使用它自己的配色，与 Rex 中显示的一致；只有 Rex 保持内置颜色的部分才使用你的 Heeler 主题配色。Rex 不提供终端的光标形状，因此在程序重新设置之前光标保持 Heeler 的形状。全屏程序打开期间，其后方的历史记录要等程序关闭后才会显示。
- **其他设备的尺寸不会适配屏幕：** 当终端保持着其他设备设定的、比你的屏幕更宽的尺寸时（见 [Sized for another device](#sized-for-another-device)），终端的行会按你的屏幕宽度折行，占满整行宽度的程序可能显示错乱。只要终端屏幕上有比你的屏幕更宽的行，光标、新的输出和你输入的内容也可能落在错误的行上，覆盖之前的文字，直到 **Fit to Screen** 重新绘制。Heeler 不会将其缩小显示，也不会截掉超出的部分。
- **目前的测试范围：** Rex 已在 iOS 模拟器中、针对 macOS 上的 Rex 0.1.0-preview.14 试用过，并由测试客户端代替其他设备。除了在 iPhone 上从 Chat 发出的一条消息（见下文），尚未在实体 iPhone 或 iPad 上试用。也尚未在 Rex 应用显示同一终端时试用。
- **Chat 搭配真实的 Agent 只在模拟器中试过：** 在 iOS 模拟器中，Chat 已搭配在 macOS 上的 Rex 中运行的真实 Claude Code、Codex、Pi 和 Oh My Pi 试用：四者都试过阅读对话、**Send** 和 **Stop**，Claude Code 和 Codex 还试过 **Blocked** 提示上的按钮。在 iPhone 上，从 Chat 发出的一条消息送达了在 Rex 中运行的真实 Codex 0.169.0，并得到了回答。那是较早的构建，Codex 的回答里出现链接之后，它拒绝了之后的每一次 Send。Chat 现在能读懂这类链接，但之后还没有在 iPhone 或 iPad 上再试过 Chat。Pi 和 Oh My Pi 尚未在 Linux 上试用，也未搭配 Oh My Pi 的配置文件夹试用。
- **上传尚未在实体设备上试用：** 图片和文件已在 iOS 模拟器中针对运行中的 Rex 服务端试用：图片搭配了真实的 Claude Code、Codex、Grok Build、Antigravity CLI、Pi 和 Oh My Pi，文本文件搭配了 Claude Code 和 Codex。尚未在实体 iPhone 或 iPad 上试用。
- **Windows 上的 Chat 逐步检查过：** 针对 Windows 11 上的 Rex 0.1.0-preview.23，Rex 终端中三个真实的 Claude Code 2.1.332 Agent 都被 Chat 在那里运行的进程读取找到，与各自的对话对应上，并通过 SFTP 读取了它们的对话文件。在该账户的 `AppData\Local\Temp` 中通过 SFTP 创建暂存文件夹、写入、重命名并删除文件也都可行。Windows 上的 Chat 和上传尚未在应用中完整试用。

最后核对于 2026-11-18，基于 macOS 上的 Rex 0.1.0-preview.14（API revision 12），使用测试程序进行，并在 iOS 模拟器中搭配了真实的 Agent。
