<!-- Translated from docs/guides/voice-input.md at 68d4be8c -->
# 使用 Voice Input

轻点 Composer 中 **Send** 旁的麦克风即可开口说话，再点一下结束。Voice Input 会把转写出的文字插在草稿的光标处，在 Agent 终端和 [Chat](chat.md) 的 Composer 中都能使用，发送前可以先修改。

你需要自己准备 OpenAI、DeepInfra、ElevenLabs、SiliconFlow (China)、Volcengine (China) 或兼容语音服务的 API key。Heeler 不保留你的录音。

## 配置 Voice Input

1. 打开 **Settings > Voice Input**，或者在尚未配置 Voice Input 时直接轻点 Composer 里的麦克风。
2. 在 **Service** 中选择 **OpenAI**（`gpt-transcribe`）、**DeepInfra** 或 **SiliconFlow (China)**（`Qwen/Qwen3-ASR-1.7B`）、**ElevenLabs**（`scribe_v3`）、**Volcengine (China)**（豆包流式语音识别模型 2.0）或 **Custom**。
3. 如果选了 **Custom**，填写以下三项：
   - **Base URL**：兼容 OpenAI `audio/transcriptions` 接口的 `https://` 地址。
   - **Model**：服务要求的模型名称。
   - **Send Language**：开启后会附带设备的首选语言。如果服务拒绝该语言设置，请保持关闭。
4. 填写 **API Key**，然后轻点 **Save**。
5. 第一次保存某个服务时，Heeler 会弹出 **Send Recordings to …?** 确认。轻点 **Send Recordings** 确认。

第一次录音时，iOS 会请求麦克风权限。

你的 key 保存在本机的 Keychain 中。要删除它，打开 **Settings > Voice Input** 并轻点 **Remove Key**。

## 录制消息

轻点 **Send** 旁的麦克风开始说话，再点一下结束。转写出的文字会插在 **Message Agent** 的光标处，发送前可以先修改。

- Composer 中会出现录音条，显示取消（**✕**）、音量波形和已用时间。
- 录音时麦克风变红，**Send** 和 **Stop** 会隐藏，避免误触。
- 转写期间麦克风会转圈，这时轻点 **✕** 可以取消。
- 单次录音最长 2 分钟，到时自动结束并转写。
- 切到后台或离开 Composer 会结束录音并转写到该草稿中。进入 Direct Input、Chat 中出现 Blocked Card 替换 Composer，或离开当前 Agent 都会取消录音。

## 边说边出字，或录完再识别

**Volcengine (China)** 在 **Recognition** 下提供两种方式：

- **As You Speak**（默认）：说话时文字就显示在输入框的位置，轻点 **Stop** 或 **Send** 后加入草稿，和 On Device 一样。说话途中连接断开时，Heeler 会在你结束后把整段录音发过去。
- **After Recording**：结束录音后整段发送，文字插在光标处，和其他服务一样。

**API Key** 在火山引擎控制台的 **API Key 管理**中获取，所在项目需要开通豆包流式语音识别模型 2.0。不支持旧版控制台的 APP ID 和 Access Token。

## 语言

使用 **Volcengine** 时无需设置语言，它能识别普通话、各地方言和英语，也能识别中英混说。

使用 **ElevenLabs** 时，**Languages** 默认自动识别。手动选择时，先选主要语言，再选录音中可能出现的其他语言。

## Keywords 和 Prompt

在 **Settings > Voice Input** 中，有两个可由兼容服务共用的字段，切换 **Service** 时不会清空：

- **Keywords**：你会说到的名称和术语，用逗号分隔，例如 `herdr, Claude Code, Codex, pnpm, SwiftUI`，帮服务把它们拼对。
- **Prompt**：你说话内容的背景，原样发送。

**OpenAI** 直接读取 **Keywords**，在 **OpenAI** 下修改 **Keywords** 不会改动 **Prompt**。**DeepInfra**、**SiliconFlow (China)** 和 **Custom** 不直接读取 **Keywords**；在这些服务下编辑 **Keywords** 或切换到它们时，Heeler 会在 **Prompt** 中同步一行 `Vocabulary: …`，因此 **Prompt** 里看到的就是实际发送的内容。

**ElevenLabs** 对带关键词的录音额外收费，所以只有在它下面打开 **Send Keywords** 后才会读取 **Keywords**。超过 50 个字符或多于四个空格的关键词不会发送。ElevenLabs 不接收 **Prompt**，切回其他服务时仍可使用之前保存的 Prompt。[ElevenLabs 转写接口](https://elevenlabs.io/docs/api-reference/speech-to-text/convert)

**Volcengine** 把 **Keywords** 当作热词读取，不额外收费，不接收 **Prompt**。**As You Speak** 只用排在前面、合计约 100 个字符的 Keywords；**After Recording** 最多用 5000 个。Keywords 列得越长，效果反而越差。

## 选择麦克风

在 iOS 26 及以上系统，支持高质量录音的已连接 AirPods 会被直接使用；连接其他蓝牙耳机时，Heeler 使用 iPhone 或 iPad 的内置麦克风。

要始终使用设备内置麦克风，在 **Settings > Voice Input** 中打开 **Always Use iPhone Microphone**（在 iPad 上显示为 **Always Use iPad Microphone**）。该开关默认关闭。

## 出错时

如果录音未能转成文字，Composer 会显示原因并提供相应按钮：**Retry**（用同一段录音重新发送）、**Voice Input Settings**、**Open Settings**（麦克风权限）和 **Dismiss**。

- **The speech service rejected the API key.** — 轻点 **Voice Input Settings**，填入有效 key 并轻点 **Save**，然后轻点 **Retry**。
- **Heeler can't use the microphone. Turn it on in Settings.** — 轻点 **Open Settings**，为 Heeler 开启麦克风权限。
- **The recording was too short.** — 说话至少满半秒后再结束。

## 隐私

录音会按所选服务的条款上传，费用记在你的 key 上，Heeler 的开发者收不到录音、文字或 key。详见[隐私政策的 Voice Input 一节](../../../PRIVACY.md#voice-input)。

最后核对于 2026-11-05。
