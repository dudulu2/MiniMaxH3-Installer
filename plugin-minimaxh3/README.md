# plugin-minimaxh3

Dedicated plugin installer for the current `MiniMaxH3-Installer` CUDA 13 mainline.

## Locked target

This package targets the **actual default runtime installed by `MiniMaxH3-Installer/main`**:

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

The old OneClick plugin pack's Python 3.13 / Torch 2.12 runtime is **not** supported here. Legacy compatibility is intentionally lower priority than keeping the current local installer stable.

## Default managed plugins

The first current-runtime profile installs these pinned plugin folders:

- `comfyui_essentials`
- `comfyui-crystools`
- `comfyui-custom-scripts`
- `comfyui-manager`
- `comfyui-VideoHelperSuite`
- `rgthree-comfy`
- `comfyui-minimax-h3-audio-T8`
- `comfyui-minimax-h3-blockcache-T8`
- `ComfyUI-MiniMaxH3-AVCache-CN`

Plugin source is pinned to commit `2f6e2b4ae45852d2f8355bfea338e1ab80676964` of `dudulu2/MiniMax-H3-OneClick`; only the selected plugin directories are extracted from its `step2-plugin-pack` folder.

## Deliberately excluded for this target

- `minimax_h3_workflow_autoload`: Step 1 already creates and owns this node. Replacing it can overwrite the generated current INT8 workflow/autoload state.
- `TE-Speed-MiniMaxH3-OSS`: not enabled by default because the fixed target H3 core does not expose the `block_loop` hook path used by this optimization.
- `SageAttention-MiniMaxH3-Safe`: deferred until an exact `cp310 + Torch 2.10 + CUDA 13` Triton/Sage pair is separately validated. This installer will **never upgrade Torch to make Sage work**.

## Safety rules

1. `Check-Runtime.ps1` must pass before `custom_nodes` is modified.
2. Plugin requirements are installed with constraints that pin the current Torch trio and the ComfyUI package versions above.
3. If `wheels/dependencies/` contains local wheels they are attempted completely offline first; network sources are only fallbacks.
4. Dependencies are resolved **before** existing plugin directories are changed.
5. The exact CUDA13 runtime is checked again after dependency installation.
6. Existing managed plugin folders are backed up under `D:\MiniMaxH3\plugin-backups\plugin-minimaxh3-<timestamp>\` before replacement.
7. Python compile checks, the runtime guard, and `pip check` run after plugin copy.

## Plugin source: local first

For a network-free source install, download the pinned full source archive and rename it to:

`plugin-source.zip`

Place it directly beside `Install-Plugins.bat`.

If it is absent, the installer downloads the pinned archive once and caches it under:

`<MiniMaxH3>\downloads\plugin-minimaxh3\`

## Use

1. Finish installing `MiniMaxH3-Installer` with the default CUDA 13 runtime.
2. Stop ComfyUI with `Stop MiniMax H3.bat` if it is running.
3. Double-click `plugin-minimaxh3\Install-Plugins.bat`.
4. Review `D:\MiniMaxH3\logs\plugin-minimaxh3-*.log` if installation stops.

The CUDA 12.6 / Torch 2.8 manual compatibility channel is outside this plugin package's supported target.
