# plugin-minimaxh3

Dedicated plugin installer for the current `MiniMaxH3-Installer` CUDA 13 mainline.

## Target runtime

This package targets exactly the default runtime installed by this repository:

- Python 3.10.11 (`cp310`)
- PyTorch 2.10.0+cu130
- torchvision 0.25.0+cu130
- torchaudio 2.10.0+cu130
- CUDA runtime 13.0
- ComfyUI commit `0764232429b8cfb10b79b6f186c8cb23e0b22897`

Compatibility with the old Python 3.13 / Torch 2.12 plugin pack is intentionally not a design goal.
The installer must preserve the current runtime instead of upgrading it to satisfy plugin requirements.

## Priorities

1. Work correctly on the current MiniMaxH3-Installer CUDA 13 default environment.
2. Never replace or upgrade torch / torchvision / torchaudio.
3. Prefer bundled/local wheels before network package sources.
4. Back up an existing managed plugin before replacing it.
5. Verify imports and run `pip check` after installation.
6. Legacy compatibility is best-effort only and must not complicate the current target.

## Runtime guard

The plugin installer will refuse to modify an installation unless it detects the exact target Python/PyTorch/CUDA environment above. The manual CUDA 12.6 compatibility runtime is outside this package's supported target.
