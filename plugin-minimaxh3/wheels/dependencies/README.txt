MiniMax H3 current-runtime plugin dependency wheelhouse
====================================================

Target: Windows x64 / CPython 3.10.11 / Torch 2.10.0+cu130 / CUDA 13.0.

Put compatible ordinary plugin dependency .whl files in this directory.
The installer tries this directory first with --no-index --find-links.
If the wheelhouse cannot satisfy a plugin requirement completely, installation
falls back to configured PyPI sources while keeping protected runtime constraints.

Do NOT place cp313-only wheels here.
Do NOT place Torch 2.12 wheels here.
Do NOT place torch/torchvision/torchaudio replacement wheels here.

TE/Sage plugin source is already bundled in resources/plugins-source.zip.
The exact Triton/SageAttention binary wheels belong in ../acceleration/.
