# MiniMax H3 Clean Plugin Installer

这是一个**纯代码、运行时下载**的插件安装器，专门针对 `MiniMaxH3-Installer` 当前 CUDA 13 稳定环境：

- Python 3.10.11
- torch 2.10.0+cu130
- torchvision 0.25.0+cu130
- torchaudio 2.10.0+cu130
- CUDA 13.0

目录里不保存：

- 插件源码 ZIP
- wheel 资源包
- OneClick 本体
- Python / Torch / ComfyUI 本体
- 离线资源目录

安装时才下载所需插件源码和 Sage/Triton wheel，临时文件安装完成后删除。

## 安装的插件

1. `comfyui_essentials`
2. `comfyui-crystools`
3. `comfyui-custom-scripts`
4. `comfyui-manager`
5. `comfyui-VideoHelperSuite`
6. `rgthree-comfy`
7. `comfyui-minimax-h3-audio-T8`
8. `comfyui-minimax-h3-blockcache-T8`
9. `ComfyUI-MiniMaxH3-AVCache-CN`
10. `TE-Speed-MiniMaxH3-OSS`
11. `SageAttention-MiniMaxH3-Safe`

另外安装并验证：

- `triton-windows 3.6.0.post25`
- `sageattention 2.2.0+cu130torch2.10.0andhigher.post6`

## 来源策略

普通插件直接从各自官方 GitHub 仓库的固定 commit 下载。

MiniMax H3 专用的 `AVCache-CN`、`TE-Speed`、`SageAttention-MiniMaxH3-Safe` 只下载已验证版本对应的**具体源码文件**，不会下载或运行旧 OneClick 安装器，也不会使用 OneClick 的 Python/Torch/ComfyUI 环境。

`comfyui-manager` 使用与目标 ComfyUI v0.30.1 同时期的官方 `Comfy-Org/ComfyUI-Manager` 固定 commit，不再使用旧 `matrix-client==0.4.0` 的版本。

## 保护规则

安装器会在开始、依赖安装后、Sage/Triton 安装后、最终完成前重复检查：

- Python 必须仍为 3.10.11
- torch 必须仍为 2.10.0+cu130
- torchvision 必须仍为 0.25.0+cu130
- torchaudio 必须仍为 2.10.0+cu130
- CUDA 必须仍为 13.0

依赖安装使用 constraints 锁住 Torch 三件套和 `urllib3 2.7.0`。

如果检测到之前测试残留的 `matrix-client`，会先删除并恢复 `urllib3 2.7.0`。

TE 会执行 V3 preflight、core patch、patch check，并尝试安全连接现有工作流。

Sage 会执行真实 CUDA FP16/BF16 smoke test；只有 smoke test 和 `pip check` 都通过才会显示安装成功。

## 使用

关闭 ComfyUI，然后双击：

`Install-Plugins.bat`

默认自动寻找 `D:\MiniMaxH3`；也支持：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Install-Plugins.ps1 -TargetRoot "D:\MiniMaxH3"
```

失败时查看：

`D:\MiniMaxH3\logs\plugin-minimaxh3-clean-*.log`

被替换的旧插件会备份到：

`D:\MiniMaxH3\plugin-backups\plugin-minimaxh3-clean-*`
