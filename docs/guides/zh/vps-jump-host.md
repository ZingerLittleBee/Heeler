<!-- Translated from docs/guides/vps-jump-host.md at ed1e9e66 -->

# VPS Jump Host 与反向隧道部署参考

当运行 herdr 的 Mac 位于 NAT 之后且没有固定公网地址时，推荐使用本指南介绍的方案从 Heeler 建立连接：以一台公网 VPS 作为受限的 SSH Jump Host（跳板机），由 Mac 主动向 VPS 发起反向 SSH 隧道，并将转发端口仅绑定在 VPS 的本地回环接口（Loopback）上。

注意，这不是公网端口映射，绝不能将 Mac 的 SSH 端口直接暴露为 VPS 的公网监听端口。

如果需要按设备组织的复制粘贴分步指南，请先阅读[通过 VPS 配置远程访问](vps-jump-host-setup.md)；需要了解完整的信任模型、运维细节与迁移流程时再回到本文。

## 架构概览

整个方案包含三端系统与三类相互独立的 SSH 身份凭证：

```text
                                     persistent outbound SSH
                              +-----------------------------------+
                              |                                   |
                              v                                   |
+------------------+    +-----------------------------+    +------------------+
| iOS              |    | VPS                         |    | macOS            |
| Heeler     |    | public TCP 22               |    | Remote Login    |
|                  |    |                             |    | TCP 22           |
| Device Key       +--->| restricted Jump account    |    |                  |
| in Keychain      |    | direct-tcpip only           |    | launchd         |
|                  |    |          |                  |    | reverse SSH     |
| verifies both    |    |          v                  |    |                  |
| host keys        |    | 127.0.0.1:2222 only        +--->| 127.0.0.1:22    |
+------------------+    +-----------------------------+    +--------+---------+
                                                                   |
                                                                   v
                                                        herdr API and Attach
```

常驻路由由 Mac 主动建立：

```text
VPS 127.0.0.1:2222 -> reverse SSH channel -> Mac 127.0.0.1:22
```

当 iOS 发起连接时，会先后进行两次独立的 SSH 握手：

1. Heeler 使用自己的 Device Key 向 VPS Jump Host 完成认证。
2. Jump Host 仅打开到 `127.0.0.1:2222` 的转发通道。
3. Heeler 通过该转发字节流与 Mac 进行第二次 SSH 握手。
4. 通过 Mac 认证后，应用经由 `direct-streamlocal` 通道访问 herdr 的 Unix 套接字，并通过 SSH PTY 打开 Attach 终端。

虽然外层 SSH 连接与 Mac 到 VPS 的隧道都在 VPS 上终结，但隧道内承载的载荷是另一条端到端加密的 SSH 连接。只要应用正确校验了 Mac 的主机密钥，VPS 最多只能看到连接元数据或中断连接，无法被动窃听 iOS 与 Mac 之间的内层会话内容。

## 公网与私有端口

| 位置 | 监听地址 | 可达范围 | 用途 |
|---|---:|---|---|
| VPS | `0.0.0.0:22` 和/或 `[::]:22` | 公网（受防火墙策略控制） | VPS SSH 服务 |
| VPS | `127.0.0.1:2222` | 仅限 VPS 本地回环 | 反向转发的 Mac SSH |
| Mac | `127.0.0.1:22`（隧道目标） | 通过反向隧道访问 | macOS 远程登录 |

开启“远程登录”后，Mac 的 SSH 守护进程通常也会在局域网接口上监听。本文仅控制经由 VPS 的外网路径，不会改动局域网防火墙或路由器策略。

VPS 的云安全组与主机防火墙只需放行 SSH 服务端口，切勿为 `2222` 添加公网放行规则。

## 身份凭证与信任边界

不同角色必须使用各自独立的密钥：

| 身份凭证 | 存储位置 | 授权位置 | 权限范围 |
|---|---|---|---|
| VPS 管理员密钥 | 管理员设备 | VPS 管理员账户 | 仅用于 VPS 系统管理 |
| 隧道密钥 | Mac 文件系统 | VPS 受限隧道账户 | 仅用于创建一个反向监听端口 |
| Device Key | iOS 钥匙串 | VPS Jump 账户与 Mac 登录账户 | 访问指定的转发端点，并向 Mac 进行身份认证 |

请勿进行以下操作：

- 将 VPS 管理员私钥复制到 iOS 设备上；
- 直接拿 VPS 的 `root` 账户当作 Jump Host；
- 将隧道密钥复用于交互式登录；
- 将任何私钥写入 `authorized_keys`、文档、Shell 历史记录或 Issue；
- 为了省去首次连接确认而关闭主机密钥校验。

Heeler 会分别独立校验 Jump Host 和 Host 的主机密钥。在应用内点击信任之前，请先通过 VPS 云控制台或其他可信管理渠道核对新 VPS 的主机密钥指纹。

## VPS 上的安全策略

推荐在 VPS 上创建两个无特权专用账户：

- `herdr-tunnel`：接收来自 Mac 的自动连接，仅允许远程端口转发（Remote Forwarding）。
- `herdr-jump`：接收 Device Key 连接，仅允许到本地 `127.0.0.1:2222` 的本地端口转发（Local Forwarding）。

两个账户均禁用密码登录、键盘交互登录、Shell 会话、命令执行、SFTP、PTY 分配、Agent 转发、X11 转发、Unix 套接字转发、用户 SSH 启动脚本以及 TUN/TAP 隧道。

其中 `MaxSessions 0` 是关键配置：根据 OpenSSH 官方文档，它会阻止一切 Shell、登录与子系统会话，同时仍然允许端口转发。

所有限制均实施双重防护：

1. 在 `sshd_config` 中对账户接受的所有密钥统一施加限制；
2. 在 `authorized_keys` 中对每一条公钥单独施加限制。

这种纵深防御可以避免因某条公钥漏写限制选项而把受限账户变成普通登录账户。

## 前置条件

- 一台运行受维护版本 OpenSSH（支持 `PermitListen` 与 `PermitOpen`）的 VPS。
- 具备 VPS 的管理员 SSH 或控制台访问权限。
- 已为目标 Mac 账户开启 macOS“远程登录”。
- 在任何一端禁用密码认证前，已测试通过公钥登录路径。
- Mac 上已安装 herdr，且 SSH 服务允许 `stream-local` 转发（详见传输层架构文档）。

下文示例使用以下参数：

```text
VPS address: VPS_PUBLIC_IP
VPS SSH port: 22
VPS tunnel account: herdr-tunnel
VPS Jump account: herdr-jump
VPS loopback tunnel port: 2222
Mac account: MAC_USER
SSH aliases: work-vps-tunnel, work-vps-jump, work-mac
```

请在实际操作中保持参数一致。如果多台 Mac 共用同一台 VPS，请为每台 Mac 分配不同的本地回环端口。

## 1. 在 Mac 上创建专用隧道密钥

反向隧道需要在无人值守状态下自动运行，因此请使用空口令的专用密钥。由于该密钥在 VPS 上受到严格限制，无法用于获取 Shell。

```bash
ssh-keygen \
  -t ed25519 \
  -a 100 \
  -N '' \
  -f ~/.ssh/work-vps-tunnel \
  -C work-vps-tunnel
```

仅记录公钥部分：

```bash
cat ~/.ssh/work-vps-tunnel.pub
ssh-keygen -lf ~/.ssh/work-vps-tunnel.pub
```

## 2. 获取 Heeler 的 Device Key

复制 Heeler 中显示的公钥行；私钥始终留在 iOS 钥匙串中。

同一条 Device Key 公钥必须同时授权在以下两处：

- VPS 的 Jump 账户（附带仅允许转发的限制项）；以及
- Mac 登录账户（供第二次 SSH 握手认证使用）。

如果只在一跳上授权该公钥，另一跳就会弹出密码提示或直接认证失败。

在 Mac 上，请保留 Heeler 所需的 PTY、命令执行、SFTP 与 `stream-local` 转发能力，同时禁用应用不需要的功能：

```text
no-agent-forwarding,no-X11-forwarding,no-user-rc DEVICE_PUBLIC_KEY
```

请勿添加 `no-port-forwarding`，因为 OpenSSH 会将其同时作用于 Heeler 连接 herdr API 套接字所用的 `direct-streamlocal` 通道。

将该行追加到 `~/.ssh/authorized_keys`，并确保权限正确：

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

## 3. 在 VPS 上创建受限账户

以 VPS 管理员身份运行：

```bash
sudo adduser --disabled-password --gecos '' herdr-tunnel
sudo adduser --disabled-password --gecos '' herdr-jump

sudo install -d -m 700 \
  -o herdr-tunnel \
  -g herdr-tunnel \
  /home/herdr-tunnel/.ssh

sudo install -d -m 700 \
  -o herdr-jump \
  -g herdr-jump \
  /home/herdr-jump/.ssh
```

此时先不要修改管理员自身的登录策略，并保持当前管理员会话打开，直到新配置通过全部验证。

## 4. 在 VPS 上安装受限公钥

在隧道账户中安装隧道公钥：

```text
restrict,port-forwarding,permitlisten="127.0.0.1:2222" TUNNEL_PUBLIC_KEY
```

在 Jump 账户中安装每个获批的 Device Key：

```text
restrict,port-forwarding,permitopen="127.0.0.1:2222" DEVICE_PUBLIC_KEY
```

设置属主与权限：

```bash
sudo chown -R herdr-tunnel:herdr-tunnel /home/herdr-tunnel/.ssh
sudo chmod 700 /home/herdr-tunnel/.ssh
sudo chmod 600 /home/herdr-tunnel/.ssh/authorized_keys

sudo chown -R herdr-jump:herdr-jump /home/herdr-jump/.ssh
sudo chmod 700 /home/herdr-jump/.ssh
sudo chmod 600 /home/herdr-jump/.ssh/authorized_keys
```

`restrict` 默认会禁用包括端口转发在内的所有权限；紧跟其后的 `port-forwarding` 重新开启转发，再由 `permitlisten` 或 `permitopen` 将转发范围收敛到唯一允许的端点。

## 5. 应用账户级 OpenSSH 限制

在 Debian 与 Ubuntu 上，先确认主配置文件包含 `sshd_config.d` 目录：

```bash
grep -nE '^[[:space:]]*Include[[:space:]]+.*/sshd_config\.d/' \
  /etc/ssh/sshd_config
```

创建 `/etc/ssh/sshd_config.d/60-herdr-forwarding.conf`：

```sshconfig
# Restrict the persistent reverse-tunnel account.
Match User herdr-tunnel
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding remote
    AllowStreamLocalForwarding no
    PermitListen 127.0.0.1:2222
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
    PermitOpen 127.0.0.1:2222
    GatewayPorts no
    PermitTTY no
    PermitTunnel no
    PermitUserRC no
    X11Forwarding no
    AllowAgentForwarding no
    MaxSessions 0

Match all
```

末尾的 `Match all` 用于结束第二个条件块；当 drop-in 文件在主配置前半部分被引入时，这一行尤为重要，可防止后续全局指令被误归入 `Match` 块。

重载前先进行验证：

```bash
sudo /usr/sbin/sshd -t

sudo /usr/sbin/sshd -T \
  -C user=herdr-tunnel,host=localhost,addr=127.0.0.1 \
  | grep -E 'allowtcpforwarding|permitlisten|permitopen|gatewayports|maxsessions'

sudo /usr/sbin/sshd -T \
  -C user=herdr-jump,host=localhost,addr=127.0.0.1 \
  | grep -E 'allowtcpforwarding|permitlisten|permitopen|gatewayports|maxsessions'
```

确认 `sshd -t` 通过后再重载服务：

```bash
sudo systemctl reload ssh
```

部分发行版的服务名称为 `sshd`。

## 6. 配置 Mac 端 SSH 别名

在 `~/.ssh/config` 中添加类似如下的条目：

```sshconfig
Host work-vps-tunnel
  HostName VPS_PUBLIC_IP
  User herdr-tunnel
  Port 22
  IdentityFile ~/.ssh/work-vps-tunnel
  IdentitiesOnly yes
  BatchMode yes
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  StrictHostKeyChecking yes

Host work-vps-jump
  HostName VPS_PUBLIC_IP
  User herdr-jump
  Port 22
  IdentityFile ~/.ssh/work-client
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes

Host work-mac
  HostName 127.0.0.1
  User MAC_USER
  Port 2222
  IdentityFile ~/.ssh/work-client
  IdentitiesOnly yes
  ProxyJump work-vps-jump
  HostKeyAlias work-mac-via-vps
  StrictHostKeyChecking yes
```

桌面客户端密钥（`work-client`）仅用于命令行端到端验证；Heeler 自身使用独立的 Device Key。

在将 VPS 主机密钥写入 `known_hosts` 之前，请先通过受信任的 VPS 控制台核对指纹，切勿使用 `StrictHostKeyChecking no`。

## 7. 交互式测试隧道

在 Mac 上运行：

```bash
ssh -NT \
  -R 127.0.0.1:2222:127.0.0.1:22 \
  work-vps-tunnel
```

在 VPS 上运行：

```bash
sudo ss -ltnp | grep ':2222'
```

本地地址列应显示：

```text
127.0.0.1:2222
```

不应显示：

```text
0.0.0.0:2222
[::]:2222
```

注意对端地址列（Peer Address）常见的 `0.0.0.0:*` 并不代表公网监听，请以本地地址列（Local Address）为准。

在配有验证密钥的桌面客户端上运行：

```bash
ssh work-mac
```

这项测试不仅验证了进程存活，还端到端验证了：Jump 账户认证成功、直连 TCP 通道可到达本地回环监听端口、反向隧道可到达 Mac、Mac 主机密钥匹配，以及 Mac 接受内层 SSH 身份。

## 8. 让 Mac 隧道常驻运行

使用用户级 LaunchAgent 运行以下命令：

```text
/usr/bin/ssh -NT -R 127.0.0.1:2222:127.0.0.1:22 work-vps-tunnel
```

LaunchAgent 配置文件应定义：

- 唯一的 `Label`；
- `RunAtLoad`；
- `KeepAlive`；
- 重试节流间隔（`ThrottleInterval`）；
- 独立的标准输出与标准错误日志文件。

同时验证首次启动与故障恢复：

```bash
launchctl print gui/$(id -u)/YOUR_LAUNCH_AGENT_LABEL
```

手动杀掉一次受管的 SSH 进程，确认 `launchd` 会拉起新的 PID，并再次执行端到端的 `ssh work-mac` 测试。仅凭进程存在并不能证明远端回环监听或两跳认证正常。

macOS 用户级 LaunchAgent 仅在该用户登录后启动；如果 Mac 重启后尚未有用户登录，该隧道不会运行。

## 9. 配置 Heeler

在 **Hosts > Add Host** 中，轻点 **Routes** 下的 **Add Route** 填写隧道与 Jump Host 字段并轻点 **Save** 保存路由，再填写其余 Host 字段：

| 字段 | 值 |
|---|---|
| User | `MAC_USER` |
| Address（在 Route 中） | `127.0.0.1` |
| Port（在 Route 中） | `2222` |
| Jump Host address（在 Route 中） | `VPS_PUBLIC_IP` |
| Jump Host port（在 Route 中） | `22` |
| Jump Host user（在 Route 中） | `herdr-jump` |
| Authentication | `Device Key` |

在 **Add Host** 页面轻点 **Save** 开始 **Preflight** 预检，并分别独立确认两跳的主机密钥：

- VPS 的公网端点指纹；
- 通过 `127.0.0.1:2222` 呈现的 Mac 主机密钥指纹。

信任 Jump Host 并不代表自动信任 Mac；任何一跳的指纹发生变化都属于独立的安全事件。

## macOS 认证加固

虽然反向隧道设计避免了将 Mac 直接暴露到公网，但 VPS 的 `root` 用户可以访问回环隧道端点，任何持有获批 Jump Host 密钥的客户端也能访问该端点。如果 Mac 仍允许密码或键盘交互认证，这些主体就可以尝试暴力猜测 Mac 密码。

在验证好独立的第二管理通道后，建议将 Mac“远程登录”设为仅允许公钥认证：

```sshconfig
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
```

在关闭现有会话前，请先测试实际生效的服务端认证方式。在确认 Device Key 访问正常且备有独立恢复途径之前，切勿禁用密码登录。

Device Key 按设计授予了 Heeler 所需的 Mac 权限（包括命令执行、SFTP 与 PTY 访问）。因此一旦已授权的 iOS 设备丢失，必须同时从 VPS Jump 账户和 Mac 的 `authorized_keys` 中吊销其公钥。

## 故障表现与行为

| 故障场景 | 表现结果 |
|---|---|
| iOS 离线或应用关闭 | Mac 到 VPS 的常驻隧道继续保持连接 |
| Mac 休眠、关机或断网 | VPS 上的回环监听端口消失；macOS 恢复后由 `launchd` 自动重连 |
| VPS 重启 | iOS 与隧道连接同时断开；VPS SSH 服务恢复后由 `launchd` 自动重连 |
| 隧道密钥被拒 | 不会在 VPS 上创建反向监听端口 |
| Jump 账户拒绝 Device Key | iOS 无法打开第一跳连接 |
| Mac 拒绝 Device Key | Jump Host 连接成功，但内层 Mac 认证失败 |
| VPS 主机密钥变更 | 立即停止，先通过 VPS 控制台核对指纹再决定是否信任 |
| Mac 主机密钥变更 | 立即停止，先在 Mac 本机核对指纹再决定是否信任 |

## 添加或迁移到新 VPS

请将新 VPS 视为全新的安全边界，不要直接在原路径上覆盖修改。

### 阶段 1：并行准备新 VPS

1. 更新操作系统补丁并安装受维护的 OpenSSH 服务端。
2. 通过云厂商控制台确认新 VPS 的主机密钥指纹：

   ```bash
   sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

3. 在云防火墙中仅放行 VPS 的 SSH 端口，切勿开放反向转发端口。
4. 创建全新的受限隧道账户与 Jump 账户。
5. 为新 VPS 生成一把新的隧道密钥，不要复用旧 VPS 的隧道密钥。
6. 在新的 Jump 账户上授权现有的 Heeler Device Key（Device Key 私钥从未离开 iOS，因此可以继续使用同一把）。
7. 应用 `sshd_config` 限制，并使用 `sshd -t` 与 `sshd -T` 进行校验。

在此阶段，旧 VPS 及其隧道保持原样运行。

### 阶段 2：在 Mac 上并行搭建新路径

在 Mac 上新增一组 SSH 别名，不要直接修改旧别名：

```text
new-vps-tunnel
new-vps-jump
new-mac
```

创建第二个 LaunchAgent，配置：

- 不同的 `Label`；
- 新的隧道密钥；
- 新的 VPS 别名；
- 独立的日志文件。

两台不同 VPS 上可以使用相同的回环端口号（如 `2222`）；如果新路径与另一台 Mac 共用同一台 VPS，请分配不同的端口号。

启动新隧道并验证：

```bash
ssh new-mac
```

在新 VPS 上运行：

```bash
sudo ss -ltnp | grep ':2222'
```

确认监听地址严格为 `127.0.0.1:2222`，然后手动终止一次新隧道进程，证明新的 LaunchAgent 能够自动重连。

### 阶段 3：切换 Heeler

在 Heeler 中打开该 Host 并轻点 **Edit**，点进 **Routes** 下的路由（或新增一条路由），仅修改 Jump Host 相关字段：

| 字段 | 值 |
|---|---|
| Jump Host address（在 Route 中） | `NEW_VPS_PUBLIC_IP` |
| Jump Host port（在 Route 中） | `NEW_VPS_SSH_PORT` |
| Jump Host user（在 Route 中） | 新的受限 Jump 账户 |

路由目标与 Host 用户保持不变：

| 字段 | 值 |
|---|---|
| Address（在 Route 中） | `127.0.0.1` |
| Port（在 Route 中） | `2222` |
| User | `MAC_USER` |

保存路由（如新增路由则轻点 **Save**）并在 **Edit Host** 页面轻点 **Save**。出现提示时核对并确认新 VPS 的指纹，随后完成 **Preflight** 预检并通过 Attach 打开一个 Agent。至此完成功能切换。

### 阶段 4：下线旧 VPS

仅在新路径通过命令行与应用端双重验证后，按顺序执行：

1. 停止并卸载旧的 LaunchAgent。
2. 确认新的 LaunchAgent 依然运行正常。
3. 从 Mac 上移除旧的 SSH 别名以及旧 VPS 的 `known_hosts` 记录。
4. 从旧 VPS 的 Jump 账户中移除 Device Key。
5. 移除旧 VPS 上的隧道公钥与受限账户。
6. 关闭旧 VPS 的防火墙规则或直接销毁旧 VPS。

条件允许时可保留短暂的回滚观察期，但不要让两台公网 Jump Host 长期无人维护地并存。

如果在切换期间遇到 `remote port forwarding failed for listen port 2222`，请先排查是哪个隧道进程占用了端口，不要盲目放宽安全策略。这通常是因为两个隧道进程在同一台 VPS 上争用同一个监听端口；切勿通过开启 `GatewayPorts yes` 或开放非受限端口来“解决”。

## 密钥吊销与轮换

### iOS 设备丢失或更换

从以下所有位置移除该设备对应的公钥行：

- 每台在用 VPS 上的 `/home/herdr-jump/.ssh/authorized_keys`；
- 每台可达 Mac 上的 `~/.ssh/authorized_keys`。

在新设备上生成新的 Device Key 并单独注册授权。

### 隧道密钥泄露

1. 在 Mac 上生成新的专用隧道密钥。
2. 替换对应 VPS 隧道账户中的旧公钥。
3. 更新 Mac 上的 SSH 别名与 LaunchAgent。
4. 验证自动重连正常后，删除旧私钥。

单独持有隧道密钥无法打开 VPS Shell，也无法通过 Mac 的身份认证。

### VPS 被攻陷

请使用全新的主机密钥和全新的隧道密钥重建一台干净的 VPS，并将旧 VPS 的主机密钥、受限账户、日志及防火墙策略全部视为不可信。只要攻击者没有拿到 iOS 私钥或其他 Mac 凭证，Mac 上的 Device Key 无需轮换。

## 验证清单

- [ ] 已通过带外可信渠道核对 VPS SSH 主机密钥指纹。
- [ ] VPS 公网防火墙仅暴露目标 SSH 服务端口。
- [ ] 隧道账户与 Jump 账户均拒绝密码认证。
- [ ] 隧道账户仅允许向 `127.0.0.1:2222` 进行远程端口转发。
- [ ] Jump 账户仅允许向 `127.0.0.1:2222` 进行本地端口转发。
- [ ] 两个受限账户均设置了 `MaxSessions 0`。
- [ ] VPS 上 `ss` 输出为 `127.0.0.1:2222`，绝非 `0.0.0.0:2222`。
- [ ] Mac 到 VPS 的隧道由 `launchd` 托管。
- [ ] 杀掉隧道进程后能自动生成新 PID 并恢复连接。
- [ ] Heeler 分别校验了 VPS 与 Mac 的主机密钥。
- [ ] Device Key 在两跳上均已完成授权。
- [ ] `ssh` 或等效的端到端实测可连通 Mac。
- [ ] Heeler 预检与 Attach 均可通过 Jump Host 正常工作。

## 参考资料

- [OpenSSH `sshd_config`](https://man.openbsd.org/sshd_config)
- [OpenSSH `authorized_keys` 选项](https://man.openbsd.org/sshd#AUTHORIZED_KEYS_FILE_FORMAT)
- [Apple：允许远程电脑访问你的 Mac](https://support.apple.com/guide/mac-help/mchlp1066/mac)
- [传输层 ADR](../../adr/0011-libssh2-direct-streamlocal-transport.md)
- [配对 ADR](../../adr/0007-pairing-via-herdr-plugin.md)
