# MiniMax H3 一键安装器（硬件自动配置版）

双击 `Start-Installer.bat` 后，安装器会先检测 NVIDIA 显卡、显存、系统内存、驱动和目标磁盘空间，并在开始下载前询问要安装哪一种 MiniMax H3 配置。

## 支持范围

- Windows 10/11 64 位，需有桌面环境
- NVIDIA RTX 3060 级别到 RTX 5090 级别显卡
- 兼容配置最低要求：8 GB 显存、16 GB 系统内存
- RTX 30/40 系建议 NVIDIA 驱动 560 或更新
- RTX 50 系建议 NVIDIA 驱动 570 或更新
- 安装期间需要联网

存在多张 NVIDIA 显卡时，安装器会默认选择显存最大的一张，并通过 `CUDA_VISIBLE_DEVICES` 把对应物理 GPU 编号写入启动器。

## 三种安装配置

| 配置 | 适用硬件 | 扩散模型 / 文本编码器 | 默认输出 | 最低可用空间 |
|---|---|---|---|---:|
| 兼容配置 | RTX 3060/4060 及其他 8–16 GB 显卡；16–32 GB 内存 | Pruned INT8 ConvRot / NVFP4 AWQ | 608×352、5 秒、24fps | 60 GiB |
| 4090/5090 平衡配置 | RTX 4090 或 RTX 5090，至少 32 GB 内存 | Pruned FP8 Scaled / NVFP4 AWQ | 864×480、5 秒、24fps | 60 GiB |
| 64 GB 高质量配置 | 24 GB 以上显存、至少 64 GB 内存 | Pruned BF16 / INT8 ConvRot | 960×544、5 秒、24fps | 90 GiB |

选择 `Auto` 时：

- 普通 8–16 GB 显卡，以及只有 32 GB 内存的 RTX 30 系高显存显卡，推荐“兼容配置”；
- 支持 FP8 的 RTX 40/50 系显卡，显存 24 GB 以上且内存为 32–63 GB 时，推荐“4090/5090 平衡配置”；
- 任意受支持的 24 GB 以上显存显卡，系统内存达到 64 GB 时，推荐“64 GB 高质量配置”。

也可以手动选择，但安装器会按所选配置重新检查显存、内存和磁盘空间，不符合最低条件时会阻止安装。Windows 可能显示略低于内存条标称容量，因此检测为正常的 16/32/64 GB 机器时会保留少量容差。

## CUDA 运行环境自动选择

- RTX 30、RTX 40 系：PyTorch `2.8.0+cu126`
- RTX 50 系 / Blackwell：PyTorch `2.8.0+cu128`

Torchvision 和 Torchaudio 会安装相匹配的 `0.23.0` / `2.8.0` CUDA 构建。开始下载 H3 模型前，安装器会验证精确版本、CUDA 是否可用、CUDA 运行时版本以及实际识别到的显卡。

## 安装内容

- 固定版本 ComfyUI：commit `0764232429b8cfb10b79b6f186c8cb23e0b22897`
- 独立 Python 3.10 和虚拟环境，不污染系统 Python
- 根据显卡自动选择的 PyTorch CUDA 运行环境
- 所选配置对应的一份 FL2VA 扩散模型
- 所选配置对应的一份 Qwen3-VL 32B MiniMax H3 文本编码器
- MiniMax H3 视频 VAE 和音频 VAE
- 自动生成与配置匹配的工作流，包括模型名和默认分辨率
- `Start MiniMax H3.bat`、`Stop MiniMax H3.bat`、日志、安装清单和可选桌面快捷方式

当前版本安装的是标准 FL2VA 工作流，支持文生视频以及可选首帧/尾帧条件。Ref2VA 的参考图片、参考视频和参考音频权重暂未包含在这一版安装器中。

启动时不使用 `--lowvram`，由 PyTorch 2.8 DynamicVRAM 管理显存。不安装 SeedVR2、xformers、SageAttention、FlashAttention、Triton。

## 下载与校验

官方模型文件大小和 SHA-256 全部记录在 `assets/hf_model_inventory.json`。下载会优先使用 Hugging Face，失败后切换 `hf-mirror`；保留未完成文件，支持 HTTP Range 断点续传，并在继续安装前校验完整文件。

## 使用方法

1. 双击 `Start-Installer.bat`。
2. 查看检测到的显卡和内存，接受 `Auto` 推荐，或手动选择三种配置之一。
3. 选择安装目录并点击 **Check computer**。
4. 点击 **Install / Repair**。
5. 安装完成后运行 `Start MiniMax H3.bat` 或桌面快捷方式。
6. 关机或移动安装目录前运行 `Stop MiniMax H3.bat`。

目前代码和静态校验已经覆盖三种配置，但约 40–68 GiB 模型的完整下载和实际生成性能，仍需分别在 RTX 3060、RTX 4090 和 RTX 5090 代表机器上做端到端实测后，才能作为正式发布版本。
