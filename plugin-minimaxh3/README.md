# plugin-minimaxh3

Dedicated plugin installer for the current `MiniMaxH3-Installer` CUDA 13 mainline.

## Locked target

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

Python 3.13 / Torch 2.12 is not a supported target. The current MiniMaxH3-Installer CUDA13 runtime must remain unchanged.

## Bundled plugin source

The installer ships its required plugin source snapshot inside:

`resources/plugins-source.zip`

This archive contains the nine base plugins plus `TE-Speed-MiniMaxH3-OSS` and `SageAttention-MiniMaxH3-Safe`. Runtime installation does **not** download the MiniMax-H3-OneClick repository or use its Python/Torch/ComfyUI runtime.

The source snapshot has build-time provenance from the validated plugin set, but the released `plugin-minimaxh3` package is self-contained for plugin source.

## Base plugins

- `comfyui_essentials`
- `comfyui-crystools`
- `comfyui-custom-scripts`
- `comfyui-manager`
- `comfyui-VideoHelperSuite`
- `rgthree-comfy`
- `comfyui-minimax-h3-audio-T8`
- `comfyui-minimax-h3-blockcache-T8`
- `ComfyUI-MiniMaxH3-AVCache-CN`

`minimax_h3_workflow_autoload` remains owned by MiniMaxH3-Installer Step 1 and is not overwritten.

## TE-Speed

- Node: `TE-Speed-MiniMaxH3-OSS`
- Safe core patch: V3 `patch_model.py`
- Safe workflow wiring: `tespeed_workflow_patch.py`

The complete installer runs TE preflight, applies the owned `block_loop` core patch, installs the node, verifies the patch, then safely wires eligible H3 workflows.

## SageAttention

Validated stack:

- `triton-windows==3.6.0.post25`
- `triton_windows-3.6.0.post25-cp310-cp310-win_amd64.whl`
- `sageattention==2.2.0+cu130torch2.10.0andhigher.post6`
- `sageattention-2.2.0+cu130torch2.10.0andhigher.post6-cp310-abi3-win_amd64.whl`
- Node: `SageAttention-MiniMaxH3-Safe`

Sage/Triton are installed with `--no-deps --no-index`; the installer never upgrades or downgrades Torch to satisfy Sage. Exact file size and SHA-256 are verified before installation.

## Local-first dependency files

Normal plugin dependency wheels go in:

`wheels/dependencies/`

The installer tries this wheelhouse with `--no-index --find-links` before using PyPI.

Validated acceleration wheels go in:

`wheels/acceleration/`

- `triton_windows-3.6.0.post25-cp310-cp310-win_amd64.whl`
- `sageattention-2.2.0+cu130torch2.10.0andhigher.post6-cp310-abi3-win_amd64.whl`

If these two acceleration wheels are absent, the installer downloads them into `<MiniMaxH3>\downloads\sageattention-safe\`, verifies them, then installs locally.

## Safety sequence

1. Validate Python 3.10.11 / Torch 2.10.0+cu130 / CUDA 13.0 / fixed ComfyUI APIs.
2. Require ComfyUI to be stopped.
3. Extract the bundled `resources/plugins-source.zip` locally.
4. Resolve base plugin dependencies before changing `custom_nodes`.
5. Re-check the protected runtime.
6. Back up and install the nine base plugins.
7. Run compile checks and `pip check`.
8. Run TE V3 preflight.
9. Install exact Sage/Triton wheels with `--no-deps`.
10. Back up/install TE and Sage nodes, apply/check TE core patch, wire workflows.
11. Run a real CUDA Sage FP16/BF16 smoke test.
12. Re-check the protected runtime again.

## Use

1. Finish installing `MiniMaxH3-Installer` with its default CUDA 13 runtime.
2. Stop ComfyUI.
3. Double-click `plugin-minimaxh3\Install-Plugins.bat`.
4. Check `D:\MiniMaxH3\logs\plugin-minimaxh3-*.log` and `plugin-minimaxh3-acceleration-*.log` if installation stops.

The CUDA 12.6 / Torch 2.8 manual compatibility channel is outside this plugin package's supported target.
