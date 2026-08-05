from __future__ import annotations

from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8-sig")
    if old not in text:
        raise SystemExit(f"Expected fragment not found in {path}:\n{old}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def patch_core() -> None:
    path = Path("assets/hardware_profiles_core.ps1")
    replace_once(
        path,
        '$script:ProfileButton = $null\n',
        '''$script:ProfileButton = $null
$script:chkChinaMirror = $null

function Test-ChinaMirrorPriority {
    try {
        return [bool]($script:chkChinaMirror -and $script:chkChinaMirror.Checked)
    } catch {
        return $false
    }
}

function Get-DownloadRouteLabel {
    if (Test-ChinaMirrorPriority) { return "China mirrors first" }
    return "Official sources first"
}
''',
    )
    replace_once(
        path,
        '''function Initialize-HardwareProfileUI {
    if (-not $script:ProfileButton) {''',
        '''function Initialize-HardwareProfileUI {
    if (-not $script:chkChinaMirror) {
        $script:chkChinaMirror = New-Object Windows.Forms.CheckBox
        $script:chkChinaMirror.Text = "China mainland mirror priority"
        $script:chkChinaMirror.AutoSize = $true
        $script:chkChinaMirror.Location = New-Object Drawing.Point(250, 420)
        $chinaLocale = $false
        try {
            $chinaLocale = ([Globalization.RegionInfo]::CurrentRegion.TwoLetterISORegionName -eq "CN") -or ([Globalization.CultureInfo]::CurrentUICulture.Name -eq "zh-CN")
        } catch { $chinaLocale = $false }
        $script:chkChinaMirror.Checked = $chinaLocale
        $script:chkChinaMirror.Add_CheckedChanged({ Show-HardwareReport | Out-Null })
        $form.Controls.Add($script:chkChinaMirror)
        $script:chkChinaMirror.BringToFront()
    }
    if (-not $script:ProfileButton) {''',
    )
    replace_once(
        path,
        '''    & $add "PyTorch runtime" $runtime.label "PASS" ($(if ($snapshot.RuntimeId -eq "cuda128") { "RTX 50-series / Blackwell runtime selected." } else { "RTX 30/40-series runtime selected." }))

    try {''',
        '''    & $add "PyTorch runtime" $runtime.label "PASS" ($(if ($snapshot.RuntimeId -eq "cuda128") { "RTX 50-series / Blackwell runtime selected." } else { "RTX 30/40-series runtime selected." }))
    $routeDetail = if (Test-ChinaMirrorPriority) { "npmmirror, Tsinghua, Aliyun (when available), and hf-mirror are attempted before official sources." } else { "Official sources are attempted first; configured mirrors remain automatic fallbacks." }
    & $add "Download route" (Get-DownloadRouteLabel) "PASS" $routeDetail

    try {''',
    )
    replace_once(
        path,
        '''        RecommendedProfileId = $snapshot.RecommendedProfileId
    }
}''',
        '''        RecommendedProfileId = $snapshot.RecommendedProfileId
        ChinaMirrorPriority = (Test-ChinaMirrorPriority)
    }
}''',
    )


def patch_install() -> None:
    path = Path("assets/hardware_profiles_install.ps1")
    text = path.read_text(encoding="utf-8-sig")
    marker = "function Invoke-PipWithFallback {"
    if not text.startswith(marker):
        raise SystemExit("hardware_profiles_install.ps1 no longer starts with Invoke-PipWithFallback")

    python_runtime = r'''function Install-PythonRuntime {
    param([string]$InstallRoot)
    $pythonRoot = Join-Path $InstallRoot "runtime\python"
    $python = Join-Path $pythonRoot "python.exe"
    if (Test-Path -LiteralPath $python) {
        $version = (& $python -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null)
        if ($version -eq "3.10") {
            Add-Log "Existing private Python 3.10 runtime found."
            return $python
        }
        throw "The private Python runtime exists but is not Python 3.10: $python"
    }

    $cache = Join-Path $InstallRoot "downloads"
    $installer = Join-Path $cache "python-3.10.11-amd64.exe"
    Set-Stage "Downloading Python 3.10 runtime" -1
    $mirrorFirst = Test-ChinaMirrorPriority
    $pythonUrls = if ($mirrorFirst) {
        @(
            "https://registry.npmmirror.com/-/binary/python/3.10.11/python-3.10.11-amd64.exe",
            "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe"
        )
    } else {
        @(
            "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe",
            "https://registry.npmmirror.com/-/binary/python/3.10.11/python-3.10.11-amd64.exe"
        )
    }
    Add-Log ("Python download route: {0}" -f $(if ($mirrorFirst) { "China mirror first" } else { "Official source first" }))
    $null = Invoke-SimpleDownload "Python 3.10.11" $pythonUrls $installer
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or -not $signature.SignerCertificate.Subject.Contains("Python Software Foundation")) {
        throw "The Python installer signature is not valid. File was not executed. Status: $($signature.Status)"
    }
    Add-Log "Python installer signature verified: $($signature.SignerCertificate.Subject)"
    Set-Stage "Installing private Python runtime" -1
    $arguments = "/quiet InstallAllUsers=0 Include_launcher=0 Include_test=0 Include_doc=0 AssociateFiles=0 Shortcuts=0 PrependPath=0 Include_pip=1 TargetDir=`"$pythonRoot`""
    $null = Invoke-ProcessChecked $installer $arguments $InstallRoot
    if (-not (Test-Path -LiteralPath $python)) { throw "Python installation did not create $python" }
    return $python
}

'''
    text = python_runtime + text
    path.write_text(text, encoding="utf-8")

    text = path.read_text(encoding="utf-8")
    start = text.index("function Invoke-PipWithFallback {")
    end = text.index("\nfunction Install-ComfyEnvironment {", start)
    pip_function = r'''function Invoke-PipWithFallback {
    param(
        [string]$Python,
        [string]$PackageArguments,
        $Runtime,
        [switch]$NeedsTorchIndex
    )
    if ($NeedsTorchIndex) {
        $officialArgs = "$PackageArguments --index-url $($Runtime.index_url)"
        $mirrorArgs = if ($Runtime.mirror_index_url) { "$PackageArguments --index-url $($Runtime.mirror_index_url)" } else { $null }
        $officialLabel = "PyTorch official source"
        $mirrorLabel = "Aliyun PyTorch mirror"
    } else {
        $mirrorTorchIndex = if ($Runtime.mirror_index_url) { $Runtime.mirror_index_url } else { $Runtime.index_url }
        $officialArgs = "$PackageArguments --index-url https://pypi.org/simple --extra-index-url $($Runtime.index_url)"
        $mirrorArgs = "$PackageArguments --index-url https://pypi.tuna.tsinghua.edu.cn/simple --extra-index-url $mirrorTorchIndex"
        $officialLabel = "official PyPI"
        $mirrorLabel = "Tsinghua PyPI mirror"
    }

    $preferMirror = Test-ChinaMirrorPriority
    if ($preferMirror -and $mirrorArgs) {
        $primaryArgs = $mirrorArgs
        $primaryLabel = $mirrorLabel
        $fallbackArgs = $officialArgs
        $fallbackLabel = $officialLabel
    } else {
        $primaryArgs = $officialArgs
        $primaryLabel = $officialLabel
        $fallbackArgs = $mirrorArgs
        $fallbackLabel = $mirrorLabel
    }

    if ($preferMirror -and -not $mirrorArgs) {
        Add-Log "No verified China mirror is configured for $($Runtime.label); using the official PyTorch source." "WARN"
    }
    Add-Log "Python package source: $primaryLabel"
    $exit = Invoke-ProcessChecked $Python ("-m pip {0} --timeout 30 --retries 2 --no-cache-dir --disable-pip-version-check" -f $primaryArgs) $script:InstallerRoot -AllowFailure
    if ($exit -ne 0) {
        if (-not $fallbackArgs) { throw "$primaryLabel failed and no fallback source is configured for $($Runtime.label)." }
        Add-Log "$primaryLabel failed; switching to $fallbackLabel." "WARN"
        Invoke-ProcessChecked $Python ("-m pip {0} --timeout 30 --retries 3 --no-cache-dir --disable-pip-version-check" -f $fallbackArgs) $script:InstallerRoot
    }
}
'''
    path.write_text(text[:start] + pip_function + text[end:], encoding="utf-8")

    replace_once(
        path,
        '''    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Python
    $psi.Arguments = "`"$downloader`" --comfy-root `"$ComfyRoot`" --status `"$statusPath`" --catalog `"$script:CatalogPath`" --profiles `"$script:ProfilesPath`" --profile `"$($Profile.id)`""''',
        '''    $sourceOrder = if (Test-ChinaMirrorPriority) { "mirror-first" } else { "official-first" }
    Add-Log "Model download route: $sourceOrder"
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Python
    $psi.Arguments = "`"$downloader`" --comfy-root `"$ComfyRoot`" --status `"$statusPath`" --catalog `"$script:CatalogPath`" --profiles `"$script:ProfilesPath`" --profile `"$($Profile.id)`" --source-order $sourceOrder"''',
    )
    replace_once(
        path,
        '''        launch_file = "Start MiniMax H3.bat"
    }''',
        '''        launch_file = "Start MiniMax H3.bat"
        download_route = $(if (Test-ChinaMirrorPriority) { "china-mirror-first" } else { "official-first" })
    }''',
    )
    replace_once(
        path,
        '''    if ($script:ProfileButton) { $script:ProfileButton.Enabled = $false }
    $btnLaunch.Enabled = $false''',
        '''    if ($script:ProfileButton) { $script:ProfileButton.Enabled = $false }
    if ($script:chkChinaMirror) { $script:chkChinaMirror.Enabled = $false }
    $btnLaunch.Enabled = $false''',
    )
    replace_once(
        path,
        '''        Add-Log "Selected runtime: $($runtime.label)"
        Add-Log ("Models: {0:N2} GiB; downloads support resume and SHA-256 verification." -f ($modelBytes/1GB))''',
        '''        Add-Log "Selected runtime: $($runtime.label)"
        Add-Log "Download route: $(Get-DownloadRouteLabel)"
        Add-Log ("Models: {0:N2} GiB; downloads support resume and SHA-256 verification." -f ($modelBytes/1GB))''',
    )
    replace_once(
        path,
        '''        if ($script:ProfileButton) { $script:ProfileButton.Enabled = $true }
        $form.ControlBox = $true''',
        '''        if ($script:ProfileButton) { $script:ProfileButton.Enabled = $true }
        if ($script:chkChinaMirror) { $script:chkChinaMirror.Enabled = $true }
        $form.ControlBox = $true''',
    )


def patch_downloader() -> None:
    path = Path("assets/download_models.py")
    replace_once(
        path,
        'MODEL_KEYS = ("diffusion_model", "text_encoder", "video_vae", "audio_vae")\n\n\ndef load_json',
        '''MODEL_KEYS = ("diffusion_model", "text_encoder", "video_vae", "audio_vae")


def model_sources(model_path: str, source_order: str) -> tuple[str, str]:
    official = f"{OFFICIAL}/{model_path}"
    mirror = f"{MIRROR}/{model_path}"
    if source_order == "mirror-first":
        return mirror, official
    return official, mirror


def load_json''',
    )
    replace_once(
        path,
        '''    index: int,
    model: dict[str, Any],
) -> None:''',
        '''    index: int,
    model: dict[str, Any],
    source_order: str,
) -> None:''',
    )
    replace_once(path, '    sources = (f"{OFFICIAL}/{model[\'path\']}", f"{MIRROR}/{model[\'path\']}")', '    sources = model_sources(model["path"], source_order)')
    replace_once(
        path,
        '''    parser.add_argument("--profile", required=True)
    parser.add_argument("--dry-run", action="store_true")''',
        '''    parser.add_argument("--profile", required=True)
    parser.add_argument(
        "--source-order",
        choices=("official-first", "mirror-first"),
        default="official-first",
    )
    parser.add_argument("--dry-run", action="store_true")''',
    )
    replace_once(
        path,
        '''    print(f"Selected model download: {total / (1024 ** 3):.2f} GiB", flush=True)
    for item in models:''',
        '''    print(f"Selected model download: {total / (1024 ** 3):.2f} GiB", flush=True)
    print(f"Model source order: {args.source_order}", flush=True)
    for item in models:''',
    )
    replace_once(
        path,
        '        download_model(args.comfy_root, args.status, models, profile["id"], index, model)',
        '''        download_model(
            args.comfy_root,
            args.status,
            models,
            profile["id"],
            index,
            model,
            args.source_order,
        )''',
    )


def patch_readme() -> None:
    path = Path("README.md")
    replace_once(
        path,
        '''## Download safety

All official model file sizes and SHA-256 values are stored in `assets/hf_model_inventory.json`. Downloads try Hugging Face first and then `hf-mirror`, retain partial files, resume by HTTP range, and verify the completed file before installation continues.''',
        '''## Download routes and safety

The main installer window includes **China mainland mirror priority**. When enabled, Python uses npmmirror first, normal Python packages use the Tsinghua PyPI mirror first, CUDA 12.6 PyTorch uses the Aliyun mirror first, and MiniMax H3 models use `hf-mirror` first. Every configured official source remains the automatic fallback. CUDA 12.8 currently has no verified bundled China mirror and therefore continues to use the official PyTorch source.

When the option is disabled, official sources are attempted first and mirrors remain automatic fallbacks. The selected route is locked while an installation is running and is written to the installation manifest.

All official model file sizes and SHA-256 values are stored in `assets/hf_model_inventory.json`. Model downloads retain partial files, resume by HTTP range, and verify the completed file before installation continues, regardless of source order.''',
    )


def write_validation() -> None:
    Path(".github/workflows/validate-download-route.yml").write_text(
        '''name: Validate download route

on:
  push:
    branches:
      - main
      - feature/china-mirror-mode
  pull_request:

permissions:
  contents: read

jobs:
  validate-download-route:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - name: Validate Python model source ordering
        shell: pwsh
        run: |
          @'
          import importlib.util
          from pathlib import Path

          path = Path("assets/download_models.py")
          spec = importlib.util.spec_from_file_location("download_models", path)
          module = importlib.util.module_from_spec(spec)
          assert spec.loader is not None
          spec.loader.exec_module(module)

          mirror_first = module.model_sources("vae/test.bin", "mirror-first")
          official_first = module.model_sources("vae/test.bin", "official-first")
          assert mirror_first[0].startswith("https://hf-mirror.com/")
          assert mirror_first[1].startswith("https://huggingface.co/")
          assert official_first[0].startswith("https://huggingface.co/")
          assert official_first[1].startswith("https://hf-mirror.com/")
          print("Model source ordering passed.")
          '@ | python -

      - name: Validate PowerShell pip source ordering
        shell: powershell
        run: |
          $tokens = $null
          $errors = $null
          $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'assets/hardware_profiles_install.ps1'), [ref]$tokens, [ref]$errors)
          if ($errors.Count -gt 0) { throw 'hardware_profiles_install.ps1 did not parse.' }
          $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-PipWithFallback'
          }, $true)
          Invoke-Expression $functionAst.Extent.Text

          $script:InstallerRoot = (Resolve-Path '.').Path
          $script:CapturedArguments = @()
          function Add-Log { param([string]$Message, [string]$Level = 'INFO') }
          function Invoke-ProcessChecked {
            param([string]$FilePath, [string]$Arguments, [string]$WorkingDirectory, [switch]$AllowFailure)
            $script:CapturedArguments += $Arguments
            if ($AllowFailure) { return 0 }
          }
          $runtime = [PSCustomObject]@{
            label = 'test runtime'
            index_url = 'https://download.pytorch.org/whl/cu126'
            mirror_index_url = 'https://mirrors.aliyun.com/pytorch-wheels/cu126'
          }

          function Test-ChinaMirrorPriority { return $true }
          Invoke-PipWithFallback 'python.exe' 'install torch' $runtime -NeedsTorchIndex
          if ($script:CapturedArguments.Count -ne 1 -or $script:CapturedArguments[0] -notmatch 'mirrors\.aliyun\.com') {
            throw "Mirror-first PyTorch route was not selected: $($script:CapturedArguments -join '; ')"
          }

          $script:CapturedArguments = @()
          function Test-ChinaMirrorPriority { return $false }
          Invoke-PipWithFallback 'python.exe' 'install torch' $runtime -NeedsTorchIndex
          if ($script:CapturedArguments.Count -ne 1 -or $script:CapturedArguments[0] -notmatch 'download\.pytorch\.org') {
            throw "Official-first PyTorch route was not selected: $($script:CapturedArguments -join '; ')"
          }

      - name: Validate installer route propagation
        shell: powershell
        run: |
          $core = Get-Content -LiteralPath 'assets/hardware_profiles_core.ps1' -Raw
          $install = Get-Content -LiteralPath 'assets/hardware_profiles_install.ps1' -Raw
          if ($core -notmatch 'China mainland mirror priority') { throw 'Mirror-priority checkbox is missing.' }
          if ($install -notmatch 'registry\.npmmirror\.com') { throw 'npmmirror Python source is missing.' }
          if ($core -notmatch 'Download route') { throw 'Download route hardware-report row is missing.' }
          if ($install -notmatch '--source-order \$sourceOrder') { throw 'Model source order was not propagated.' }
          if ($install -notmatch 'download_route') { throw 'Download route was not written to the manifest.' }
''',
        encoding="utf-8",
    )


def main() -> None:
    patch_core()
    patch_install()
    patch_downloader()
    patch_readme()
    write_validation()


if __name__ == "__main__":
    main()
