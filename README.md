# 小七桌虫 · XiaoQi Desktop Pet

> 一个懂得何时陪伴、何时安静，也能把你的想法整理成安全任务交接的桌面小生物。

小七是一个中文优先、跨平台、低依赖的开源桌面伙伴。她不只是聊天框换皮，也不追求替你接管一切；更重要的是长期待在桌面上，用短句、动作、记忆和适度的主动性陪你工作。

当你说的是一个工程任务时，小七还可以先理解意图、判断风险、整理约束与验收标准，再生成可交给 Codex、Claude Code 或终端工具的本地任务包。**她默认不自动执行高风险操作，决定权仍然在你手里。**

![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-6f42c1)
![License](https://img.shields.io/badge/code-MIT-green)
![Assets](https://img.shields.io/badge/XiaoQi%20assets-CC%20BY%204.0-orange)

## 小七想帮助谁

- 希望桌面上有一点陪伴感，但不想被频繁打扰的人
- 长时间写代码、写作、学习，希望获得轻量反馈的人
- 想尝试 AI 桌宠，但不愿先安装庞大运行栈的人
- 想制作原创角色包、动作和行为配置的创作者
- 希望把模糊想法安全地交给 AI 编程工具，而不是直接放权执行的人

## 为什么小七不只是“又一个 AI 桌宠”

### 1. 陪伴首先是一种注意力礼仪

小七默认使用短回复，尊重工作状态，支持低频捣乱、自然动作和勿扰偏好。设计目标不是让 AI 尽可能多说话，而是让一个长期住在桌面上的角色不过度占用你的注意力。

### 2. 帮你交接任务，而不是悄悄替你做决定

macOS 版本包含早期的 Task Router / TaskPackage 能力。它可以把工程需求整理为本地 Markdown 任务包，记录推荐工具、任务类型、上下文、约束、禁止事项、执行步骤、验收标准和风险等级。

这层能力目前坚持三条边界：

- 不因为一句自然语言就自动运行终端命令
- 中高风险任务明确提示确认
- 任务包可以查看、复制和人工交给其他工具

### 3. 角色身份与运行底座分开

小七的人格、语音配置、动作、立绘和行为包独立保存，不把角色身份绑死在某个模型或单一界面上。项目会继续探索兼容开放角色与桌宠格式，但不会为了接入更多底座而牺牲小七的中文交互和陪伴感。

### 4. 原生双端、默认可离线

- macOS 使用 Swift + AppKit
- Windows 使用 PowerShell + WPF
- 默认模板脑无需 API Key
- 云模型和语音服务均为可选能力

这不是功能最庞大的路线，但它让源码更直接、启动边界更清楚，也适合继续做小步实验。

## 当前已经能做什么

- 透明、置顶、可拖动的桌面宠物窗口
- 闲逛、跳跃、睡眠、思考和轻量捣乱动作
- 中文短句聊天、系统语音和语音输入入口
- 小七 persona、动作、状态立绘和行为包
- 本地保存昵称、回复偏好和窗口位置
- macOS Task Router 与本地任务包交接面板
- DeepSeek / Anthropic-compatible 模型可选接入
- macOS 与 Windows 启动、自测和调试入口

## 当前边界

这是一个仍在生长的个人开源项目，不是成熟商业产品。

- macOS 是目前验证更充分的主线
- Windows 实现已包含在仓库中，但仍需要更多 Windows 真机反馈
- 当前记忆以本地轻量偏好为主，不是完整知识图谱或向量记忆系统
- 没有默认开启自主工具调用，也不会静默控制你的电脑
- 模型、云语音和第三方运行底座不是启动小七的必要条件

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

## 项目目录

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

## 参与方式

现阶段最有帮助的贡献包括：

- 在真实 Windows 设备上运行自测并提交问题
- 改善无障碍、性能和稳定性
- 制作原创且许可清晰的角色资产或行为包
- 提出具体使用场景，而不是单纯堆叠模型与功能
- 帮助小七在“有用”和“不过度打扰”之间找到更好的尺度

如果你喜欢这种方向，可以点一个 Star、试着运行、提交 Issue，或者告诉我们：**你希望桌面上的小生命在什么时候出现，又应该在什么时候安静。**

## 开放边界与许可证

这个仓库公开的是当前可运行实现，希望它能帮助更多人实验桌面陪伴、角色包和安全任务交接。

- 程序代码：MIT，见 [LICENSE](LICENSE)
- `characters/xiaoqi/` 原创角色资产：CC BY 4.0，见 [LICENSE-ASSETS.md](LICENSE-ASSETS.md)
- API Key、本地记忆、日志和私人资料不属于公开内容

小七仍是一个持续发展的原创角色与产品方向。欢迎学习、修改和贡献，也请保留许可要求中的署名，并尊重角色来源与创作者劳动。
