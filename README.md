# MiniMax H3 Windows Installer

Double-click `Start-Installer.bat`. The installer detects the NVIDIA GPU, VRAM, system RAM, driver, and free disk space, then asks which MiniMax H3 configuration to install before any downloads begin.

## Supported range

- Windows 10/11 x64 with a desktop session
- NVIDIA RTX 3060-class through RTX 5090-class GPUs
- At least 8 GB VRAM and 16 GB system RAM for the compatibility profile
- NVIDIA driver 560 or newer recommended for RTX 30/40 series
- NVIDIA driver 580 or newer required for the RTX 50-series CUDA 13.0 runtime
- Internet access during installation

The installer chooses the highest-VRAM NVIDIA GPU when more than one GPU is present and writes that physical GPU index into the launcher through `CUDA_VISIBLE_DEVICES`.

## Installation profiles

| Profile | Intended hardware | Diffusion / text encoder | Default output | Minimum free disk |
|---|---|---|---|---:|
| Compatibility | RTX 3060/4060 and other 8–16 GB cards; 16–32 GB RAM | Pruned INT8 ConvRot / NVFP4 AWQ | 608x352, 5 seconds, 24 fps | 60 GiB |
| Balanced 4090/5090 | RTX 4090 or RTX 5090 with at least 32 GB RAM | Pruned FP8 Scaled / NVFP4 AWQ | 864x480, 5 seconds, 24 fps | 60 GiB |
| Quality 64 GB | 24 GB+ VRAM and at least 64 GB RAM | Pruned BF16 / INT8 ConvRot | 960x544, 5 seconds, 24 fps | 90 GiB |

`Auto` recommends Compatibility for normal 8–16 GB cards and for RTX 30-series cards with 32 GB RAM. It recommends Balanced for FP8-capable RTX 40/50-series cards with 24 GB+ VRAM and 32–63 GB RAM, and Quality for any supported 24 GB+ card with at least 64 GB RAM. A manually selected profile is checked against its own VRAM, RAM, and disk requirements before installation can start.

## CUDA runtime selection

- RTX 30 and RTX 40 series: PyTorch `2.8.0+cu126`, Torchvision `0.23.0+cu126`, TorchAudio `2.8.0+cu126`
- RTX 50 series / Blackwell: PyTorch `2.10.0+cu130`, Torchvision `0.25.0+cu130`, TorchAudio `2.10.0+cu130`

The installer verifies the exact package versions, CUDA availability, CUDA runtime version, and detected GPU before downloading the H3 models.

## Upgrade an existing installation

Select the same installation directory and click **Install / Repair**. The installer preserves models, user workflows, logs, launchers, and partial model downloads. If the installed PyTorch runtime does not match the selected GPU runtime, the old Torch/Torchvision/TorchAudio packages are removed and the matching set is installed. ComfyUI requirements are then refreshed with `--upgrade --upgrade-strategy only-if-needed`, followed by `pip check` and a CUDA verification run.

For an existing RTX 50-series installation this upgrades the previous PyTorch 2.8 CUDA 12.8 environment to PyTorch 2.10 CUDA 13.0 without downloading the H3 models again when their verified files are already present.

## Local PyTorch wheels

The installer searches its root and `assets` recursively for exact Python 3.10 Windows wheels matching the selected runtime. For RTX 50-series systems the optional local files are:

- `torch-2.10.0+cu130-cp310-cp310-win_amd64.whl`
- `torchvision-0.25.0+cu130-cp310-cp310-win_amd64.whl`
- `torchaudio-2.10.0+cu130-cp310-cp310-win_amd64.whl`

A local Torch wheel is used first. Missing matching Torchvision or TorchAudio wheels are downloaded individually. If no matching local Torch wheel exists, the full matching runtime is downloaded from the configured PyTorch source.

## Installed stack

- Fixed ComfyUI commit `0764232429b8cfb10b79b6f186c8cb23e0b22897`
- Private Python 3.10 runtime and virtual environment
- Selected PyTorch CUDA runtime
- One selected FL2VA diffusion model
- One selected Qwen3-VL 32B MiniMax H3 text encoder
- MiniMax H3 video and audio VAEs
- A generated workflow whose model names and resolution match the selected profile
- `Start MiniMax H3.bat`, `Stop MiniMax H3.bat`, logs, manifest, and optional desktop shortcut

The current installer deploys the standard FL2VA workflow for text generation and optional first/last frame conditioning. Ref2VA reference-image/video/audio weights are not installed by this version.

The launcher does not use `--lowvram`; ComfyUI uses DynamicVRAM. SeedVR2, xformers, SageAttention, FlashAttention, and Triton are not installed.

## Download routes and safety

The main installer window includes **China mainland mirror priority**. When enabled, Python uses npmmirror first, normal Python packages use the Tsinghua PyPI mirror first, CUDA 12.6 PyTorch uses the Aliyun mirror first, and MiniMax H3 models use `hf-mirror` first. Every configured official source remains the automatic fallback. CUDA 13.0 currently has no verified bundled China mirror and therefore uses the official PyTorch source unless matching local wheels are supplied.

When the option is disabled, official sources are attempted first and mirrors remain automatic fallbacks. The selected route is locked while an installation is running and is written to the installation manifest.

All official model file sizes and SHA-256 values are stored in `assets/hf_model_inventory.json`. Model downloads retain partial files, resume by HTTP range, and verify the completed file before installation continues, regardless of source order.

## Use

1. Double-click `Start-Installer.bat`.
2. Review the detected GPU/RAM and accept `Auto`, or choose one of the three profiles.
3. Select an installation folder and run **Check computer**.
4. Click **Install / Repair**.
5. After completion, use `Start MiniMax H3.bat` or the desktop shortcut.
6. Use `Stop MiniMax H3.bat` before shutting down or moving the installation.

The full 40–68 GiB model downloads and generation performance still require end-to-end validation on representative RTX 3060, RTX 4090, and RTX 5090 systems before this branch is treated as a final release.
