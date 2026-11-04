<!-- Translated from docs/guides/vps-jump-host-setup.md at ed1e9e66 -->

# 通过 VPS 配置远程访问

当运行 herdr 的 Mac 位于 NAT 之后、Heeler 无法直接连接时，请按本指南配置反向隧道访问。

配置完成后的连接路径如下：

```text
iPhone -> VPS public SSH port -> VPS 127.0.0.1:2222 -> Mac SSH port 22
```

VPS 仅对外暴露常规的 SSH 服务端口；`2222` 端口始终绑定在 VPS 的本地回环接口（Loopback）上，绝不会在公网防火墙中开放。

关于设计原理、威胁边界、密钥轮换以及完整的迁移操作手册，请参阅 [VPS Jump Host 与反向隧道部署参考](vps-jump-host.md)。

## 开始之前

你需要：

- 一台安装了 Heeler 的 iPhone；
- 一台安装了 herdr 的 Mac；
- 一台处于维护周期内的 Debian 或 Ubuntu VPS，并具备管理员权限；
- VPS 的公网 IP 地址；
- VPS 的 SSH 服务端口（通常为 `22`）；
- 一条独立的 VPS 应急恢复通道（例如云厂商网页控制台）。

在受限账户全部通过验证之前，请不要关闭当前的 VPS 管理员会话。

请先确定以下占位符对应的实际值：

| 占位符 | 示例 | 含义 |
|---|---|---|
| `VPS_PUBLIC_IP` | `203.0.113.10` | VPS 公网地址 |
| `VPS_SSH_PORT` | `22` | VPS 公网 SSH 端口 |
| `VPS_NAME` | `work-vps` | 本地简短别名 |
| `MAC_USER` | `alice` | macOS 登录账户名 |
| `TUNNEL_PORT` | `2222` | VPS 上映射给这台 Mac 的本地回环端口 |

执行命令前请先替换所有全大写占位符，切勿直接粘贴仍含未替换占位符的命令。

如果多台 Mac 共用同一台 VPS，请为每台 Mac 分配不同的 `TUNNEL_PORT`。

## 步骤 1：在 Mac 上开启远程登录

**运行位置：macOS**

打开：

```text
System Settings -> General -> Sharing -> Remote Login
```

开启 Remote Login（远程登录），并仅允许 Heeler 将要使用的 Mac 账户访问。本网络方案不需要授予完全磁盘访问权限（Full Disk Access）。

确认本机 SSH 监听正常：

```bash
nc -z 127.0.0.1 22 && echo 'Mac SSH is reachable'
```

预期：

```text
Mac SSH is reachable
```

请确认此命令成功后再继续下一步。

## 步骤 2：创建专用隧道密钥

**运行位置：macOS**

该密钥专用于保持反向隧道常驻，切勿复用于管理员登录或交互式登录。

```bash
ssh-keygen \
  -t ed25519 \
  -a 100 \
  -N '' \
  -f ~/.ssh/VPS_NAME-tunnel \
  -C VPS_NAME-tunnel
```

例如，当 `VPS_NAME` 为 `work-vps` 时：

```bash
ssh-keygen \
  -t ed25519 \
  -a 100 \
  -N '' \
  -f ~/.ssh/work-vps-tunnel \
  -C work-vps-tunnel
```

查看公钥内容与指纹：

```bash
cat ~/.ssh/VPS_NAME-tunnel.pub
ssh-keygen -lf ~/.ssh/VPS_NAME-tunnel.pub
```

复制 `.pub` 公钥行。切勿复制或上传不带 `.pub` 后缀的私钥文件。

检查点：

- [ ] 私钥权限为 `600`。
- [ ] 公钥以 `ssh-ed25519` 开头。
- [ ] 已记录公钥的 SHA-256 指纹。

## 步骤 3：复制 Heeler 的 Device Key

**运行位置：iOS**

在 Heeler 中前往 **Hosts > Add Host**，在 **Authentication** 下保持选中 **Device Key**（设备密钥），轻点 **Copy authorized_keys Line** 复制公钥行。格式形如：

```text
ssh-ed25519 AAAA... heeler
```

私钥保存在 iOS 钥匙串（Keychain）中，复制出来的只是公钥行。

将该行记为 `DEVICE_PUBLIC_KEY`。稍后需要同时在 VPS 的 Jump 账户和 Mac 登录账户上授权该公钥。

## 步骤 4：在 Mac 上授权 Device Key

**运行位置：macOS**

将 `DEVICE_PUBLIC_KEY` 替换为从 Heeler 复制的完整公钥行：

```bash
DEVICE_KEY='DEVICE_PUBLIC_KEY'
DEVICE_ENTRY="no-agent-forwarding,no-X11-forwarding,no-user-rc $DEVICE_KEY"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
grep -qxF "$DEVICE_ENTRY" ~/.ssh/authorized_keys 2>/dev/null \
  || printf '%s\n' "$DEVICE_ENTRY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

这些选项保留了 Heeler 所需的 PTY、命令执行与 SFTP 能力，同时禁用了 Agent 转发与 X11 转发。

注意不要在此处添加 `no-port-forwarding`。OpenSSH 会将该限制同时作用于 TCP 转发和 Unix 域套接字转发（stream-local），而 Heeler 需要通过 `direct-streamlocal` 通道连接 herdr API 套接字（ADR 0011）。如果加上该选项，即使 SSH 认证成功，预检也会在连接 herdr 套接字时失败。况且该密钥本就可在 Mac 上执行命令，禁用端口转发并不能带来额外防护。

检查点：

```bash
grep -F "$DEVICE_KEY" ~/.ssh/authorized_keys
```

该命令应当恰好输出一行匹配的授权公钥。

## 步骤 5：在 VPS 上创建受限账户

**运行位置：VPS**

```bash
id -u herdr-tunnel >/dev/null 2>&1 \
  || sudo adduser --disabled-password --gecos '' herdr-tunnel

id -u herdr-jump >/dev/null 2>&1 \
  || sudo adduser --disabled-password --gecos '' herdr-jump

sudo install -d -m 700 \
  -o herdr-tunnel \
  -g herdr-tunnel \
  /home/herdr-tunnel/.ssh

sudo install -d -m 700 \
  -o herdr-jump \
  -g herdr-jump \
  /home/herdr-jump/.ssh
```

如果账户已存在，请先检查其状态，不要盲目重建：

```bash
getent passwd herdr-tunnel
getent passwd herdr-jump
```

这两个账户均不设密码。后续添加的 SSH 策略会禁止它们打开 Shell 或子系统会话，仅放行所需的单一端口转发模式。

## 步骤 6：在 VPS 上安装受限公钥

**运行位置：VPS**

首先安装 Mac 的隧道公钥。将 `TUNNEL_PUBLIC_KEY` 替换为 `~/.ssh/VPS_NAME-tunnel.pub` 的完整内容：

```bash
TUNNEL_PORT='2222'
TUNNEL_KEY='TUNNEL_PUBLIC_KEY'
TUNNEL_ENTRY="restrict,port-forwarding,permitlisten=\"127.0.0.1:${TUNNEL_PORT}\" $TUNNEL_KEY"

printf '%s\n' "$TUNNEL_ENTRY" \
  | sudo tee /home/herdr-tunnel/.ssh/authorized_keys >/dev/null
```

如果这台 Mac 使用其他回环端口，请在运行前替换 `2222`。

接着追加 Heeler 的 Device Key。请替换 `DEVICE_PUBLIC_KEY`，并根据需要修改 `2222`：

```bash
TUNNEL_PORT='2222'
DEVICE_KEY='DEVICE_PUBLIC_KEY'
DEVICE_ENTRY="restrict,port-forwarding,permitopen=\"127.0.0.1:${TUNNEL_PORT}\" $DEVICE_KEY"

sudo grep -qxF "$DEVICE_ENTRY" /home/herdr-jump/.ssh/authorized_keys 2>/dev/null \
  || printf '%s\n' "$DEVICE_ENTRY" \
  | sudo tee -a /home/herdr-jump/.ssh/authorized_keys >/dev/null
```

设置目录与文件的属主及权限：

```bash
sudo chown -R herdr-tunnel:herdr-tunnel /home/herdr-tunnel/.ssh
sudo chmod 700 /home/herdr-tunnel/.ssh
sudo chmod 600 /home/herdr-tunnel/.ssh/authorized_keys

sudo chown -R herdr-jump:herdr-jump /home/herdr-jump/.ssh
sudo chmod 700 /home/herdr-jump/.ssh
sudo chmod 600 /home/herdr-jump/.ssh/authorized_keys
```

检查两个文件的内容：

```bash
sudo cat /home/herdr-tunnel/.ssh/authorized_keys
sudo cat /home/herdr-jump/.ssh/authorized_keys
```

检查点：

- [ ] 隧道公钥行包含 `permitlisten="127.0.0.1:TUNNEL_PORT"`。
- [ ] Device Key 公钥行包含 `permitopen="127.0.0.1:TUNNEL_PORT"`。
- [ ] 两个文件中均不包含任何私钥。

## 步骤 7：在 OpenSSH 中限制两个 VPS 账户

**运行位置：VPS**

确认主 SSH 配置文件启用了 `sshd_config.d` 目录包含：

```bash
grep -nE '^[[:space:]]*Include[[:space:]]+.*/sshd_config\.d/' \
  /etc/ssh/sshd_config
```

如果没有匹配行，请先停下来查阅当前 VPS 发行版的文档，确认配置加载方式后再继续。

创建 `/etc/ssh/sshd_config.d/60-herdr-forwarding.conf`：

```bash
sudoedit /etc/ssh/sshd_config.d/60-herdr-forwarding.conf
```

写入以下内容，并将两处 `TUNNEL_PORT` 替换为实际端口号：

```sshconfig
# Restrict the persistent reverse-tunnel account.
Match User herdr-tunnel
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding remote
    AllowStreamLocalForwarding no
    PermitListen 127.0.0.1:TUNNEL_PORT
    PermitOpen none
    GatewayPorts no
    PermitTTY no
    PermitTunnel no
    PermitUserRC no
    X11Forwarding no
    AllowAgentForwarding no
    MaxSessions 0

# Restrict the external Jump Host account.
Match User herdr-jump
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding local
    AllowStreamLocalForwarding no
    PermitListen none
    PermitOpen 127.0.0.1:TUNNEL_PORT
    GatewayPorts no
    PermitTTY no
    PermitTunnel no
    PermitUserRC no
    X11Forwarding no
    AllowAgentForwarding no
    MaxSessions 0

Match all
```

在重载服务前校验配置语法：

```bash
sudo /usr/sbin/sshd -t
```

没有任何输出说明语法正确。如果报错，切勿重载服务。

检查最终生效的限制项：

```bash
sudo /usr/sbin/sshd -T \
  -C user=herdr-tunnel,host=localhost,addr=127.0.0.1 \
  | grep -E 'allowtcpforwarding|permitlisten|permitopen|gatewayports|maxsessions'

sudo /usr/sbin/sshd -T \
  -C user=herdr-jump,host=localhost,addr=127.0.0.1 \
  | grep -E 'allowtcpforwarding|permitlisten|permitopen|gatewayports|maxsessions'
```

在 Debian 或 Ubuntu 上重载服务：

```bash
sudo systemctl reload ssh
```

部分发行版的服务名为 `sshd`。

在关闭当前管理员连接之前，请先新开第二个管理员连接确认仍能正常登录。

## 步骤 8：配置 VPS 防火墙

**运行位置：VPS 云控制台与 VPS**

仅对 VPS 的 SSH 服务端口放行入站 TCP 流量：

```text
VPS_SSH_PORT
```

切勿为 `TUNNEL_PORT` 创建公网放行规则。

先查看主机防火墙状态，不要盲目启用或覆盖现有规则：

```bash
sudo ufw status verbose
sudo nft list ruleset
```

具体防火墙工具取决于发行版与云厂商。所需结果为：

```text
Public: VPS_SSH_PORT
Private loopback only: TUNNEL_PORT
```

如果 VPS 上已承载其他服务，请保留其原有的放行规则。除所选的 SSH 端口外，本方案不需要开放任何额外公网端口。

## 步骤 9：核验 VPS 主机密钥

**先运行于：VPS**

```bash
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

通过云厂商控制台或受信任的管理员会话记下 SHA-256 指纹。

**接着运行于：macOS**

```bash
ssh-keyscan -T 10 -t ed25519 -p VPS_SSH_PORT VPS_PUBLIC_IP 2>/dev/null \
  | ssh-keygen -lf -
```

两边的指纹必须完全一致。单独运行 `ssh-keyscan` 只能发现公钥，不能代替身份核验。如果指纹不一致，请立即停止。

## 步骤 10：在 Mac 上添加 SSH 隧道别名

**运行位置：macOS**

将以下配置块添加到 `~/.ssh/config`，并替换所有占位符：

```sshconfig
Host VPS_NAME-tunnel
  HostName VPS_PUBLIC_IP
  User herdr-tunnel
  Port VPS_SSH_PORT
  IdentityFile ~/.ssh/VPS_NAME-tunnel
  IdentitiesOnly yes
  BatchMode yes
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  StrictHostKeyChecking yes
```

检查解析后的配置值：

```bash
ssh -G VPS_NAME-tunnel \
  | grep -E '^(hostname|user|port|identityfile|stricthostkeychecking) '
```

确认每一项都指向新的 VPS 地址与专用隧道密钥。

## 步骤 11：手动测试反向隧道

**运行位置：macOS**

```bash
ssh -NT \
  -R 127.0.0.1:TUNNEL_PORT:127.0.0.1:22 \
  VPS_NAME-tunnel
```

保持该命令处于运行状态。

**在另一会话中运行于：VPS**

```bash
sudo ss -ltnp | grep ':TUNNEL_PORT'
```

本地地址列应显示：

```text
127.0.0.1:TUNNEL_PORT
```

不应显示：

```text
0.0.0.0:TUNNEL_PORT
[::]:TUNNEL_PORT
```

通过此检查点后，在 Mac 终端按 `Control-C` 停止手动测试隧道。

## 步骤 12：安装常驻 macOS LaunchAgent

**运行位置：macOS**

创建文件：

```text
~/Library/LaunchAgents/dev.herdr.VPS_NAME-reverse-ssh.plist
```

使用以下模板，并替换其中的 `MAC_USER`、`VPS_NAME` 和 `TUNNEL_PORT`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.herdr.VPS_NAME-reverse-ssh</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ssh</string>
        <string>-NT</string>
        <string>-R</string>
        <string>127.0.0.1:TUNNEL_PORT:127.0.0.1:22</string>
        <string>VPS_NAME-tunnel</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>/Users/MAC_USER/Library/Logs/VPS_NAME-reverse-ssh.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/MAC_USER/Library/Logs/VPS_NAME-reverse-ssh.error.log</string>
</dict>
</plist>
```

校验并加载该服务：

```bash
PLIST=~/Library/LaunchAgents/dev.herdr.VPS_NAME-reverse-ssh.plist
LABEL=dev.herdr.VPS_NAME-reverse-ssh

plutil -lint "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
launchctl print "gui/$(id -u)/$LABEL"
```

预期状态：

```text
state = running
```

检查错误日志：

```bash
tail -n 50 ~/Library/Logs/VPS_NAME-reverse-ssh.error.log
```

正常情况下错误日志应为空。

该用户级 LaunchAgent 会在该 Mac 用户登录后启动；如果 Mac 重启后停留在 FileVault 登录前界面，隧道尚未运行。

## 步骤 13：在 Heeler 中添加 Host

**运行位置：iOS**

前往 **Hosts > Add Host**，在 **Routes** 下轻点 **Add Route** 填写隧道与 Jump Host 字段并轻点 **Save** 保存路由，再填写其余 Host 字段：

| 字段 | 值 |
|---|---|
| Name | 任意易于识别的名称 |
| User | `MAC_USER` |
| Address（在 Route 中） | `127.0.0.1` |
| Port（在 Route 中） | `TUNNEL_PORT` |
| Jump Host address（在 Route 中） | `VPS_PUBLIC_IP` |
| Jump Host port（在 Route 中） | `VPS_SSH_PORT` |
| Jump Host user（在 Route 中） | `herdr-jump` |
| Authentication | `Device Key` |
| herdr Session | 留空 |

在路由页面中，只有填写了 Jump Host address 后，Jump Host port 与 Jump Host user 字段才会显示。如果将 Jump Host user 留空，Heeler 会默认复用 Host user，从而被 VPS 当作未知账户拒绝。

将 herdr Session 留空即可使用位于 `~/.config/herdr/herdr.sock` 的默认会话。填写任何值（包括 `default`）都会连接 `~/.config/herdr/sessions/<name>/herdr.sock`。

在 **Add Host** 页面轻点 **Save** 开始预检（**Preflight**）。

Heeler 会分两次独立询问主机密钥确认：

1. VPS Jump Host 的主机密钥；
2. 通过反向隧道连上的 Mac 主机密钥。

请分别对照各自信任的系统核对指纹，不要因为信任了 VPS 就直接跳过 Mac 指纹核对。

预检通过需同时验证以下四项：

- Jump Host 认证成功；
- Mac 认证成功；
- herdr 套接字可达；
- 协议版本兼容。

最后通过 Attach 打开一个 Agent，完成功能验收。

## 步骤 14：验证自动重连恢复

**运行位置：macOS**

查找受管的隧道进程：

```bash
ps -axo pid=,command= | grep '[s]sh .*VPS_NAME-tunnel'
```

仅终止该 PID：

```bash
kill TUNNEL_PROCESS_PID
```

等待几秒后检查 LaunchAgent 状态：

```bash
launchctl print "gui/$(id -u)/dev.herdr.VPS_NAME-reverse-ssh"
```

输出应显示新的 PID 以及 `state = running`。

在 Heeler 中轻点 **Preflight** 旁的 **Run Checks Again** 重新运行预检，或打开一个 Agent。仅进程重启而没有验证应用端连接恢复，不足以证明自动重连正常。

## 步骤 15：加固 Mac 认证配置

**运行位置：macOS（仅在确认 Device Key 可正常连接后执行）**

VPS 的 `root` 用户以及任何持有获批 Jump Host 密钥的客户端，都能通过回环隧道访问到 Mac 的 SSH 监听端口。如果 macOS 仍开启了密码或键盘交互认证，这些主体就可以尝试暴力猜测 Mac 密码。

在不输入密码的情况下检查当前开放的认证方式：

```bash
ssh \
  -o BatchMode=yes \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=none \
  MAC_USER@127.0.0.1 true
```

如果报错信息中列出了 `password` 或 `keyboard-interactive`，建议将 Mac 的 SSH 服务配置改为：

```sshconfig
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
```

请仅在人守在 Mac 旁、且已确认 Device Key 登录正常并备有独立恢复途径时执行此操作。重启“远程登录”前请先校验 SSH 配置语法。

## 最终验收清单

- [ ] Mac 已为目标账户开启“远程登录”。
- [ ] Mac 反向隧道使用专用密钥。
- [ ] iOS Device Key 已在 VPS 与 Mac 两端同时获得授权。
- [ ] VPS 使用相互独立的隧道账户与 Jump 账户。
- [ ] 两个 VPS 受限账户均拒绝 Shell、密码、PTY 及无关转发。
- [ ] 云厂商防火墙仅对外开放 VPS 的 SSH 服务端口。
- [ ] VPS 监听地址严格为 `127.0.0.1:TUNNEL_PORT`。
- [ ] 已分别独立核对 VPS 与 Mac 的主机密钥指纹。
- [ ] LaunchAgent 状态显示为 `state = running`。
- [ ] 杀掉隧道进程后会自动拉起新 PID。
- [ ] Heeler 预检通过。
- [ ] 可通过 Attach 正常打开 Agent。

## 故障排查

| 现象 | 可能出问题的边界 | 检查项 |
|---|---|---|
| Jump Host 拒绝 Device Key | iOS -> VPS | 检查 `/home/herdr-jump/.ssh/authorized_keys` 中的公钥行 |
| `remote port forwarding failed` | Mac -> VPS 隧道 | 检查是否已有占用该端口的监听进程、`PermitListen` 配置及隧道账户公钥 |
| VPS 上看不到 `TUNNEL_PORT` 监听 | Mac -> VPS 隧道 | 检查 LaunchAgent 运行状态与错误日志 |
| VPS 显示 `0.0.0.0:TUNNEL_PORT` | VPS 安全策略 | 立即停止隧道；恢复 `GatewayPorts no` 并显式绑定到回环地址 |
| Mac 提示输入密码 | VPS -> Mac | Mac 上未添加该 Device Key，或填错了 Mac 用户名 |
| Mac 主机密钥发生变化 | 内层 SSH 信任 | 先在 Mac 本机核对主机密钥指纹，再决定是否接受 |
| VPS 主机密钥发生变化 | 外层 SSH 信任 | 先通过云厂商控制台核对指纹，再决定是否接受 |
| 应用能连上 Mac 但连不上 herdr | Mac 应用层 | 检查 herdr 运行状态、套接字路径以及 `AllowStreamLocalForwarding` |

## 自动化配置更多桌面客户端

当 VPS 与反向隧道正常运作后，如需让其他 Mac 也能通过该隧道访问，无需重做完整的 15 个步骤。仓库内置的两个脚本可以自动完成客户端配置，同时保证每台电脑使用各自独立、可单独吊销的密钥。

这套自动化脚本采用双端审批流程：

1. 新客户端在本机生成私钥；
2. 管理员在被暴露的目标 Mac 上仅注册该客户端的公钥。

这样无需将 VPS 管理员私钥或共享客户端私钥复制到每台电脑上。

### 管理员一次性前置条件

**运行位置：被暴露的 Mac**

确保这台 Mac 能通过 SSH 连接到 VPS 管理员账户，且已完成 VPS 主机密钥核验。目标可以是已配置好的别名（如 `vps-admin`）或显式地址（如 `admin@VPS_PUBLIC_IP`）。

远端管理员账户必须是 `root`，或具备免密 `sudo` 权限。一旦发现 VPS 主机密钥未知或发生变更，注册脚本会拒绝执行。

### 配置新的 Mac 客户端

**运行位置：新客户端 Mac（在本仓库检出目录中）**

```bash
scripts/configure-vps-ssh-client.sh \
  --profile VPS_NAME \
  --vps-host VPS_PUBLIC_IP \
  --vps-port VPS_SSH_PORT \
  --target-user MAC_USER \
  --jump-user herdr-jump \
  --tunnel-port TUNNEL_PORT
```

该脚本会：

- 若 `~/.ssh/VPS_NAME-client` 不存在则自动创建；
- 提示设置密钥口令（Passphrase）；
- 在 SSH 配置中写入受管的 `VPS_NAME-jump` 与 `VPS_NAME-mac` 别名；
- 校验生成的 OpenSSH 配置语法；
- 打印公钥指纹；
- 仅将公钥复制到 macOS 剪贴板。

仅当客户端无法交互式输入口令时才使用 `--no-passphrase`。私钥始终保留在新客户端本机，无需导出。

请通过受信任的渠道将打印出的公钥发给管理员。公钥本身虽不是机密，但批准前仍应核对指纹。

### 一次性批准该客户端

**运行位置：被暴露的 Mac（在本仓库检出目录中）**

如果已通过通用剪贴板（Universal Clipboard）传过来公钥：

```bash
pbpaste | scripts/manage-vps-ssh-client.sh add \
  --vps-admin VPS_ADMIN_SSH_DESTINATION \
  --jump-user herdr-jump \
  --tunnel-port TUNNEL_PORT
```

否则请将公钥保存为 `.pub` 文件后运行：

```bash
scripts/manage-vps-ssh-client.sh add \
  --vps-admin VPS_ADMIN_SSH_DESTINATION \
  --jump-user herdr-jump \
  --tunnel-port TUNNEL_PORT \
  --public-key-file NEW_CLIENT_PUBLIC_KEY_FILE
```

这一条命令会：

1. 在 VPS 的 Jump 账户中，将该公钥已有的重复项或未受限项替换为仅允许转发的受限条目；
2. 在目标 Mac 上，将该公钥已有的重复项或未受限项替换为支持命令执行但禁用 Agent 与 X11 转发的条目；
3. 保留两端其余无关的授权公钥；
4. 强制设置正确的文件属主与权限。

脚本会先完成 VPS 端更新，再替换目标 Mac 上的文件；如果 VPS 步骤失败，目标 Mac 的授权保持不变。

### 连接并验证

**运行位置：新客户端 Mac**

```bash
ssh VPS_NAME-mac
```

首次连接时 OpenSSH 会先后询问两个主机密钥。请先通过云厂商控制台核对 VPS 指纹，并通过系统设置或本地命令核对目标 Mac 指纹，确认无误后再分别接受。

### 吊销单个客户端

**运行位置：被暴露的 Mac**

在删除客户端私钥前，请保留旧公钥或先将其导出为文件：

```bash
scripts/manage-vps-ssh-client.sh revoke \
  --vps-admin VPS_ADMIN_SSH_DESTINATION \
  --jump-user herdr-jump \
  --tunnel-port TUNNEL_PORT \
  --public-key-file OLD_CLIENT_PUBLIC_KEY_FILE
```

吊销操作会同时从 VPS 和目标 Mac 两个授权点移除该公钥，其他客户端不受影响。

## 添加另一台 VPS

请勿直接覆盖正在正常工作的配置，而应并行搭建新路径：

1. 为新 VPS 生成一把全新的隧道密钥。
2. 在新 VPS 上配置受限账户并确认其主机密钥。
3. 将现有的 Device Key 公钥行添加到新 VPS 的 Jump 账户。
4. 在 Mac 上创建新的 SSH 别名与第二个 LaunchAgent。
5. 验证新的回环监听端口与自动重连恢复。
6. 在 Heeler 中打开该 Host 的路由（或新增一条路由），仅修改 Jump Host 相关字段，并轻点 **Save** 保存 Host。
7. 测试 **Preflight** 预检与 Attach。
8. 确认新路径工作正常后，再停止并移除旧路径。

完整的分阶段切换与回滚流程，请参阅[添加或迁移到新 VPS](vps-jump-host.md#添加或迁移到新-vps)。
