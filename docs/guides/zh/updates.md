<!-- Translated from docs/guides/updates.md at 2e3f5e3d -->
# 更新 Heeler 插件与 Host Helper

新版本的 Heeler 可能带来更新的 Heeler 插件（用于 Herdr TUI Host），或更新的 Host Helper（用于 herdr-core 和 tmux Host）。可以在 Heeler 中更新；如果在 App 中更新一直失败，再手动更新。

## 在 Heeler 中更新

当某台 Host 上的版本较旧时，**Hosts** 标签会显示数量，Host 列表上方的卡片会说明有多少个更新在等待。

1. 轻点卡片上的 **Update All**。所有 Host 会同时更新。
2. 如果想逐个更新，轻点卡片打开 **Updates**，再轻点某一行的 **Update**。

**成功的标志是**卡片显示 **All Up to Date**，随后消失。

**Update All** 只更新已经安装的内容。首次安装插件或 Helper 要在对应 Server 的页面进行：在 **Hosts** 中打开该 Host，再轻点 Server。

## 更新失败时

该行会说明原因。除非该行显示 **Damaged**，旧版本仍可继续使用。轻点该行可以查看 Host 返回的原话。处理好原因后，轻点 **Try Again**。**Copy Details** 会复制完整信息，方便提交问题反馈。

| 行显示 | 处理方法 |
| --- | --- |
| Heeler could not connect to the Host | 在 **Hosts** 中确认该 Host 已连接，然后轻点 **Try Again**。 |
| Check that the Host can reach github.com | Host 需要从 GitHub 下载插件。修复它的网络，或[手动更新插件](#手动更新-heeler-插件)。 |
| 缺少 Node.js 或 npm，或版本过旧 | 在 Host 上安装 Node.js 20 或更新版本（含 npm），然后轻点 **Try Again**。 |
| The connection ended or the Host took too long | 更新可能仍会在 Host 上完成。等一分钟，然后在 **Updates** 中下拉刷新。 |
| **Damaged**，并带有 **Repair** 按钮 | 轻点 **Repair**。 |

如果仍然失败，请手动更新。

## 手动更新 Heeler 插件

**运行位置：Mac 或 Linux**

在 Host 上运行安装插件时用的那条命令，它同样会完成更新：

```sh
herdr plugin install ZingerLittleBee/Heeler --ref plugin --yes
```

herdr 会从 GitHub 下载插件，并用 Node.js 20 或更新版本和 npm 构建，所以 Host 上两者都要有。如果 Host 使用了具名的 herdr 会话，轻点它 **Herdr TUI** Server 页面上的 **Heeler Plugin** 行，可以看到已填好该会话的命令。

**成功的标志是**在 **Updates** 中下拉刷新，或重新打开该 Server 的页面后，**Heeler Plugin** 行显示新版本。

## 手动更新 Host Helper

Host Helper 包含在 Heeler App 里，所以没有可以在 Host 上运行的命令。请在 Server 的页面上逐台 Host 更新：

1. 在 **Hosts** 中打开该 Host，轻点它的 **herdr-core** 或 **tmux** Server，再轻点 **Host Helper**。
2. 轻点 **Update**；如果该行显示 **Damaged**，则轻点 **Repair**。失败时面板会说明出了什么问题。
3. 如果仍然失败，轻点 **Remove**，再轻点 **Install**。

**Remove** 还会删除该 Host 的通知注册。重新安装后，请在 **Settings > Notifications** 中重新打开该 Host。

Helper 需要 Host 上装有 Node.js 20 或更新版本。**Host Helper** 行各个状态的含义见 [Host Helper](herdr-core.md#host-helper)。

**成功的标志是** **Host Helper** 行显示新版本，且面板显示 **The Host Helper is running.**
