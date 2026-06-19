# 小七桌虫 · XiaoQi Desktop Pet

一个中文优先、跨平台、可自己养成的桌面小生物。不是比赛项目，也不是聊天框换皮：小七会待在桌面上移动、回应、记住偏好，并可以按需接入模型和语音服务。

![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-6f42c1)
![License](https://img.shields.io/badge/code-MIT-green)
![Assets](https://img.shields.io/badge/XiaoQi%20assets-CC%20BY%204.0-orange)

## 能做什么

- 透明、置顶、可拖动的桌面宠物窗口
- 闲逛、跳跃、睡眠和轻量捣乱动作
- 中文短句聊天、系统语音、语音输入入口
- 小七 persona、动作和状态立绘
- macOS Swift/AppKit 与 Windows PowerShell/WPF 双端实现
- 离线模板脑默认可用；DeepSeek/Anthropic-compatible 接入可选
- 本地偏好和窗口位置记忆（不会进入 Git）

## 快速开始

### macOS

需要 Apple Command Line Tools：

```bash
./SelfTest-Mac.command
./RunDesktopPet-Mac.command
```

### Windows

双击或在 PowerShell 中运行：

```powershell
.\SelfTest.cmd
.\RunDesktopPet.cmd
```

Windows 端使用系统自带 PowerShell/WPF，不要求 Node.js 或 Python。

## 可选模型接入

默认配置使用离线 `template` provider，不需要密钥。要启用兼容 Anthropic Messages API 的服务：

1. 将 `config/settings.json` 中 `brain.provider` 改为 `anthropic`。
2. 按需调整 `baseURL` 和 `model`。
3. 在启动进程环境中提供密钥：

```bash
export DEEPSEEK_API_KEY="your-key"
./RunDesktopPet-Mac.command
```

密钥只从环境变量读取。不要把 `.env`、shell 配置或真实密钥提交到仓库。

## 目录

```text
src-mac/       macOS Swift/AppKit 实现
src/           Windows PowerShell/WPF 实现
characters/    小七角色包与立绘
behavior-packs 行为配置
config/        公共默认配置
scripts/       资产处理与自测脚本
docs/          架构和格式说明
```

公开范围和排除项见 [docs/OPEN_SOURCE_SCOPE.md](docs/OPEN_SOURCE_SCOPE.md)。

## 许可证

- 程序代码：MIT，见 [LICENSE](LICENSE)
- `characters/xiaoqi/` 原创角色资产：CC BY 4.0，见 [LICENSE-ASSETS.md](LICENSE-ASSETS.md)

欢迎拿去改、拿去养，也欢迎把你自己的桌虫角色包接进来。
