<!-- Translated from docs/guides/cloudflare-tunnel.md at ed1e9e66 -->

# 通过 Cloudflare Tunnel 连接 Mac

Cloudflare Tunnel 通过一条只由 Mac 主动发起的出站连接把 Mac 接入 Cloudflare，路由器无需开放任何端口。手机上运行的 Cloudflare 客户端 App 再承载 Heeler 的 SSH 会话。Mac 上依然需要开启“远程登录”并运行 herdr，Host 的配置与其它指南完全一致。

这与 [Overlay Network](overlay-networks.md) 是两条不同的路径：你不需要在 **Settings > Overlay Networks** 里添加任何内容，Heeler 也不会新增一个网络。Cloudflare 自己的 App 在手机上以系统 VPN 的方式运行，使 Mac 的私有地址变为可达，然后由 Host 的路由指向该地址。

由于手机上运行的是系统 VPN，它无法与其它 VPN 应用（例如官方 Tailscale 客户端）同时启用。Heeler 内置的 Overlay Network 不属于系统 VPN，可以与它并存。

## 选择方案

| 方式 | 前置条件 | 需要自有域名 |
| --- | --- | --- |
| [私有网络路由](#1-将-mac-接入-cloudflare)（本页） | Cloudflare 账号，以及手机上的 Cloudflare One Agent App | 不需要 |
| [在 VPS 上运行客户端 `cloudflared`](#附录改用-vps-替代-vpn-应用) | Cloudflare 账号、托管在 Cloudflare 的域名，以及一台 VPS | 需要 |

## 开始之前

- 一个已开通 Zero Trust 的 Cloudflare 账号，并因此拥有 team name。个人免费计划通常足够；如果某项功能需要更高计划，控制台会明确提示。
- Mac 已完成[“远程登录”与 herdr 的准备](overlay-networks.md#准备-host)，并记下它的私有地址，例如 `192.168.1.10`。Heeler 连接的就是这个地址。
- 支持多条路由（Host Routes）的当前版本 Heeler，以及你要用来连接的手机或 iPad。

## 1. 将 Mac 接入 Cloudflare

1. 在 [Cloudflare 控制台](https://dash.cloudflare.com/)中进入 **Networking > Tunnels**，轻点 **Create a tunnel**。
2. 选择 **Cloudflared**，为隧道命名（例如 `herdr-mac`），轻点 **Save tunnel**。
3. 选择 **macOS**，复制页面给出的安装命令。该命令会安装 `cloudflared`，并用隧道的 token 把它注册为后台服务，例如：

   ```sh
   brew install cloudflared
   sudo cloudflared service install <TOKEN>
   ```

   在 Mac 的终端中执行。请使用控制台显示的完整命令；token 只对这一个隧道有效。
4. 等待隧道状态变为 **Healthy**，然后轻点 **Continue**。

关闭终端后该服务仍在运行。此时 Mac 上没有任何服务在监听来自公网的连接。

## 2. 将 Mac 的地址路由到该隧道

1. 进入 **Networking > Routes**，轻点 **Create route > Tunnel CIDR**。
2. 选择刚创建的隧道。
3. 在 **Network** 中填写 Mac 的地址并加上 `/32`，例如 `192.168.1.10/32`。填写整个网段（例如 `192.168.1.0/24`）也可以，但该网段内的所有地址都会变得可从手机访问。
4. 轻点 **Create route**。

默认情况下，组织内所有已注册的设备都可以使用这条路由。只有一台手机和一台 Mac 时这通常正是你想要的；需要用 Gateway 网络策略收窄范围时，见故障排查表的最后一行。

## 3. 注册手机

1. 从 App Store 安装 **Cloudflare One Agent**。
2. 打开后输入你的 team name，并在弹出浏览器时完成登录。允许它添加 VPN 配置。应用显示 **Connected** 即完成。
3. 在控制台进入 **Zero Trust > Team & Resources > Devices > Device profiles > General profiles**，在你所用设备对应的 profile 上轻点 **Configure**。
4. 在 **Split Tunnels** 处选择 **Include IPs and domains**，轻点 **Manage**，添加两条记录：

   | 类型 | 值 |
   | --- | --- |
   | IP address | 第 2 步填写的地址，例如 `192.168.1.10/32` |
   | Domain | `<你的-team-name>.cloudflareaccess.com` |

   **Include** 模式只把这些目标送进 VPN App，手机其它流量不受影响。在 iOS 上，域名记录会在 VPN 启动时解析，因此修改后请重连该 App。

   如果你更希望保留默认的 **Exclude** 模式，请先删掉覆盖 Mac 地址的那条记录（通常是 `192.168.0.0/16`、`10.0.0.0/8` 或 `172.16.0.0/12`），再用 [Cloudflare 的计算器](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/#remove-a-route)重新加入仍需排除的网段。不要清空整个列表：那会让手机的流量全部走 Cloudflare。

5. 配置下发到手机最长可能需要十分钟，之后请重连该 App。这里修改的设置不会立即生效。

## 4. 在 Heeler 中添加 Host

按[准备 Host](overlay-networks.md#准备-host) 中的说明，在 Mac 上准备好账户、登录方式与 herdr 会话，然后按以下步骤添加 Host：

1. 打开 **Hosts** 并轻点 **Add Host**。在 **Routes** 下轻点 **Add Route**，将 **Network** 设为 **Direct**，填写第 2 步的地址与端口 `22`，**Jump Host** 留空，然后轻点 **Save**。（**Direct** 表示由 Heeler 自己发起连接，是 VPN App 让该地址变得可达。）
2. 返回 **Add Host** 页面，填写其余字段并轻点 **Save**。
3. 仅在显示的指纹与 Mac 上的一致时轻点 **Trust**。
4. 如果 iOS 询问 Heeler 是否可以访问本地网络，请允许。Mac 的地址属于私有地址，缺少该权限时路由会失败。

在家时 Mac 通常也会在局域网地址上响应。同一个 Host 可以配置多条路由，因此可以把局域网地址作为第二条路由加入，由 Heeler 选用最先连通的一条。参见[多条路由](host-routes.md#添加路由)。

## 验证连接

1. Cloudflare One Agent 显示 **Connected**，且 **Networking > Tunnels** 中的隧道为 **Healthy**。
2. 从 **Hosts** 打开该 Host，确认标记为 **In Use** 的路由就是指向 Mac 私有地址的那一条。
3. Host 各项检查全部通过，会话中的 Agent 或终端正常加载。
4. 打开一个 **New Terminal**，运行 `pwd` 能输出 Mac 上的目录。
5. 关闭手机 Wi-Fi，在蜂窝网络下重复上述测试，并再次检查 **In Use**。
6. 切出 Heeler 超过 20 秒后再返回，确认 Host 和终端能够自动重连，并再次检查 **In Use**，确认重连使用的路由。VPN App 会在后台维护自己的连接。

## 故障排查

| 现象 | 处理方法 |
| --- | --- |
| 隧道显示 **Inactive**、**Down** 或 **Degraded** | Mac 上的后台服务没有运行。重新执行控制台给出的安装命令，然后查看 **Networking > Tunnels**。 |
| 手机已连接，但 SSH 超时 | 依次核对三处：**Networking > Routes** 中的路由 CIDR、Split Tunnels 中的同一地址，以及 VPN App 是否显示 **Connected**。再确认 Mac 未休眠且已开启“远程登录”。 |
| 路由 CIDR 正确，但流量到不了 Mac | Split Tunnels 可能仍是 **Exclude** 模式，且覆盖了 Mac 所在的网段。把 Mac 的地址加入 include 列表，或删除覆盖它的 exclude 记录。 |
| 改完设置，手机上没有任何变化 | 等待十分钟，然后断开并重新连接 VPN App。 |
| 手机就在 Mac 的局域网内，却显示 **Can't Connect** 并超时 | iOS 可能拒绝给 Heeler 本地网络权限。请检查手机上的 **Settings > Privacy & Security > Local Network**。 |
| SSH 登录失败 | 检查用户名、“远程登录”访问权限，以及所用的密钥或密码。 |
| SSH 正常，但 herdr 检查失败 | 查看未通过的具体检查项；通常是该账户下未安装 herdr，或会话名称有误。 |
| 局域网内其它设备能访问本不该访问的服务 | CIDR 路由会暴露其中的所有地址，且默认允许组织内每台已注册设备使用它。把路由收窄到 Mac 的 `/32`，并在 **Traffic policies** 中添加 Gateway 网络策略，只放行需要访问的目标。 |

## 附录：改用 VPS 替代 VPN 应用

这条路径不需要在手机上安装任何 App，但需要托管在 Cloudflare 的域名和一台小型 VPS。iOS 无法运行 `cloudflared`，因此任意 TCP 隧道的客户端部分需要运行在你已经控制的机器上，Heeler 再把它当作 Jump Host 使用。受限跳板账户的做法参见[跳板机指南](vps-jump-host-setup.md)。

1. **发布 Mac 的 SSH 端口。** 可以在控制台中为隧道添加公开主机名（**Networking > Tunnels**，**Routes > Add route > Published application**，服务类型 **TCP**，地址 `localhost:22`），也可以在本地管理：

   ```sh
   cloudflared tunnel login
   cloudflared tunnel create herdr-ssh
   cloudflared tunnel route dns herdr-ssh herdr-ssh.example.com
   ```

   并准备一个配置文件（默认路径 `~/.cloudflared/config.yml`），其 ingress 规则为 `- hostname: herdr-ssh.example.com` 与 `service: tcp://localhost:22`，然后以 `cloudflared tunnel run herdr-ssh` 运行。`cloudflared tunnel run` 不接受 `--hostname` 这类快捷参数，因此主机名要在控制台或配置文件中指定。

2. **保护该主机名。** 在 **Zero Trust > Access controls > Applications** 中为它添加一个 Self-hosted 应用，并配置 **Service Auth** 策略。在 **Access controls > Service Auth > Service tokens** 中创建 token，把 secret 保存在 VPS 上，不要放进仓库。

3. **在 VPS 上运行客户端**，并作为失败后自动重启的服务：

   ```sh
   cloudflared access tcp \
     --hostname herdr-ssh.example.com \
     --listener 127.0.0.1:2222 \
     --service-token-id <ID> \
     --service-token-secret <SECRET>
   ```

   该监听只留在 VPS 的回环接口上。

4. **在 Heeler 中添加 Host**，把路由的 **Jump Host** 设为该 VPS，地址填 `127.0.0.1`，端口填 `2222`。Heeler 先登录 VPS，向它请求这个回环端口，然后与 Mac 单独完成一次 SSH 握手。

如果始终收不到 SSH banner，且 VPS 日志中显示浏览器登录而不是使用 service token，说明你遇到了 `cloudflared` 的已知回归（[cloudflared#1674](https://github.com/cloudflare/cloudflared/issues/1674)）：该版本中 `access tcp` 忽略了 service token。请固定使用可用的版本，并在确认该 issue 后再升级。

## Cloudflare 能看到什么

SSH 会话在 Heeler 与 Mac 之间始终保持加密，Heeler 也会在发送任何数据前校验 Mac 的主机密钥。Cloudflare 看到的是连接本身：客户端地址、Mac 的地址与端口、连接建立的时间，以及传输了多少数据。在附录的方式中，它还会终止来自 VPS 的那一段连接，这一点与 Jump Host 相同。

最后核对于 2026-10-23（真实 iPhone）。

维护者：参见[指南维护记录](../../agents/overlay-network-guides.md)。