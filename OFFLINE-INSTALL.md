# Offline / local-wheel-first installation test

This branch keeps the stable runtime unchanged:

- Python 3.10.11
- PyTorch 2.10.0+cu130 (default CUDA 13 runtime)
- torchvision 0.25.0+cu130
- torchaudio 2.10.0+cu130
- bundled ComfyUI source and its existing pinned frontend/template versions

The only behavioral change is package source priority:

1. local Python installer / local wheelhouse
2. configured China or official mirrors
3. remaining network fallback

## Folder layout

Put pre-downloaded files in either of these locations. `assets/wheels` is recommended.

```text
MiniMaxH3-Installer/
├─ python-3.10.11-amd64.exe        # may also be placed under assets/
├─ Prepare-Offline-Wheelhouse.ps1
├─ Start-Installer.bat
└─ assets/
   └─ wheels/
      ├─ torch-2.10.0+cu130-cp310-cp310-win_amd64.whl
      ├─ torchvision-0.25.0+cu130-cp310-cp310-win_amd64.whl
      ├─ torchaudio-2.10.0+cu130-cp310-cp310-win_amd64.whl
      └─ ...all ordinary dependency wheels...
```

The installer searches recursively below the repository root and `assets`, so the exact wheel subfolder can be reorganized later without changing the installer.

## Direct downloads for the large/fixed files

| File | Official URL |
| --- | --- |
| Python 3.10.11 x64 installer | https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe |
| torch 2.10.0 + cu130 cp310 | https://download.pytorch.org/whl/cu130/torch-2.10.0%2Bcu130-cp310-cp310-win_amd64.whl |
| torchvision 0.25.0 + cu130 cp310 | https://download.pytorch.org/whl/cu130/torchvision-0.25.0%2Bcu130-cp310-cp310-win_amd64.whl |
| torchaudio 2.10.0 + cu130 cp310 | https://download.pytorch.org/whl/cu130/torchaudio-2.10.0%2Bcu130-cp310-cp310-win_amd64.whl |

## Recommended: build the complete ordinary dependency wheelhouse automatically

On a machine that already has Python 3.10 available:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Prepare-Offline-Wheelhouse.ps1
```

For China mirror priority:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Prepare-Offline-Wheelhouse.ps1 -ChinaMirror
```

If Python 3.10 is not on PATH:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Prepare-Offline-Wheelhouse.ps1 `
  -Python "C:\path\to\python.exe" `
  -ChinaMirror
```

The helper reads the bundled ComfyUI `requirements.txt` from `assets/ComfyUI-source.zip`, reads the fixed CUDA 13 versions from `assets/install_profiles.json`, and downloads the matching dependency set into `assets/wheels`.

## Offline test

After the wheelhouse is prepared and `python-3.10.11-amd64.exe` is present:

1. disconnect the network (or temporarily block the installer with Windows Firewall);
2. start `Start-Installer.bat`;
3. select the normal CUDA 13 runtime/profile;
4. inspect the installer log.

Expected messages include:

```text
Local Python installer found: ...python-3.10.11-amd64.exe
Local wheel found for torch: ...
Local wheel found for torchvision: ...
Local wheel found for torchaudio: ...
Trying local wheelhouse first: ...\assets\wheels
Local wheelhouse satisfied this dependency transaction; no network source was used.
```

If any ordinary dependency is missing, the installer prints a warning and then tries the configured network sources. That fallback is intentional for normal connected users.

## Scope of this offline test

This change covers the Python runtime installer and Python/wheel dependencies. MiniMax H3 model files are handled by the existing model downloader and are a separate payload. A fully disconnected end-to-end install also requires the selected model files to be staged using the installer's existing local-model mechanism or copied into the expected ComfyUI model folders before model verification.
