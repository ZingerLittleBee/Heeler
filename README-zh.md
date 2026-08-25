<div align="center">

<img src="docs/images/logo.png" width="96" alt="Heeler logo" />

# Heeler

**[herdr](https://herdr.dev) 的原生 iOS 伴侣应用 —— herdr 是一个 agent 优先的终端运行时。**

[![CI](https://github.com/ZingerLittleBee/Heeler/actions/workflows/ci.yml/badge.svg)](https://github.com/ZingerLittleBee/Heeler/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/ZingerLittleBee/Heeler?style=flat)](https://github.com/ZingerLittleBee/Heeler/stargazers)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![iOS](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![TestFlight](https://img.shields.io/badge/TestFlight-beta-0D96F6?logo=apple&logoColor=white)](https://testflight.apple.com/join/aXSxRn4r)

**[通过 TestFlight 加入 beta](https://testflight.apple.com/join/aXSxRn4r)**

[English](./README.md) | 简体中文

</div>

---

Heeler 是一个 **agent 控制台**：把所有机器上正在运行的 coding agent 汇成一个原生仪表盘，按"谁需要你"排序。打开一个 Agent 即可阅读并操控它的实时终端，同时在原生 Composer 里用完整的标准 iOS 键盘本地起草。Send 一次性投递完整消息；直达控制键、原生回滚和连续触摸滚动让全屏 TUI 依然好用，一切只经由普通 SSH。

## 截图

汇聚所有 Host、按优先级排序的 Agent Console；实时终端下方工具键盘的 Agent 控制键；渲染在 Composer 上方的 Agent 会话；带 Text / Keys 的普通 Terminal；输入时弹出的 Composer Skills 建议；锁屏上实时跟踪 Agent 的实时活动：

| Agent Console | Composer + 工具键盘 | 实时终端 |
| --- | --- | --- |
| ![iPhone 上的 Agent Console](docs/images/console-iphone.png) | ![iPhone 上带工具键盘的 Agent 终端](docs/images/agent-iphone.png) | ![iPhone 上 Composer 上方的 Agent 实时终端](docs/images/composer-iphone.png) |

| Terminal | Skills | 实时活动 |
| --- | --- | --- |
| ![iPhone 上带 Text / Keys 的普通 Terminal](docs/images/terminal-iphone.png) | ![iPhone 上 Composer 的 Skills 建议](docs/images/skills-iphone.png) | ![iPhone 锁屏上实时跟踪 Agent 的实时活动](docs/images/live-activity-iphone.png) |

## 功能

- **Console** —— 所有机器上的 Agent 汇成一个按状态排序的列表（Blocked
  排最前），可按 Host 过滤，靠 herdr 的事件流实时更新。
- **Attach** —— 通过 libghostty 阅读并操控 Agent 真实的实时终端：Metal
  渲染、原生回滚、也能驱动全屏 TUI 的惯性触摸滚动，以及长按选择。文字在终端
  下方本地起草，工具键盘的 Agent 控制键则直接操控实时 TUI。Attach 与
  Reattach 使用 herdr 的 takeover 模式，必要时断开先前的终端占用者。
- **Attach Links** —— 静默收集网页链接，稍后打开或复制。
- **Composer** —— 用完整的标准 iOS 键盘本地起草，自动纠错、输入法、系统听写
  都可用，然后一次 Send 投递完整消息。切换到分页工具键盘可使用直达 Agent
  控制键、可用的 Agent Skills、插入草稿的可复用 Snippets，以及终端外观设置。
- **附件暂存** —— 从"照片"添加图片，或从"文件"添加最大 64 MiB 的文件，经
  SFTP 暂存到 Host，并把路径插入本地草稿而不提交。
- **扫码配对** —— 扫描内置 herdr 插件展示的 Pairing Code 即可添加机器；
  Ed25519 Device Key 在设备上生成，私钥不离开 Keychain，配对码同时固定
  host key 指纹。
- **Agent 通知** —— Agent 进入 Blocked 或 Done 时发出端到端加密的 APNs
  推送，深链直达其终端；中继只能看到 device token、来源 IP、请求时间和
  密文，读不到通知内容。
- **实时活动** —— 锁屏与灵动岛上的 per-Host 横幅，实时跟踪 Working、
  Blocked、Done 状态的 Agent，走同一条端到端加密推送管线；无法解密细节时，
  中继与锁屏只能看到状态计数。
- **Worktrees** —— New Agent 表单上的一个开关，让 Agent 从工作区仓库的
  干净检出上启动。
- **外观** —— 应用外观可选跟随系统、浅色或深色；30 个精选终端主题，浅色与
  深色模式各占独立槽位；内置 JetBrains Mono 与 IBM Plex Mono，另有系统
  等宽字体；双指缩放字号。
- **跳板机** —— 通过 SSH 跳板访问不可直连的机器，两跳各自独立校验密钥。

## 连接原理

应用通过 SSH 使用 herdr 的 JSON API（Unix socket 上的换行分隔 JSON）：

- **RPC + 事件**：每个请求经一条 OpenSSH direct-streamlocal 通道直连 `herdr.sock`，另有一条长连接通道用于 `events.subscribe`。
- **交互终端 + Composer**：Agent 详情页申请 SSH PTY 并在其上执行 `herdr agent attach <pane> --takeover`，再经宿主管理的 libghostty-spm 会话渲染实时终端：Metal 输出、持久的外观感知主题、长按文本选择、应用接管的触摸滚动（本地回滚与远端 TUI 皆可）。草稿留在本地 Composer，直到 Send 发出一次 `agent.prompt` RPC；只有工具键盘的显式 Agent 控制键直接经 PTY 下发。

无需改动 herdr 服务器，也无需额外软件包：SSH 访问加一个运行中的 herdr 服务器就是全部前提。Host 的 SSH 服务器需允许 stream-local 转发（OpenSSH 默认开启）；若被关闭，引导流程会明确指出。

不可直连的 Host 可以放在 SSH 跳板机之后。推荐部署把反向转发端口保留在
VPS 的回环接口上，而不是公开 Mac 的 SSH 端口。

- [逐步搭建远程访问](docs/guides/vps-jump-host-setup.md)
- [自动化补充桌面客户端注册](docs/guides/vps-jump-host-setup.md#automate-additional-desktop-clients)
- [理解架构、安全边界与 VPS 迁移手册](docs/guides/vps-jump-host.md)

## 添加机器：装插件，扫码

本仓库附带一个 [herdr 插件](plugin/README.md)，通过二维码把应用与机器配对，
并经 APNs 投递 Agent 通知。在运行 herdr 的机器上（Node >= 20、herdr >=
0.7.5、已启用 OpenSSH 服务器 —— macOS 上是 **系统设置 > 通用 > 共享 >
远程登录**）：

```bash
herdr plugin install ZingerLittleBee/Heeler/plugin --ref main --yes
herdr plugin action invoke heeler.pair
```

`pair` 动作会弹出 Pairing Code 二维码；用应用扫描后机器即添加为 Host ——
地址、host key 指纹和 SSH 密钥注册全部由配对码处理，无需手动输入。在应用
设置里为该 Host 启用 Agent 通知后，同一插件会向应用推送加密的 Blocked/Done
通知；中继只能看到 device token、来源 IP、请求时间和密文，读不到通知内容
（见 [PRIVACY.md](PRIVACY.md)）。

## 技术栈

- SwiftUI，iOS 18+，当前仅支持 iPhone；iPad 支持计划在后续版本提供
- 仓库内 `Packages/HeelerSSH`（libssh2 + OpenSSL）负责 SSH
- [libghostty-spm](https://github.com/lakr233/libghostty-spm) 负责终端仿真与 Metal 渲染

选型缘由见 `docs/adr/`（传输层的故事尤其不直观）。

## 参与贡献

欢迎 Issue 和 PR：仓库结构、构建与测试方式、提交需要遵循的约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 状态

Beta，已上 [TestFlight](https://testflight.apple.com/join/aXSxRn4r)。以个人日常使用打磨为先，仍有粗糙之处，迭代较快。与 herdr 项目无隶属关系。
