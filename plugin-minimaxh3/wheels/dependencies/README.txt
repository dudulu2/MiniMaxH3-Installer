MiniMax H3 current-runtime plugin dependency wheelhouse
====================================================

Target: Windows x64 / CPython 3.10.11 / Torch 2.10.0+cu130 / CUDA 13.0.

Put compatible ordinary dependency .whl files in this directory.
The installer tries this directory first with --no-index --find-links.
If the wheelhouse cannot satisfy a plugin requirement completely, installation
falls back to the configured PyPI sources while keeping the protected runtime
constraints in force.

Do NOT place cp313-only wheels here.
Do NOT place Torch 2.12 wheels here.
SageAttention/Triton are not part of the default current-runtime plugin profile.
