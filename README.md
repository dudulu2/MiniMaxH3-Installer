# MiniMax H3 Windows Installer

Double-click `Start-Installer.bat`, select an installation folder, check the computer, and click **Install / Repair**.

The installer is intended for Windows 10/11 computers with:

- NVIDIA GPU with at least 8 GB VRAM
- At least 16 GB system RAM
- NVIDIA driver 560 or newer recommended
- At least 60 GiB free on the selected drive; 70 GiB recommended
- Internet access during installation

Installed stack:

- ComfyUI commit `0764232429b8cfb10b79b6f186c8cb23e0b22897`
- Private Python 3.10 runtime and virtual environment
- PyTorch `2.8.0+cu126`
- Torchvision `0.23.0+cu126`
- Torchaudio `2.8.0+cu126`
- MiniMax H3 INT8 ConvRot diffusion model
- Qwen3-VL 32B MiniMax H3 NVFP4 AWQ text encoder
- MiniMax H3 video and audio VAEs
- `MiniMax_H3_8GB.json` workflow, preset to 608x352, 5 seconds, 24 fps

The launcher does not use `--lowvram`. ComfyUI can use the PyTorch 2.8 DynamicVRAM path. SeedVR2, xformers, SageAttention, FlashAttention, and Triton are not installed.

Downloads try official sources first and then configured mirrors. All four model files are verified with SHA-256. Interrupted model downloads are retained and resume when **Install / Repair** is run again.

After installation, double-click `Start MiniMax H3.bat` in the selected folder or use the desktop shortcut. Use `Stop MiniMax H3.bat` before shutting down or moving the installation.
