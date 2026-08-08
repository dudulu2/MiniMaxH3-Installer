# MiniMax H3 Heretic Safe Switch v2

这是一个**独立于主安装器**的 Heretic H3 配置工具。

## v2 的核心原则

**官方工作流完全不修改。**

原安装器部署的：

`MiniMax_H3_8GB.json`

始终保留原样。

运行 `一键启用-H3-Heretic.bat` 后，只额外创建两份工作流：

- `MiniMax_H3_Heretic_T2V.json`：文生视频，直接输入 Prompt。
- `MiniMax_H3_Heretic_I2V.json`：图生视频，自动增加 `LoadImage` 首帧节点并连接到 H3 `first_frame`。

两份新工作流都使用独立安装的 Ultra-Heretic INT8 ConvRot text encoder。

## 下载路线

默认使用：

`hf-mirror.com 镜像 → 失败后 Hugging Face 官方源`

模型下载支持 `.part` 断点续传。模型通过大小、SHA-256（远端提供时）和 safetensors 结构检查后，才生成新工作流。

## 安全边界

- 不修改 `main` 分支。
- 不修改原 MiniMax H3 一键安装流程。
- 不删除或覆盖官方 Qwen3-VL encoder。
- 不覆盖 `MiniMax_H3_8GB.json`。
- Heretic 配置失败时，官方工作流仍可直接使用。
- `移除-Heretic-工作流.bat` 只删除两份新增工作流和状态文件，官方工作流无需恢复，因为从未被改动。

## 使用

1. 先使用原 MiniMaxH3-Installer 完成正常 H3 安装，并确认官方工作流可运行。
2. 双击 `一键启用-H3-Heretic.bat`。
3. ComfyUI 工作流列表中会额外出现 T2V 与 I2V 两份 Heretic 工作流。
4. 如需撤销，双击 `移除-Heretic-工作流.bat`。

## 关于“无审核”和精度

Ultra-Heretic 能显著降低 Qwen3-VL 作为语言模型时的拒答倾向，但这不能科学保证 MiniMax H3 最终视频输出达到 100% 无任何限制。H3 主要读取 Qwen3-VL 的中间隐藏状态作为 conditioning，因此实际收益应使用同 Prompt、同 Seed 做官方 encoder / Heretic encoder A/B 测试。

工具选择 INT8 ConvRot，是为了优先保持 text encoder 精度，而不是追求最低文件体积。

> 目录中早期 `Enable-H3-Heretic-Encoder.ps1` / `Run-MirrorFirst.ps1` 属于旧版实现。正常使用请直接运行 `一键启用-H3-Heretic.bat`，它现在走 v2 隔离工作流逻辑。
