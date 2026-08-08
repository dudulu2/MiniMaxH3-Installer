# MiniMax H3 Heretic Safe Switch

这是一个**独立于主安装器**的实验性切换工具。

## 设计原则

- **不修改 main 分支**。
- **不修改现有一键安装流程**。
- 官方 Qwen3-VL H3 text encoder 永远保留，不删除、不覆盖。
- Heretic encoder 使用独立文件名安装。
- 只有模型下载与校验全部通过后，才修改工作流。
- 工作流修改前自动备份。
- JSON 修改失败或 ComfyUI 无法识别新 encoder 时，自动恢复官方工作流。
- 可随时运行回退脚本恢复官方 encoder。

## 使用方法

1. 先用原来的 MiniMaxH3-Installer 完成正常安装，并确认 H3 可正常运行。
2. 再单独下载/运行本目录里的 Heretic 切换脚本。
3. 成功后继续使用原有 H3 环境。
4. 如有任何问题，运行回退脚本恢复官方工作流。

## 重要说明

Ultra-Heretic 能显著降低 Qwen3-VL 作为 LLM 时的拒答倾向，但这**不能科学保证** MiniMax H3 最终视频输出达到“100% 无审核”。H3 主要读取 Qwen3-VL 的隐藏状态作为 conditioning，因此实际收益应通过同 prompt、同 seed 的 A/B 测试验证。

本工具优先采用 INT8 ConvRot，是为了尽量保留 text encoder 精度，而不是追求最低体积。
