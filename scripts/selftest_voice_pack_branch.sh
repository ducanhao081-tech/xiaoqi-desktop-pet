#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_ROOT="$ROOT/reports/voice-pack-selftest"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$REPORT_ROOT/$STAMP"
REPORT="$RUN_DIR/report.md"
SELFTEST_OUT="$RUN_DIR/selftest.out"
BUILD_LOG="$RUN_DIR/build.log"

mkdir -p "$RUN_DIR"

pass_count=0
fail_count=0
declare -a CHECK_LINES=()

record_check() {
  local name="$1"
  local status="$2"
  local detail="$3"
  if [ "$status" = "PASS" ]; then
    pass_count=$((pass_count + 1))
    CHECK_LINES+=("- ✅ ${name}：${detail}")
  else
    fail_count=$((fail_count + 1))
    CHECK_LINES+=("- ❌ ${name}：${detail}")
  fi
}

contains() {
  local file="$1"
  local pattern="$2"
  rg -q "$pattern" "$file"
}

json_lint() {
  local file="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$file" >/dev/null
  elif command -v ruby >/dev/null 2>&1; then
    ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' "$file" >/dev/null
  else
    echo "需要 python3 或 ruby 来校验 JSON" >&2
    return 1
  fi
}

if xcrun swiftc -parse-as-library -module-cache-path "$ROOT/.module-cache" "$ROOT/src-mac/DesktopPetMac.swift" -o "$RUN_DIR/DesktopPetMac-test" >"$BUILD_LOG" 2>&1; then
  record_check "Swift 编译" "PASS" "DesktopPetMac.swift 编译通过"
else
  record_check "Swift 编译" "FAIL" "查看 $BUILD_LOG"
fi

if plutil -lint "$ROOT/src-mac/Info.plist" >/dev/null; then
  record_check "Info.plist 格式" "PASS" "plist 可解析"
else
  record_check "Info.plist 格式" "FAIL" "plist 解析失败"
fi

if json_lint "$ROOT/config/settings.json"; then
  record_check "settings.json 格式" "PASS" "配置 JSON 可解析"
else
  record_check "settings.json 格式" "FAIL" "配置 JSON 解析失败"
fi

if json_lint "$ROOT/characters/xiaoqi/voice.json"; then
  record_check "voice.json 格式" "PASS" "voice seed 可解析"
else
  record_check "voice.json 格式" "FAIL" "voice seed 解析失败"
fi

if contains "$ROOT/src-mac/Info.plist" "NSMicrophoneUsageDescription" && contains "$ROOT/src-mac/Info.plist" "NSSpeechRecognitionUsageDescription"; then
  record_check "麦克风权限说明" "PASS" "麦克风与语音识别权限说明都存在"
else
  record_check "麦克风权限说明" "FAIL" "缺少麦克风或语音识别权限说明"
fi

if contains "$ROOT/src-mac/DesktopPetMac.swift" "import Speech" && contains "$ROOT/src-mac/DesktopPetMac.swift" "AVAudioEngine" && contains "$ROOT/src-mac/DesktopPetMac.swift" "microphoneAutoDetect"; then
  record_check "Mac 麦克风主线保留" "PASS" "Speech / AVAudioEngine / microphoneAutoDetect 均存在"
else
  record_check "Mac 麦克风主线保留" "FAIL" "Mac 麦克风相关实现缺失"
fi

if contains "$ROOT/src-mac/DesktopPetMac.swift" "nextLanguageCode" && contains "$ROOT/src-mac/DesktopPetMac.swift" "japaneseLanguageCycle"; then
  record_check "日语循环护栏" "PASS" "中英日循环与自检 flag 存在"
else
  record_check "日语循环护栏" "FAIL" "日语循环或自检 flag 缺失"
fi

if contains "$ROOT/characters/xiaoqi/voice.json" "\"provider\"" && contains "$ROOT/characters/xiaoqi/voice.json" "\"futureProvider\"" && contains "$ROOT/characters/xiaoqi/voice.json" "\"fallback\"" && contains "$ROOT/characters/xiaoqi/voice.json" "\"languages\"" && contains "$ROOT/characters/xiaoqi/voice.json" "\"consent\""; then
  record_check "Voice pack seed" "PASS" "provider / futureProvider / fallback / languages / consent 字段存在"
else
  record_check "Voice pack seed" "FAIL" "voice.json 缺少关键 voice pack 字段"
fi

if contains "$ROOT/src-mac/DesktopPetMac.swift" "protocol VoiceInputProvider" && contains "$ROOT/src-mac/DesktopPetMac.swift" "protocol SpeechRecognitionProvider" && contains "$ROOT/src-mac/DesktopPetMac.swift" "protocol SpeechSynthesisProvider"; then
  record_check "V1 Provider 协议层" "PASS" "VoiceInputProvider / SpeechRecognitionProvider / SpeechSynthesisProvider 均存在"
else
  record_check "V1 Provider 协议层" "FAIL" "缺少语音 provider 协议"
fi

if contains "$ROOT/src-mac/DesktopPetMac.swift" "struct VoicePackManifest" && contains "$ROOT/src-mac/DesktopPetMac.swift" "loadVoicePackManifest"; then
  record_check "VoicePack manifest runtime" "PASS" "manifest 结构与加载入口存在"
else
  record_check "VoicePack manifest runtime" "FAIL" "缺少 voice pack manifest runtime"
fi

if contains "$ROOT/src-mac/DesktopPetMac.swift" "DoubaoCloudSpeechSynthesisProvider" && contains "$ROOT/src-mac/DesktopPetMac.swift" "DOUBAO_TTS_API_KEY" && contains "$ROOT/src-mac/DesktopPetMac.swift" "X-Api-Resource-Id"; then
  record_check "V2 豆包云端 TTS provider" "PASS" "云端 TTS provider 支持新版 API Key 与 env guard"
else
  record_check "V2 豆包云端 TTS provider" "FAIL" "缺少豆包云端 TTS provider / API Key / env guard"
fi

if contains "$ROOT/characters/xiaoqi/voice.json" "zh_female_vv_uranus_bigtts" && contains "$ROOT/characters/xiaoqi/voice.json" "seed-tts-2.0"; then
  record_check "V2 TTS 音色配置" "PASS" "voice.json 已记录用户选定音色与 TTS 2.0 resource id"
else
  record_check "V2 TTS 音色配置" "FAIL" "voice.json 缺少用户选定音色或 TTS 2.0 resource id"
fi

if contains "$ROOT/src-mac/DesktopPetMac.swift" "DoubaoCloudSpeechRecognitionProvider" && contains "$ROOT/src-mac/DesktopPetMac.swift" "DOUBAO_ASR_APP_ID" && contains "$ROOT/src-mac/DesktopPetMac.swift" "DOUBAO_ASR_ACCESS_TOKEN"; then
  record_check "V2.5 豆包云端 ASR provider" "PASS" "云端 ASR provider 状态与 env guard 存在"
else
  record_check "V2.5 豆包云端 ASR provider" "FAIL" "缺少豆包云端 ASR provider 或 env guard"
fi

if contains "$ROOT/characters/xiaoqi/voice.json" "\"provider\": \"doubao-cloud\"" && contains "$ROOT/characters/xiaoqi/voice.json" "\"cloudASR\"" && contains "$ROOT/characters/xiaoqi/voice.json" "\"cloudTTS\"" && contains "$ROOT/characters/xiaoqi/voice.json" "\"fallback\": \"system\""; then
  record_check "V2 voice.json 云端配置" "PASS" "voice manifest 指向 doubao-cloud，包含 cloudASR/cloudTTS，且保留 system fallback"
else
  record_check "V2 voice.json 云端配置" "FAIL" "voice manifest 缺少 doubao-cloud / cloudASR / cloudTTS / system fallback"
fi

if [ -f "$ROOT/docs/VOICE_PACK_BRANCH_AUTOMATION.md" ]; then
  record_check "路线文档" "PASS" "VOICE_PACK_BRANCH_AUTOMATION.md 存在"
else
  record_check "路线文档" "FAIL" "缺少语音包路线文档"
fi

if "$ROOT/SelfTest-Mac.command" >"$SELFTEST_OUT" 2>&1; then
  record_check "SelfTest-Mac" "PASS" "SelfTest-Mac.command 退出码为 0"
else
  record_check "SelfTest-Mac" "FAIL" "查看 $SELFTEST_OUT"
fi

for flag in speechRecognitionOneShot microphoneAutoDetect japaneseLanguageCycle avSpeechSynthesizer voiceProviderProtocol voicePackManifestRuntime systemVoiceFallback staticBubbleTTSBridge doubaoCloudASRProvider cloudASRSystemFallback cloudASREnvGuard doubaoCloudTTSProvider cloudTTSSystemFallback cloudVoiceEnvGuard; do
  if contains "$SELFTEST_OUT" "$flag"; then
    record_check "SelfTest flag: $flag" "PASS" "已在 SelfTest 输出中出现"
  else
    record_check "SelfTest flag: $flag" "FAIL" "SelfTest 输出缺少该 flag"
  fi
done

if contains "$SELFTEST_OUT" "\"voicePack\"" && contains "$SELFTEST_OUT" "\"voiceProviders\"" && contains "$SELFTEST_OUT" "\"cloudASR\"" && contains "$SELFTEST_OUT" "\"cloudTTS\""; then
  record_check "SelfTest voice sections" "PASS" "SelfTest 输出 voicePack / voiceProviders / cloudASR / cloudTTS"
else
  record_check "SelfTest voice sections" "FAIL" "SelfTest 缺少 voicePack / voiceProviders / cloudASR / cloudTTS"
fi

overall="PASS"
if [ "$fail_count" -gt 0 ]; then
  overall="FAIL"
fi

{
  echo "# 语音包分支自检报告"
  echo
  echo "- 运行 ID：$STAMP"
  echo "- 项目根目录：$ROOT"
  echo "- 总体结论：$overall"
  echo "- 通过 / 失败：$pass_count / $fail_count"
  echo
  echo "## 检查项"
  echo
  printf '%s\n' "${CHECK_LINES[@]}"
  echo
  echo "## 用户校验建议"
  echo
  echo "- 点“听”，确认系统权限弹窗、默认或外接麦克风提示正常。"
  echo "- 分别说一句中文、英文、日文短句，确认能进输入框并发送。"
  echo "- 切换语言按钮，确认中文、English、日本語循环。"
  echo "- 打开任务包面板，确认“复制选中 / 打开目录”的说明能让新用户理解。"
  echo "- 打开设置，确认语音合成开关还能静音/恢复。"
  echo
  echo "## 产物"
  echo
  echo "- Swift 编译日志：$BUILD_LOG"
  echo "- SelfTest 输出：$SELFTEST_OUT"
} > "$REPORT"

echo "语音包分支自检完成：$REPORT"

if [ "$overall" != "PASS" ]; then
  exit 1
fi
