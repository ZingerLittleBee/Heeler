<!-- Translated from docs/guides/usage.md at ed1e9e66 -->
# 查看 Usage 与 Usage Limits

Usage 显示你的 Claude Code 和 Codex 账号离 Usage Limits 还有多远，以及每台 Host 上的 Agent 最近 30 天用了多少 token、按 API 标价折算大约值多少钱。小组件把同样的数字放到主屏和锁屏上。

你需要一台装有 Heeler 插件 0.7.0 或更新版本的 macOS 或 Linux Host。

## 配置 Host

**运行位置：Mac 或 Linux**

安装或更新插件：

```sh
herdr plugin install ZingerLittleBee/Heeler --ref plugin --yes
```

如果 Usage 提示先使用一次 Agent，就在那台电脑上启动任意一个 Agent，或者重启 herdr，然后下拉刷新。

## 查看 Usage

轻点标签栏中的 **Usage**（在 iPad 上也可以从侧边栏顶部菜单选择 **Usage**）。

- 右上角（在 iPad 上位于侧边栏中）的 **All Hosts** 汇总所有 Host。选择某台 Host 则只看它的数字。
- 可以在 **Est. Cost** 与 **Tokens** 之间切换，也可以在 **Today**、**7 Days** 与 **30 Days** 之间切换。
- **Usage Limits** 显示每个程序用得最多的窗口及其重置时间。轻点 **Details** 查看所有窗口。Usage Limits 始终属于某台 Host 上登录的账号，所以从不相加。
- 按住图表，或轻点日历中的某一天，查看当天的数字。
- 下拉即可刷新。

<a href="../images/usage/usage-iphone.png"><img src="../images/usage/usage-iphone.png" width="300" alt="显示 30 天估算 API 费用、Usage Limits 和每日图表的 Usage 标签页"></a>

估算费用不是账单，它只是给这台 Host 的 Transcript 里还留着的 token 定价。

### 打开 Claude Code limits

Claude Code limits 默认关闭，需要逐台 Host 打开。轻点 **Usage Limits** 旁的 **Details**，然后打开 **Claude Code limits**。插件会向那台电脑上的 Claude Code 询问你的套餐额度；Heeler 从不经手你的登录信息。

## 添加 Claude Code Account

如果一台 Host 上同时用着不止一个 Claude Code 订阅，各自从自己的配置目录登录（例如用 `CLAUDE_CONFIG_DIR=~/.claude-2` 启动的 Agent），就把每个目录添加为一个 Account，Usage 会把它们分开统计。Account 需要那台 Host 装有 Heeler 插件 0.8.0 或更新版本；上面的安装命令也能用来更新。

每台 Host 一开始都有 **Default** Account，也就是 herdr 启动 Claude Code 时它使用的目录。你添加的每个 Account 都有自己的 Token Usage，列在 Claude Code 下面。打开 **Claude Code limits** 后，它还有自己的 Usage Limits，并在 Usage Limits 小组件里单独占一行。

1. 在 Usage 中选择一台 Host。如果 Heeler 找到了像是 Claude Code 的目录，会出现 **Found 1 Claude Code directory** 这样的提示，轻点它。否则轻点 **Usage Limits** 旁的 **Details**，再轻点 **Claude Code Accounts**。
2. 在 **Suggestions** 下，轻点 **Add** 开始统计某个目录，或轻点 **Ignore** 不再建议它。Heeler 建议的是正在运行的 Agent 使用的目录，或你主目录里的目录；在你添加之前，它们都不计入。
3. 要添加 Heeler 没有建议的目录，轻点 **Choose Another Directory…**，在 Host 上选中它。这个目录里必须有 Claude Code 的登录信息或 Transcript，也就是一个 `.claude.json` 文件或一个 `projects` 文件夹。

新 Account 从下一次刷新开始计入。一台 Host 最多可以有四个 Claude Code Account（包括 Default）；满四个后，要先移除一个才能再添加。

轻点某个 Account 可以重命名。名称会显示在 Usage、Usage Limits 和小组件中，所以同一台 Host 上的 Account 不能重名。清空 Default Account 的名称，它就会重新叫 Default。

要移除你添加的 Account，在它上面向左轻扫或按住它，然后轻点 **Remove** 和 **Remove Account**。它的 Token Usage 和 Usage Limits 不再显示；目录和其中的登录信息仍留在 Host 上。Default Account 可以重命名，但不能移除。

如果 herdr 本身用 `CLAUDE_CONFIG_DIR` 启动 Claude Code，`~/.claude` 就不再计入 Default Account。Heeler 会把它列为建议；如果你还在用它，就把它添加进来。

Account 保存在 Host 上，所以无论从哪台设备连接，看到的都是同一份列表。

## 添加小组件

1. 在主屏空白处按住，然后轻点 **编辑** > **添加小组件**。
2. 搜索 **Heeler**，选择小组件和尺寸：
   - **Usage**：今天、7 天或 30 天的估算费用或 token 数，可选 All Hosts 或某台 Host。
   - **Usage Limits**：某台 Host 的各个窗口及其重置时间。
3. 轻点 **添加小组件**，然后按住小组件并轻点 **编辑小组件**，选择 Host、显示内容或程序。**Automatic** 会显示最接近上限的程序。

两种小组件都有锁屏尺寸。按住锁屏，轻点 **自定** > **锁定屏幕**，再轻点小组件区域添加。

| 主屏 | 锁屏 |
| --- | --- |
| <a href="../images/usage/widgets-iphone.png"><img src="../images/usage/widgets-iphone.png" width="260" alt="主屏上小号和中号的 Usage 与 Usage Limits 小组件"></a> | <a href="../images/usage/widgets-lock-iphone.png"><img src="../images/usage/widgets-lock-iphone.png" width="260" alt="锁屏上的 Usage 与 Usage Limits 小组件"></a> |

轻点小组件，会在 Usage 中打开同样的数字。

## 小组件何时更新

- 打开 Heeler 时，如果某台 Host 的小组件数字已经超过 15 分钟，Heeler 会重新读取，不需要打开 Usage。
- Heeler 关闭时，iOS 会不定期让它在后台读取，最频繁每 30 分钟一次。在 **设置 > 通用 > 后台 App 刷新** 中打开。低电量模式，或在 App 切换器中划掉 Heeler，都会让后台读取停止，直到你再次打开 Heeler。后台读取只走 **Direct** 或 **Jump Host** 路由；只通过 Overlay Network 连接的 Host 会在你打开 Heeler 时更新。
