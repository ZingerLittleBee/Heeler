<!-- Translated from docs/guides/easytier.md at 57da6542 -->

# 通过 EasyTier 连接 Heeler

EasyTier 将 Heeler 与你的 Mac 接入同一个私有 Overlay Network，使 Heeler 能通过 SSH 连接 Mac。Heeler 会直接加入该网络，因此手机上无需安装 EasyTier 应用或配置系统 VPN。

你需要使用包含 **Settings > Overlay Networks** 的 Heeler 版本。

在 Heeler 中配置 EasyTier 有两种模式：

| 模式 | 在 Heeler 中的操作 | 适用场景 |
| --- | --- | --- |
| **Network** | 手动填写网络名称、密钥和 Mac 地址 | 大多数用户 |
| **Config Server** | 输入服务器地址，由管理员在 Web 控制台分配网络 | 由他人统一管理的设备 |

两种模式在家庭局域网内均可直接使用。如需在蜂窝网络或外网环境下连接，请参阅[在局域网外连接 Mac](#在局域网外连接-mac)。

## 开始之前

- 先完成[准备 Host](overlay-networks.md#准备-host)（开启“远程登录”、启动 herdr 并配置登录方式）。
- 在 **System Settings > Network** 中查看 Mac 的局域网 IP 地址。下文示例使用 `192.168.1.20`。
- 选定一个网络名称和一个高强度密钥（该密钥不是你的 SSH 密码）。

下文示例使用以下数值：

| 值 | 示例 |
| --- | --- |
| 网络名称 | `heeler-home` |
| Mac 的 EasyTier 监听地址 | `tcp://192.168.1.20:21010` |
| Mac 在 Overlay Network 内的虚拟地址 | `10.144.144.2` |
| Heeler 在 Overlay Network 内的虚拟地址 | `10.144.144.3` |

## Network 模式：直接连接 Mac

### 1. 在 Mac 上安装 EasyTier

1. 从 [EasyTier v2.6.4 发布页](https://github.com/EasyTier/EasyTier/releases/tag/v2.6.4)下载压缩包：Apple 芯片下载 `easytier-macos-aarch64-v2.6.4.zip`，Intel 芯片下载 `easytier-macos-x86_64-v2.6.4.zip`。
2. 在“下载”（Downloads）目录解压，然后在终端中运行以下命令（Intel Mac 请将 `aarch64` 改为 `x86_64`）：

   ```sh
   ET_BIN="$HOME/Downloads/easytier-macos-aarch64"
   "$ET_BIN/easytier-core" --version
   ```

   正常应输出 `2.6.4`。
3. 首次运行 EasyTier 程序时，macOS 会拦截它。请打开 **System Settings > Privacy & Security**，为该程序点击 **Open Anyway**（仍要打开），然后重新运行上面的命令。请勿关闭 Gatekeeper。

### 2. 在 Mac 上启动 EasyTier

在第 1 步的同一个终端窗口中运行以下命令。请将 `192.168.1.20` 替换为你 Mac 的局域网 IP，并在提示时输入你设定的网络密钥。

```zsh
read -rs 'ET_NETWORK_SECRET?EasyTier network secret: '
printf '\n'
export ET_NETWORK_SECRET
ET_LISTEN_HOST=192.168.1.20

"$ET_BIN/easytier-core" \
  --network-name heeler-home \
  --hostname heeler-mac \
  --ipv4 10.144.144.2/24 \
  --listeners "tcp://$ET_LISTEN_HOST:21010" \
  --rpc-portal 127.0.0.1:15888 \
  --no-tun \
  --private-mode true \
  --disable-upnp \
  --disable-p2p \
  --accept-dns false
```

- 如果 macOS 弹窗询问是否允许传入网络连接，请选择允许。
- 请保持该终端窗口打开；关闭窗口后 EasyTier 也会停止。
- 任何加入该网络的设备都能访问 Mac 本机监听的 SSH 及其他服务，请妥善保管网络密钥。
- 建议将密钥保存在密码管理器中，下一步需要在 Heeler 中输入。

### 3. 在 Heeler 中添加网络

打开 **Settings > Overlay Networks > Add Network**，选择 **EasyTier**，并保持选中 **Network**。

| 字段 | 值 |
| --- | --- |
| Name | `Home EasyTier` |
| Device name | 任意名称，或保留默认值 `heeler` |
| Network name | `heeler-home` |
| Secret | 在 Mac 上设定的网络密钥 |
| Peers | `tcp://192.168.1.20:21010`（换成你 Mac 的 IP） |
| Advanced > Fixed IPv4 | `10.144.144.3/24`（可选；留空则自动分配地址） |

<a href="../images/overlay-networks/easytier-manual-form.png"><img src="../images/overlay-networks/easytier-manual-form.png" width="300" alt="EasyTier Network 表单，包含 Name、Device name、Network name、Secret 和 Peers"></a>

轻点 **Add and Connect**。当网络状态变为 **Connected** 后，你的 Mac 会显示在 **Peers** 列表中，地址为 `10.144.144.2`。

### 4. 将 Mac 添加为 Host

轻点 **Peers** 下方 Mac 旁的 **Add**，或按[从 Heeler 连接](overlay-networks.md#从-heeler-连接)的步骤添加 Host，并将 Network 设为 **Home EasyTier**。

- Address：`10.144.144.2`，端口 `22`
- User：你的 Mac 用户名，以及所选的登录方式
- Jump Host：留空

保存后，核对 SSH 指纹与 Mac 一致再轻点信任，然后完成[验证连接](overlay-networks.md#验证连接)。如需测试蜂窝网络连接，请先完成下方的[在局域网外连接 Mac](#在局域网外连接-mac)。

## Config Server 模式：从 Web 控制台下发网络

当有人为你托管 EasyTier Config Server 时可以使用此模式。管理员会在控制台为你的手机分配网络，无需在手机上手动输入网络名称和密钥。Mac 端仍按上面 [Network 模式第 2 步](#2-在-mac-上启动-easytier)的方式运行 EasyTier。

### 1. 获取服务器地址

向服务器管理员获取 **Configuration URL**（配置地址）。该地址以你的账户名结尾，例如 `tcp://192.168.1.20:22550/USER` 或 `wss://et.example.com/USER`（注意它不是 Web 控制台的网页地址）。

请仅使用你信任的配置服务器，因为服务器知晓它下发的网络密钥。通过互联网连接时请使用 `wss://` 地址。

<details>
<summary>可选：在家庭局域网内自建 Config Server</summary>

完成[在 Mac 上安装 EasyTier](#1-在-mac-上安装-easytier) 后，打开一个新终端窗口并运行（Intel Mac 请将 `aarch64` 改为 `x86_64`）：

```sh
ET_BIN="$HOME/Downloads/easytier-macos-aarch64"
ET_WEB_DATA="$HOME/Library/Application Support/Heeler-EasyTier-Console"
mkdir -p "$ET_WEB_DATA"
chmod 700 "$ET_WEB_DATA"
umask 077

"$ET_BIN/easytier-web-embed" \
  --db "$ET_WEB_DATA/et.db" \
  --config-server-port 22550 \
  --config-server-protocol tcp \
  --api-server-port 11750 \
  --api-server-addr 127.0.0.1 \
  --web-server-addr 127.0.0.1 \
  --api-host http://127.0.0.1:11750 \
  --console-log-level warn
```

1. 在 Mac 浏览器中打开 `http://127.0.0.1:11750` 并注册账号。EasyTier 还会创建默认账号，请及时修改默认密码。
2. 你的配置地址为 `tcp://192.168.1.20:22550/USER`（替换为你的 Mac IP 和账户名）。
3. 22550 端口对整个局域网开放，请仅在受信任的局域网内使用。

该服务仅在家庭局域网内有效。如需从公网访问，需要在 HTTPS 反向代理后配置 `wss://` 地址，超出本指南范围。

</details>

### 2. 注册 Heeler 设备

1. 打开 **Settings > Overlay Networks > Add Network**，选择 **EasyTier**，然后切换到 **Config Server**。
2. 输入一个与其他网络不重名的 **Name**，例如 `Home EasyTier Console`。
3. 在 **Server** 中粘贴配置地址。
4. 填写易于识别的 **Device name**，保持 **Advanced** 为 **Encryption required**。
5. 记下页面显示的 **Machine ID**，然后轻点 **Add and Connect**。

<a href="../images/overlay-networks/easytier-config-server-form.png"><img src="../images/overlay-networks/easytier-config-server-form.png" width="300" alt="EasyTier Config Server 表单，包含服务器地址和本机 Machine ID"></a>

Heeler 会先显示 **Connecting…**，随后变为 **Waiting for a network**。此时你的手机会以设定的设备名和 Machine ID 出现在 Web 控制台中。

### 3. 在控制台中分配网络

在 Web 控制台中打开手机对应的设备页面，选择 **Create Network**，并按以下内容填写：

| 控制台设置 | 值 |
| --- | --- |
| Network Name | `heeler-home` |
| Network Secret | Mac 使用的网络密钥 |
| Virtual IPv4 | `10.144.144.4`，斜杠后填 `24`；取消勾选 **DHCP** |
| Networking Method | **Manual** |
| Peer URLs | `tcp://192.168.1.20:21010`；如果使用[中继](#在局域网外连接-mac)，则填 `tcp://YOUR_VPS_IP:21010` |
| Advanced Settings > Disable Encryption | 保持不勾选 |

点击 **Run Network**（仅保存不会生效，必须运行该网络）。

此时 Heeler 中该网络会变为 **Connected**，并将 Mac 列为对端节点。按[上文第 4 步](#4-将-mac-添加为-host)将 `10.144.144.2` 添加为 Host（Network 选择该网络），然后完成[验证连接](overlay-networks.md#验证连接)。

## 在局域网外连接 Mac

在蜂窝网络下，手机无法直接连到 Mac 的家庭内网 IP。你可以使用一台带有公网 IP 的小型 Linux 服务器（VPS）作为中继：Mac 和手机都主动向外连接 VPS，无需在家庭路由器上配置端口映射。如果你的路由器已经将公网 TCP 21010 端口映射到 Mac，也可以不使用 VPS，直接把家庭公网 IP 填入 **Peers**。

### 1. 在 VPS 上启动中继

1. 下载适用于 VPS 架构的 [v2.6.4 Linux 压缩包](https://github.com/EasyTier/EasyTier/releases/tag/v2.6.4)（`easytier-linux-x86_64-v2.6.4.zip` 或 `easytier-linux-aarch64-v2.6.4.zip`）并解压。
2. 在 VPS 系统防火墙和云厂商安全组中放行入站 **TCP 21010** 端口。
3. 在 Bash 中运行以下命令（将 `ET_BIN` 设为解压目录 `easytier-linux-x86_64` 或 `easytier-linux-aarch64`），并输入与之前相同的网络密钥。

```bash
ET_BIN="$HOME/easytier-linux-x86_64"
read -r -s -p 'EasyTier network secret: ' ET_NETWORK_SECRET
printf '\n'
export ET_NETWORK_SECRET

"$ET_BIN/easytier-core" \
  --network-name heeler-home \
  --hostname heeler-relay \
  --listeners tcp://0.0.0.0:21010 \
  --rpc-portal 127.0.0.1:15888 \
  --no-tun \
  --private-mode true \
  --disable-upnp \
  --disable-p2p \
  --accept-dns false
```

关闭 SSH 会话后中继进程会停止。临时测试可以放在 `tmux` 中运行，长期使用建议配置为系统服务。

由于 VPS 持有你的网络密钥，请仅使用由你本人控制的 VPS。

### 2. 让 Mac 连接到中继

在 Mac 终端中按 **Control-C** 停止之前的命令，改为运行以下命令（将 `YOUR_VPS_IP` 替换为你的 VPS 公网 IP）：

```sh
"$ET_BIN/easytier-core" \
  --network-name heeler-home \
  --hostname heeler-mac \
  --ipv4 10.144.144.2/24 \
  --peers tcp://YOUR_VPS_IP:21010 \
  --no-listener \
  --rpc-portal 127.0.0.1:15888 \
  --no-tun \
  --private-mode true \
  --disable-upnp \
  --disable-p2p \
  --accept-dns false
```

保持该进程持续运行。

### 3. 将 Heeler 指向中继

- **Network 模式**：点进该网络，选择 **…** > **Edit**，将 **Peers** 改为 `tcp://YOUR_VPS_IP:21010`。**Secret** 留空即可保留原密钥。
- **Config Server 模式**：在 Web 控制台中将 **Peer URLs** 改为 `tcp://YOUR_VPS_IP:21010`。同时请确保配置服务器地址也能从外网访问。

Host 的地址仍保持为 `10.144.144.2`、端口 `22`，不要改成 VPS 的地址。

测试时，请关闭手机 Wi-Fi 并打开该 Host，确认在蜂窝网络下能正常打开终端。

## 故障排查

| 问题 | 检查项 |
| --- | --- |
| 对端列表中没有出现 Mac | 确认网络名称和密钥完全一致、**Peers** 中的 IP 和端口无误、Mac 端命令仍在运行，且 Mac 防火墙已放行。 |
| 网络已连接，但 SSH 失败 | 在 Mac 上运行 `nc -vz 127.0.0.1 22`；检查 Host 的地址、端口、用户名和密钥，并查看未通过的具体检查项。 |
| Config Server 一直停在 **Connecting…** | 检查完整 URL（包括末尾的账户名），并确认手机网络能访问该服务器。 |
| Config Server 停在 **Waiting for a network** 或显示 **Failed** | 在控制台中为该 Machine ID 分配网络并点击 **Run Network**；保持 **Disable Encryption** 不勾选，并关闭端口转发、代理或出口节点等附加功能。 |
| 已分配的网络显示 **Not running** | 查看旁边显示的具体原因。 |
| Mac 提示端口已被占用 | 之前的 EasyTier 进程仍在运行，请先停止旧进程。 |
| Wi-Fi 下正常，蜂窝网络下无法连接 | 请参阅[在局域网外连接 Mac](#在局域网外连接-mac)。 |
| 切出 Heeler 后断开连接 | 预期行为，切出约 20 秒后会自动断开；返回应用后 Host 会自动重连，若终端仍未恢复可轻点 **Reattach**。 |

## 停用或移除配置

- **在 Heeler 中**：关闭网络开关即可断开连接并保留设置。如需删除网络，请先迁移或移除正在使用它的 Host。
- **在 Mac 上**：在每个运行 EasyTier 的终端窗口中按 **Control-C**，然后关闭窗口。
- **在 VPS 上**：以相同方式停止中继进程（或停止对应系统服务），并移除 TCP 21010 防火墙规则。

如需让 EasyTier 在 Mac 上开机自启，请参阅 EasyTier 的 [macOS 服务配置指南](https://github.com/EasyTier/easytier.github.io/blob/main/en/guide/network/install-as-a-macos-service.md)。

命令已对照 EasyTier v2.6.4（macOS）核对（2026 年 10 月）。

维护者：参见[指南维护记录](../../agents/overlay-network-guides.md)。
