# 语音包分支自动化路线

目标：在不砍掉现有 Mac 麦克风能力的前提下，把“豆包级语音体验”拆成可复跑、可验收、可回退的一条分支路线。当前这一版只落路线和自检通道，不直接接入云端密钥、不训练或上传任何声音样本。

## 分支边界

- Mac 主线已接入的系统麦克风、`Speech` 一次性听写、`AVSpeechSynthesizer` 兜底语音必须保留。
- 语音包分支只新增 provider 边界、音色库描述、外部服务接入点和自检；不把大模型语音运行时塞进 AppKit 主进程。
- 声音复刻只允许用户本人或明确授权的声音；没有授权记录时不得创建 voice clone。
- 所有云端 provider 必须走环境变量或本地未提交配置，不把 API Key 写进仓库。

## 自动化路线

### V0：路线与护栏

交付物：

- `docs/VOICE_PACK_BRANCH_AUTOMATION.md`
- `scripts/selftest_voice_pack_branch.sh`
- 保留 `characters/xiaoqi/voice.json` 作为当前 voice pack seed

验收：

- 编译通过。
- `Info.plist` 有麦克风和语音识别权限说明。
- `SelfTest-Mac.command` 暴露 `speechRecognitionOneShot`、`microphoneAutoDetect`、`japaneseLanguageCycle`。
- 自检报告生成到 `reports/voice-pack-selftest/<UTC时间>/report.md`。

### V1：Provider 协议层

当前本版已推进：

- 已新增 `VoiceInputProvider`、`SpeechRecognitionProvider`、`SpeechSynthesisProvider` 三个协议。
- 已把系统麦克风、系统语音识别、系统语音合成包装成默认 provider。
- 已新增 `VoicePackManifest` 和 `loadVoicePackManifest`，读取 `characters/<pack>/voice.json`。
- `SelfTest-Mac.command` 已输出 `voicePack`、`voiceProviders` 和 V1 feature flags。

计划交付：

- `VoiceInputProvider`：麦克风输入与录音会话。
- `ASRProvider`：系统 ASR / 云端 ASR / 本地 ASR 的统一接口。
- `TTSProvider`：系统 TTS / 云端 TTS / 本地 voice pack 的统一接口。
- `VoicePackManifest`：音色库元数据，记录 provider、语言、授权、voiceId、样本路径。

验收：

- 不配置第三方服务时，仍使用系统语音和当前 Mac 麦克风入口。
- provider 切换失败时自动回退系统语音，不影响文字聊天。
- 自检能列出当前 provider、fallback、voice pack manifest 状态。

### V2：豆包 / 火山云端语音

当前本版已推进：

- 已新增 `DoubaoCloudSpeechRecognitionProvider` 状态 provider，先做云端 ASR 配置和自检地基。
- `characters/xiaoqi/voice.json` 已新增 `cloudASR` 配置块，记录 endpoint 与环境变量名；默认 endpoint 为空，未配置时明确回退系统 ASR。
- 已新增 `DoubaoCloudSpeechSynthesisProvider`，用于短文本云端 TTS；当前优先支持新版 API Key / TTS 2.0 调用，同时保留 AppID + AccessToken 兼容。
- `characters/xiaoqi/voice.json` 已切到 `provider = doubao-cloud`，同时保留 `fallback = system`。
- 云端 ASR 配置只记录环境变量名：`DOUBAO_ASR_APP_ID`、`DOUBAO_ASR_ACCESS_TOKEN`、`DOUBAO_ASR_API_KEY`、`DOUBAO_ASR_CLUSTER`、`DOUBAO_ASR_LANGUAGE`。
- 云端 TTS 配置只记录环境变量名：`DOUBAO_TTS_API_KEY`、`DOUBAO_TTS_VOICE_TYPE`、`DOUBAO_TTS_RESOURCE_ID`，并保留 `DOUBAO_TTS_APP_ID` / `DOUBAO_TTS_ACCESS_TOKEN` 兼容旧控制台。
- 已记录用户选定音色 `zh_female_vv_uranus_bigtts`，默认 `resourceId = seed-tts-2.0`。
- 未配置环境变量时不报错、不阻断 App，ASR 仍走 macOS `Speech`，TTS 走系统 `AVSpeechSynthesizer`。
- `SelfTest-Mac.command` 会输出 `voiceProviders.cloudASR` 和 `voiceProviders.cloudTTS` 状态。

计划交付：

- `DoubaoASRProvider`：语音转文字的真实调用链。
- `DoubaoTTSProvider`：文本转语音的真实调用链。
- ASR 真实调用链与旧版语音环境变量兼容层。
- 云端失败回退到系统 ASR/TTS。

验收：

- 未配置密钥时自检显示 `providerUnavailable`，但 App 可正常启动。
- 配置密钥后可以完成一次“听一句 -> 转文字 -> 回复 -> 合成语音”。
- 日志只记录 provider 状态，不记录密钥和完整用户音频。

当前云端 ASR 配置方式：

当前云端 ASR 只完成配置和状态探测地基，尚未替代 macOS `Speech`。如果后续接真实服务，建议先放入本机环境变量，不写进仓库：

```bash
export DOUBAO_ASR_APP_ID="你的火山/豆包 app id"
export DOUBAO_ASR_ACCESS_TOKEN="你的火山/豆包 access token"
export DOUBAO_ASR_API_KEY="如服务要求 api key，则填这里"
export DOUBAO_ASR_LANGUAGE="zh-CN"
```

`characters/xiaoqi/voice.json` 里的 `cloudASR.endpoint` 目前保持为空，表示没有绑定具体云端 ASR 接口。自检会显示 `voiceProviders.cloudASR.available=false`，App 仍走系统语音识别。

当前云端 TTS 配置方式：

```bash
export DOUBAO_TTS_API_KEY="你的豆包语音 API Key"
export DOUBAO_TTS_VOICE_TYPE="zh_female_vv_uranus_bigtts"
export DOUBAO_TTS_RESOURCE_ID="seed-tts-2.0" # 可选；不填使用 voice.json 默认值
./RunDesktopPet-Mac.command
```

未设置 API Key 时，`voiceProviders.cloudTTS.available=false`，App 自动回退到系统 `AVSpeechSynthesizer`。已选音色 `zh_female_vv_uranus_bigtts` 会从 `voice.json` 作为默认 `voice_type` 读取；如需换音色，只改 `DOUBAO_TTS_VOICE_TYPE` 环境变量即可。

### V3：开源音色库

计划交付：

- 本地 voice library 目录，例如 `voice-packs/`。
- 支持开源音色 manifest：Piper / OpenVoice / CosyVoice / GPT-SoVITS 作为候选，不把模型权重直接提交进仓库。
- 为每个音色记录 license、source、language、quality、runtime。

验收：

- 用户能在设置里看到可用音色和授权状态。
- 缺模型、缺运行时、缺文件时显示清楚原因。
- 自检能检查 manifest 完整性和 license 字段。

### V4：用户本人声音复刻

计划交付：

- 录音向导：录制授权句和参考音频。
- consent 记录：声音属于谁、授权范围、创建时间、可删除。
- clone provider：优先云端声音复刻，后续再考虑本地 sidecar。
- 删除入口：删除样本、voiceId 映射和本地元数据。

验收：

- 没有授权句不能开始复刻。
- 不能默认导入他人音频。
- 删除后 App 不再使用该音色。
- 自检能报告授权记录存在性，但不输出音频内容。

## 每版完成后的通知格式

每做完一版，交付消息必须包含：

- 做了哪些文件和能力。
- 没做哪些，尤其是没有接入密钥、没有上传音频、没有训练音色时要说清楚。
- 用户应从哪些方面校验。
- 自检命令和报告路径。
- 是否保留了 Mac 麦克风功能。

## 用户校验重点

- 麦克风：点“听”，系统权限弹窗和默认/外接麦克风提示是否正常。
- 识别：说一句中文、英文、日文短句，是否进入输入框并发送。
- 合成：中文、英文、日文回复是否能发声，语音开关是否还能静音。
- 语言：主界面语言按钮是否按中文、English、日本語循环。
- 任务包：不会安装的用户是否能看懂“复制选中 / 打开目录”的路径。
- 稳定：退出后锁是否释放，`./scripts/mac_soak_runner.sh --duration 120 --interval 30` 可做短跑。

## 自检通道

```bash
./scripts/selftest_voice_pack_branch.sh
```

该脚本会生成 Markdown 报告，作为每版交付的固定附件。
