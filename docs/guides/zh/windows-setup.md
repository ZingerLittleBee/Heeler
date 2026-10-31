<!-- Translated from docs/guides/windows-setup.md at ed1e9e66 -->
# Windows 配置

为 Heeler 配置原生 Windows Host，包括 SSH 登录以及 SSH 与 herdr 的开机自启。

## 开始之前

- 具备管理员权限的 Windows 11。
- 原生 herdr 0.9.3 或更高版本，以及 Heeler 0.1.13 或更高版本。
- 请使用同一个 Windows 账户进行 SSH 登录、运行 herdr、运行编程 Agent（coding agent）以及配置开机自启任务。
- 下文示例使用命名会话 `heeler-win-test`；如果选用其他名称，请保持前后一致。

## 1. 启用 SSH

**以管理员身份**打开 PowerShell，检查是否已安装 OpenSSH Server：

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

如果状态为 `NotPresent`，请安装它：

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

立即启动 SSH 并设置为重启后自动启动：

```powershell
Set-Service sshd -StartupType Automatic
Start-Service sshd
Get-Service sshd
```

服务状态应显示为 `Running`。参见 [Microsoft OpenSSH 安装指南](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)。

### 允许 SSH 通过防火墙

在同一个管理员窗口中，查看当前网络配置文件以及 OpenSSH 安装的防火墙规则：

```powershell
Get-NetConnectionProfile
Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue |
    Select-Object Name, Enabled, Profile
```

仅限 `Private`（专用网络）的规则不允许在标记为 `Public`（公用网络）的网络上进行 SSH 连接。如果局域网内的 SSH 被拦截，请添加一条允许本地子网访问 TCP 22 端口的入站规则：

```powershell
if (-not (Get-NetFirewallRule -Name Heeler-SSH-LocalSubnet -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name Heeler-SSH-LocalSubnet `
        -DisplayName 'Heeler SSH (local subnet)' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 `
        -RemoteAddress LocalSubnet -Profile Private,Public
}
```

此规则涵盖了专用和公用网络下的本地子网连接。如果你希望将所有 SSH 访问都限制在该范围内，请检查其他允许 SSH 的防火墙规则。如果使用本地子网以外的 VPN 或跳板机（Jump Host），请改为放行其受信任的源地址。参见 [Microsoft 防火墙规则参考文档](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule)。

## 2. 安装并启动原生 herdr

以用于 SSH 登录的 Windows 账户打开一个普通 PowerShell 窗口，使用官方 Windows 安装脚本安装 herdr：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://herdr.dev/install.ps1 | iex"
```

打开一个新的 PowerShell 窗口以加载更新后的 PATH，然后检查：

```powershell
herdr --version
herdr remote-api-bridge --check
```

预期会输出 herdr 0.9.3 或更高版本，以及桥接标记 `herdr-api-bridge-v1`。参见 [herdr 原生 Windows 指南](https://herdr.dev/docs/windows-beta/)。

在普通的原生 Windows 终端中先启动一次命名会话，不要使用以管理员身份打开的终端：

```powershell
herdr --session heeler-win-test
```

这会初始化一个工作区（Workspace）和 shell 窗格。请在该会话内进入项目目录并启动配置好的编程 Agent。你可以随时分离（detach）herdr 客户端并在稍后重新连接，会话会继续在后台运行。

在另一个 PowerShell 窗口中确认该会话正在运行：

```powershell
herdr session list --json
```

## 3. 从 Heeler 连接

在 Windows 上查看账户名称和网络地址：

```powershell
whoami
ipconfig
```

对于本地账户，请使用 `whoami` 输出中计算机名称后面的用户名，并使用当前活动网络适配器的 IPv4 地址。

在 Heeler 中前往 **Hosts > Add Host**，先在 **Routes** 下轻点 **Add Route** 填写地址和端口并保存，再填写其余 Host 字段：

| 字段 | 值 |
| --- | --- |
| User | 运行 herdr 的 Windows 账户名 |
| Address（在 Route 中） | 手机可访问到的 Windows 地址 |
| Port（在 Route 中） | `22`（除非配置了其他 SSH 端口） |
| Authentication | `Password` |
| Password | Windows 账户密码（而非 Windows Hello PIN 码） |
| herdr Session | `heeler-win-test` |

在信任首次连接之前，请将 Heeler 显示的 SSH 主机密钥指纹与 Windows 上对应的主机公钥进行比对。对于 Ed25519 密钥：

```powershell
ssh-keygen -lf "$env:ProgramData\ssh\ssh_host_ed25519_key.pub"
```

连接检查应当全部通过，随后控制台（Console）会显示所选会话中的终端（Terminals）和 Agent（Agents）。你也可以从另一台设备测试 SSH：

```sh
ssh <username>@<windows-address> "herdr --version"
ssh <username>@<windows-address> "herdr session list --json"
```

设备密钥（Device Key）和 RSA 密钥（RSA Key）认证需要手动注册公钥。参见 [Windows 测试清单中的密钥配置步骤](../native-windows-testing.md#4-test-device-key-authentication)以及 [Microsoft 密钥管理指南](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement)。

## 4. 开机自动启动 herdr

使用任务计划程序（Task Scheduler）在与 SSH 相同的 Windows 账户下运行无头（headless）服务端。运行命令为：

```powershell
herdr --session heeler-win-test server
```

`server` 命令专为进程监管或服务式运行场景设计。参见 [herdr CLI 参考文档](https://herdr.dev/docs/cli-reference/#server)。

在普通 PowerShell 窗口中查找完整可执行文件路径和账户主目录：

```powershell
$HeelerHerdrExe = Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'
if (-not (Test-Path -LiteralPath $HeelerHerdrExe)) {
    $HeelerHerdrExe = (Get-Command herdr.exe).Source
}
$HeelerHerdrExe
$env:USERPROFILE
```

如果固定路径存在，请优先使用该路径；否则使用 `Get-Command` 返回的路径，并在升级 herdr 后更新计划任务。请将上方输出的实际路径复制到任务计划程序中，而不要粘贴 PowerShell 表达式本身。

**以管理员身份打开任务计划程序（Task Scheduler）**，选择 **创建任务（Create Task）**，并按以下内容配置：

| 标签页 | 设置 |
| --- | --- |
| 常规（General） | 名称：`Herdr Server`。运行账户设为 Heeler 使用的 Windows 账户。 |
| 常规（General） | 选择 **不管用户是否登录都要运行（Run whether user is logged on or not）**，取消勾选 **不存储密码（Do not store password）**。保持 **使用最高权限运行（Run with highest privileges）** 未勾选。 |
| 触发器（Triggers） | **启动时（At startup）**，可选延迟 30 秒。 |
| 操作（Actions） | **启动程序（Start a program）**。程序或脚本：上方输出的完整 `herdr.exe` 路径。 |
| 操作（Actions） | 添加参数：`--session heeler-win-test server`。起始于：上方输出的账户主目录。 |
| 条件（Conditions） | 如果需要在电池供电时同样运行服务端，请取消勾选仅在交流电源下启动和切换为电池电源时停止的选项。 |
| 设置（Settings） | 取消勾选 **如果任务运行时间超过以下时间，停止任务（Stop the task if it runs longer than）**。当任务已在运行时选择 **请勿启动新实例（Do not start a new instance）**。 |

保存时在弹出的 Windows 对话框中输入该 Windows 账户的密码。这允许计划任务在桌面登录之前就以该账户的配置文件和网络权限运行。如果将来修改了账户密码，请重新保存计划任务并输入新密码。切勿使用 SYSTEM 账户运行，否则会使用不同的账户和配置目录。Microsoft 文档详细说明了[任务登录类型](https://learn.microsoft.com/en-us/windows/win32/taskschd/principal-logontype)和[默认的 72 小时执行时间限制](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-executiontimelimit)。

从 herdr 0.9.4 起，以提升权限运行的服务端（使用最高权限运行，或从以管理员身份打开的终端启动）只接受管理员终端的连接。如需允许普通终端连接，请在启动服务端时加上 `--allow-unelevated-clients`，或在 herdr 配置中设置 `[server] allow_unelevated_clients = true`。

### 验证已保存的计划任务

首先检查 `herdr session list --json`。如果 `heeler-win-test` 已在运行，请等到其中的 Agent 可以安全停止时，先停止该会话再测试计划任务。herdr 会拒绝为同一个会话启动第二个服务端。

在任务计划程序中，右键单击 **Herdr Server** 并选择 **运行（Run）**。确认其状态变为 **正在运行（Running）**，然后在 SSH 账户下的 PowerShell 中运行以下检查：

```powershell
Get-Service sshd | Select-Object Name, Status, StartType
herdr --session heeler-win-test status server --json
```

预期 `sshd` 显示为 `Running` 和 `Automatic`，且 herdr 的响应包含 `running: true` 和 `session: "heeler-win-test"`。

在提供会话服务期间，该任务会一直保持 **正在运行（Running）** 状态。**上次运行结果（Last Run Result）** 显示为 `0x41301`（`267009`）表示任务仍在运行中，这对于长期运行的服务端属于正常现象。参见 [Microsoft 计划任务状态码文档](https://learn.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-error-and-success-constants)。

从 Heeler 重新连接，确认该命名会话能够正常加载。

### 重启后验证

当 Agent 可以停止时，重启 Windows。在登录 Windows 桌面之前，先从 Heeler 发起连接并检查命名会话能否正常加载。登录桌面后，重复上方的服务与 API 检查，确认计划任务处于 **正在运行（Running）** 状态。手动运行成功并不能代替重启后的自启验证。

## 支持的功能与进一步检查

原生 Windows 支持手动 SSH 连接、会话选择、实时 Agent（Agents）与终端（Terminals）以及目录浏览。配对（Pairing）、Chat、Usage、变更（Changes）、技能（Skills）、文件上传和通知注册目前暂不可用。请在连接前保持 herdr 处于运行状态；Heeler 不会自动启动 Windows 服务端。

如需进行终端尺寸调整、滚动、重连、会话隔离和认证方面的验收检查，请使用 [Windows 测试清单](../native-windows-testing.md)。
