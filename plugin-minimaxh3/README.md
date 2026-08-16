# plugin-minimaxh3

Dedicated plugin installer for the current `MiniMaxH3-Installer` CUDA 13 mainline.

## Locked target

This package targets the actual default runtime installed by `MiniMaxH3-Installer/main`:

- Python `3.10.11` (`cp310`)
- PyTorch `2.10.0+cu130`
- torchvision `0.25.0+cu130`
- torchaudio `2.10.0+cu130`
- CUDA runtime `13.0`
- ComfyUI commit `0764232429b8cfb10b79b6f186c8cb23e0b22897`
- comfyui-frontend-package `1.47.12`
- comfyui-workflow-templates `0.11.27`
- comfyui-embedded-docs `0.5.9`
- comfy-kitchen `0.2.26`
- comfy-aimdo `0.4.11`

The old OneClick Python 3.13 / Torch 2.12 runtime is not a compatibility target. Keeping the current local CUDA13 runtime unchanged has priority over legacy behavior.

## Default install

The base layer installs these pinned plugin folders:

- `comfyui_essentials`
- `comfyui-crystools`
- `comfyui-custom-scripts`
- `comfyui-manager`
- `comfyui-VideoHelperSuite`
- `rgthree-comfy`
- `comfyui-minimax-h3-audio-T8`
- `comfyui-minimax-h3-blockcache-T8`
- `ComfyUI-MiniMaxH3-AVCache-CN`

The acceleration layer then installs the two combinations that were already validated on the Python 3.10 / Torch 2.10 / CUDA 13 MiniMax H3 environment:

### TE-Speed

- Node: `TE-Speed-MiniMaxH3-OSS`
- Safe core patch: V3 `patch_model.py`
- Safe workflow wiring: `tespeed_workflow_patch.py`

The TE node alone is not enough. The validated installer first preflights and then injects the owned `block_loop` hook into `ComfyUI/comfy/ldm/minimax/model.py`. Therefore a previous `MiniMax H3 core has no block_loop hooks` message means the node was loaded without running the complete TE installer; it is not evidence that the validated TE installer is incompatible with this target.

### SageAttention

Exact validated stack:

- `triton-windows==3.6.0.post25`
- `triton_windows-3.6.0.post25-cp310-cp310-win_amd64.whl`
- `sageattention==2.2.0+cu130torch2.10.0andhigher.post6`
- `sageattention-2.2.0+cu130torch2.10.0andhigher.post6-cp310-abi3-win_amd64.whl`
- Node: `SageAttention-MiniMaxH3-Safe`

Sage/Triton are installed from exact wheels with `--no-deps --no-index`. The plugin installer does not upgrade or downgrade Torch to satisfy Sage.

## Intentionally not replaced

`minimax_h3_workflow_autoload` remains owned by `MiniMaxH3-Installer` Step 1 so the current generated INT8 workflow/autoload state is not overwritten by an older helper copy.

## Safety rules

1. `Check-Runtime.ps1` must pass before plugins or acceleration are modified.
2. Base plugin requirements are constrained to the current Torch trio and fixed ComfyUI package versions.
3. `wheels/dependencies/` is tried offline before PyPI for normal plugin dependencies.
4. Dependencies are resolved before existing base plugin folders are changed.
5. Existing managed plugin folders are backed up before replacement.
6. TE-Speed V3 performs a read-only core preflight before patching `model.py` and stores its own safe-patch state/recovery data.
7. Sage/Triton wheels are verified by exact size and SHA-256 before installation and are installed with `--no-deps`.
8. The protected CUDA13 runtime is checked again after both base dependencies and acceleration installation.
9. Sage runs a real CUDA FP16/BF16 tensor smoke test after installation.
10. Python compile checks and `pip check` run for the normal plugin layer.

## Local-first files

For a source install without downloading the plugin source archive, put the pinned `MiniMax-H3-OneClick` commit archive beside `Install-Plugins.bat` and name it:

`plugin-source.zip`

Normal dependency wheels may be placed in:

`wheels/dependencies/`

For fully local Sage installation, put these two files in:

`wheels/acceleration/`

- `triton_windows-3.6.0.post25-cp310-cp310-win_amd64.whl`
- `sageattention-2.2.0+cu130torch2.10.0andhigher.post6-cp310-abi3-win_amd64.whl`

If they are absent, validated wheels are downloaded into `<MiniMaxH3>\downloads\sageattention-safe\` and verified before use.

## Use

1. Finish installing `MiniMaxH3-Installer` with the default CUDA 13 runtime.
2. Stop ComfyUI with `Stop MiniMax H3.bat`.
3. Double-click `plugin-minimaxh3\Install-Plugins.bat`.
4. Base plugins install first, followed by the validated TE-Speed + Sage acceleration layer.
5. Review `D:\MiniMaxH3\logs\plugin-minimaxh3-*.log` and `plugin-minimaxh3-acceleration-*.log` if installation stops.

The CUDA 12.6 / Torch 2.8 manual compatibility channel is outside this plugin package's supported target.
