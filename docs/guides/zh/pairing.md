<!-- Translated from docs/guides/pairing.md at ed1e9e66 -->

# 扫码配对 Host

在运行 herdr 的机器上显示配对码（Pairing Code），再用 Heeler 扫描。Host 添加后，密钥和指纹都已配置好，无需填写任何表单。

## 开始之前

- 一台运行 [herdr](https://herdr.dev/docs/install/) 0.7.5 或更高版本的 Mac 或 Linux 机器，并安装 [Node.js](https://nodejs.org/) 20 或更高版本。Windows Host 不支持配对，请按 [Windows 配置](windows-setup.md)手动添加。
- iPhone 或 iPad 与这台机器处于同一网络（例如同一个 Wi-Fi），或连接到同一个 VPN。配对不会使用 Heeler 中 **Settings > Overlay Networks** 里的网络；这些网络可以在配对完成后再添加，用于[外出时使用](#外出时使用)。
- 预留约两分钟：配对码只能使用一次，两分钟后失效。

## 1. 开启 SSH

**运行位置：Mac 或 Linux**

在 Mac 上，开启 **System Settings > General > Sharing > Remote Login**（系统设置 > 通用 > 共享 > 远程登录），并允许你的账户访问（参见 [Apple 官方指南](https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac)）。请保持 Mac 处于唤醒状态。

在 Linux 上，安装并启动 OpenSSH 服务器。在 Debian 或 Ubuntu 上运行：

```sh
sudo apt install openssh-server
sudo systemctl enable --now ssh
```

如果开启了防火墙，请放行 SSH（端口 22）。

然后确认[开始之前](#开始之前)中要求的版本：

```sh
herdr --version
node --version
```

## 2. 安装 Heeler 插件

**运行位置：Mac 或 Linux**

```sh
herdr plugin install ZingerLittleBee/Heeler --ref plugin --yes
```

herdr 会下载并构建插件。当插件版本低于当前 Heeler 所需的版本时，Heeler 中该 Host 的页面会给出提示，并可以直接帮你更新；在 Host 上再次运行同一条命令也能更新。

## 3. 显示配对码

**运行位置：Mac 或 Linux**

用 Heeler 将要登录的账户打开 herdr（运行 `herdr`），并把窗口调大到约 40 行高、90 列宽，以便完整显示二维码。在 herdr 的任一窗格中运行：

```sh
herdr plugin action invoke heeler.pair
```

配对码会以弹窗形式显示在 herdr 窗口之上。

1. 弹窗会列出这台机器的网络地址。勾选 iPhone 或 iPad 能够访问到的每个地址，通常是机器的 Wi-Fi 或以太网地址：用方向键移动，按空格键勾选或取消勾选。每个勾选的地址都会成为该 Host 的一条路由，因此可以勾选多个。如果其中没有 iPhone 或 iPad 能访问到的地址，请参见[通过端口映射配对](#通过端口映射配对)。
2. 按 Enter。弹窗会显示二维码及其失效时间。

扫码期间请保持弹窗打开，不要按任何键。除 `c` 以外的任何按键都会关闭弹窗并作废配对码。

## 4. 在 Heeler 中扫码

**运行位置：iPhone 或 iPad**

1. 打开 **Hosts**，轻点 **Scan to Pair**（**+** 旁边的二维码按钮）。在带侧边栏的 iPad 上，从侧边栏底部打开 **Hosts**。
2. 允许访问相机；如果 iOS 询问，也请允许访问本地网络中的设备。然后将相机对准二维码。
3. 配对会立即开始，Heeler 会逐项显示每个步骤的完成情况。无需核对指纹：配对码中已包含指纹。

配对完成后，Heeler 会打开新添加的 Host 并运行检查。

如果无法使用相机，请在弹窗中按 `c`。在 Mac 上，这会复制配对码；把它传到 iPhone 或 iPad 上（例如通过通用剪贴板），然后在 **Scan to Pair** 中轻点 **Paste Pairing Code**。在 Linux 上，按 `c` 会在二维码下方打印配对码：把它发送到 iPhone 或 iPad（例如发到自己的备忘录或消息中），在设备上复制后按同样方式粘贴。

**接着运行于：Mac 或 Linux**

弹窗会显示 **Device paired** 以及刚刚添加的密钥。如果你刚才并没有配对设备，请按 `r` 撤销该密钥。按其他任意键关闭弹窗。

**成功的标志是** 弹窗显示 **Device paired**，且该 Host 在 Heeler 中的检查全部通过，Agent 或终端能够正常加载。

## 配对之后

- Host 会以你的用户名和这台机器的地址命名。如需重命名，请从 **Hosts** 中打开它并轻点 **Edit**。
- Heeler 使用这台设备的 Device Key（设备密钥）登录。如需配对另一台 iPhone 或 iPad，请在那台设备上重复步骤 3 和步骤 4。
- 如果这台机器已经在 **Hosts** 中，再次配对会新增一个条目。在不再需要的条目上向左轻扫并轻点 **Remove** 即可移除。
- 如需在 Agent 需要你处理或完成任务时收到提醒，请前往 **Settings > Notifications**，依次轻点 **Enable Notifications** 和 **Continue**，并在 iOS 询问时允许通知。然后为该 Host 开启 **Notifications**。

## 外出时使用

配对得到的 Host 只包含你勾选的地址，因此只能在这些地址可达的网络中连接。如需通过蜂窝网络访问，请先配置 [Overlay Network](overlay-networks.md) 或 [Jump Host](vps-jump-host-setup.md)，再把通过它访问 Host 所用的地址添加为另一条路由，参见[通过多条路由访问 Host](host-routes.md#添加路由)。Heeler 会使用最先连通的那条路由。

## 通过端口映射配对

**运行位置：Mac 或 Linux**

弹窗只会列出这台机器自身网络接口上的地址。如果 iPhone 或 iPad 需要通过其他方式访问 herdr，例如 herdr 运行在 Docker 容器中、其 SSH 通过 NAS 上的某个端口对外发布，或者机器位于 NAT 之后，请告诉插件要写入配对码的地址和端口。此功能需要 Heeler 插件 0.6.2 或更高版本；如需更新，请重新运行[第 2 步](#2-安装-heeler-插件)中的安装命令。

1. 找到插件的配置目录：

   ```sh
   herdr plugin config-dir heeler
   ```

2. 在该目录中创建 `pair.json`，写入 iPhone 或 iPad 能访问到的地址（IP 或主机名）和 SSH 端口。例如容器发布在 NAS（192.168.1.10）的 2222 端口上：

   ```json
   {"ssh_port": 2222, "addresses": ["192.168.1.10", "nas.example.com"]}
   ```

3. 重新运行 `herdr plugin action invoke heeler.pair`。`pair.json` 中的地址会排在弹窗最前面并已勾选，机器自身的地址排在其后，默认不勾选。

该端口必须通向运行 herdr 的那台机器上的 OpenSSH 服务器，因为配对码携带的是它在 `/etc/ssh` 下的主机密钥指纹。如果弹窗提示无法使用 `pair.json`，请修正该文件，按 `q` 后重新运行命令。各字段的完整说明见[插件 README](../../../plugin/README.md#install)。

## 故障排查

| 现象 | 处理方法 |
| --- | --- |
| 终端显示 **no herdr server is running** | 先运行 `herdr`，再在它的某个窗格中运行该命令。 |
| 二维码底部显示不全 | 调大 herdr 窗口或缩小终端字号，然后按 `q` 并重新运行该命令。 |
| **No SSH host key found under /etc/ssh.**（弹窗） | 开启“远程登录”（Remote Login），或运行 `sudo ssh-keygen -A`，然后重新运行该命令。 |
| **No routable network address found.**（弹窗） | 将机器连接到 Wi-Fi、以太网或 VPN，然后重新运行该命令。 |
| 弹窗中没有 iPhone 或 iPad 能访问到的地址，例如只有 `172.17.x.x` 这样的容器地址 | herdr 位于端口映射或 NAT 之后。按[通过端口映射配对](#通过端口映射配对)的说明，把 iPhone 或 iPad 能访问到的地址写入 `pair.json`，然后重新运行该命令。 |
| **The Host did not answer at any of its addresses.** | 让 iPhone 或 iPad 与机器处于同一网络或 VPN，确认 iOS 的 **Settings > Privacy & Security > Local Network**（设置 > 隐私与安全性 > 本地网络）中已允许 Heeler，并确认已开启“远程登录”，然后轻点 **Try Again**。 |
| **This Pairing Code has expired.**、**The Host rejected this Pairing Code.** 或 **The Host has no pairing in progress for this code.** | 配对码只能使用一次，有效期两分钟，弹窗关闭后也会失效。在弹窗中按 Enter 生成新的配对码，或重新运行该命令，然后轻点 **Scan Again**。 |
| **Enrollment did not complete, likely a network hiccup.** 或 **This device was enrolled, but the verifying reconnect did not get through.** | 轻点 **Try Again**。 |
| **Tailscale SSH answers port 22…**（弹窗或 Heeler） | 配对需要 OpenSSH，而 Tailscale SSH 会接管 Tailscale 地址上的 22 端口。取消勾选该地址并改用局域网地址配对，或在机器上关闭 Tailscale SSH。如果仍要通过 Tailscale 配对，请按[插件 README](../../../plugin/README.md#install) 的说明在 `pair.json` 中设置 `ssh_port`。然后生成新的配对码并轻点 **Scan Again**。 |
| **The Host accepted this Pairing Code, but its pairing command ended without answering.** | 重新运行安装命令，并确认应答 22 端口的是机器自带的 OpenSSH 服务器（远程登录）。然后生成新的配对码并轻点 **Scan Again**。 |
| 提示更新 App 和配对插件 | 如果显示了 **Try Again**，请再试一次。否则请更新 Heeler 并重新运行安装命令，然后生成新的配对码并轻点 **Scan Again**。 |
| **Camera Access Needed** 或 **Scanning Unavailable** | 轻点 **Open Settings** 并允许访问相机，或使用 **Paste Pairing Code**。 |

配对错误会显示在弹窗或 Heeler 中，不会写入 herdr 的插件日志。

核对依据为 Heeler 插件 0.6.0（2026-10-14）。
