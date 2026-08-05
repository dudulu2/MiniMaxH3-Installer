# MiniMax H3 一键安装器（中文说明）

## 使用方法

1. 双击 `Start-Installer.bat`（如果 Windows 提示“已保护你的电脑”，点“更多信息”然后“仍要运行”）。
2. 选择安装位置（建议 `D:\MiniMaxH3`），点“Check computer”检查电脑。
3. 通过检查后点“Install / Repair”，等待模型下载完成。
4. 安装结束后，双击安装目录里的 `Start MiniMax H3.bat`（或桌面快捷方式），浏览器会自动打开 ComfyUI 并载入 H3 工作流。

## 适用电脑

- Windows 10/11 64 位
- NVIDIA 显卡，显存至少 8 GB（8 GB 已按本机验证）
- 内存至少 16 GB
- 显卡驱动建议 560 或更新
- 目标磁盘至少 60 GB 可用空间（建议 70 GB）

## 装的是什么

- 固定版本的 ComfyUI（commit `0764232`）
- 独立 Python 3.10 环境和虚拟环境，不污染系统 Python
- PyTorch `2.8.0+cu126` / Torchvision `0.23.0+cu126` / Torchaudio `2.8.0+cu126`
- MiniMax H3 INT8 扩散模型 + Qwen NVFP4 文本编码器 + 视频/音频 VAE（共约 39.6 GiB）
- 预配置工作流 `MiniMax_H3_8GB.json`：16:9、608×352、5 秒、24fps

不安装 SeedVR2、xformers、SageAttention、FlashAttention、Triton。启动时不用 `--lowvram`，由 PyTorch 2.8 DynamicVRAM 自行管理显存。

## 下载说明

- 优先官方源，失败自动切换到镜像（hf-mirror / 阿里云 / 清华）。
- 四个模型文件都做 SHA-256 校验，支持断点续传。
- 下载中断后直接再点一次“Install / Repair”即可继续。

## 常见问题

- 端口 8188 被占用：关闭占用程序，或先点 `Stop MiniMax H3.bat`。
- 启动后界面空白：首次打开会自动载入工作流；如果没有，点击顶部工作流菜单选择 `MiniMax_H3_8GB.json`。
- 想完全删除：关闭 ComfyUI，删除整个安装目录和桌面快捷方式即可（不写注册表）。